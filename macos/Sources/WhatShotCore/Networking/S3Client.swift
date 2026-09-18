import Foundation
import CryptoKit

/// S3 兼容存储客户端（RustFS/MinIO 等，2026-09-18 海报镜像定案）。
/// 只做一件事：把海报镜像上传到自有桶（mirror），App 拉图优先走桶——
/// 站方图床是明文 http（ATS 不可请求）时，图的中转由 App 完成：
/// App 从豆瓣/TMDB（https）取图 → 传桶 → poster_url 改写为桶 URL。
/// NAS 只做哑存储，不跑任何服务（极空间等无法跑脚本的 NAS 也适用）。
///
/// 认证走 AWS SigV4（RustFS/MinIO 均兼容）；局域网 http 端点由
/// Info.plist NSAllowsLocalNetworking 豁免（本地网络是 ATS 官方例外场景，
/// 不为任何第三方域开洞）。path-style 寻址（MinIO 默认支持，极空间同类）。
public struct S3Client: Sendable {
  public enum S3Error: Error, Sendable {
    case invalidResponse(String)
    case unauthorized        // 401/403：key 错误/权限不足，当批停止
  }

  static let algorithm = "AWS4-HMAC-SHA256"

  let endpoint: String      // 如 http://192.168.1.10:9000（末尾无斜杠）
  let bucket: String
  let accessKey: String
  let secretKey: String
  let region: String
  let session: URLSession

  public init(endpoint: String, bucket: String, accessKey: String, secretKey: String,
              region: String = "us-east-1", session: URLSession = .shared) {
    self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    self.bucket = bucket
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.region = region
    self.session = session
  }

  /// 镜像一张海报：key 形如 "posters/{videoID}.jpg"。存在则跳过（409/404 语义由
  /// HEAD 探测决定——桶是持久层，同一 key 只传一次）。返回成功后的公网/内网直读 URL
  public func mirror(data: Data, contentType: String, key: String) async throws -> String {
    if await exists(key: key) {
      return "\(endpoint)/\(bucket)/\(key)"
    }
    try await put(data: data, contentType: contentType, key: key)
    return "\(endpoint)/\(bucket)/\(key)"
  }

  /// 建桶（PutBucket）。桶已存在（409 BucketAlreadyOwnedByYou/BucketAlreadyExists）视为成功——
  /// 幂等，重复调用无害。管理面建桶和 API 建桶等价，首次部署用哪个都行
  public func createBucket() async throws {
    // us-east-1 可省略 LocationConstraint（省略即代表该 region）；其他 region 需带 body
    let body: Data?
    if region == "us-east-1" {
      body = nil
    } else {
      body = Data("<CreateBucketConfiguration><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>".utf8)
    }
    let response = try await request(method: "PUT", key: "", body: body)
    switch response.statusCode {
    case 200..<300:
      return
    case 409:
      return // 桶已存在：幂等成功
    case 401, 403:
      throw S3Error.unauthorized
    default:
      throw S3Error.invalidResponse("建桶失败 HTTP \(response.statusCode)")
    }
  }

  /// HEAD 探测对象是否已存在（桶里已有的图不重复上传）。
  /// request() 对非 2xx 不抛（401/403 之外原样返回），必须显式查 200——
  /// 首版只看"未抛异常"，HEAD 404 被误判存在跳过 PUT（2026-09-18 实测事故）
  public func exists(key: String) async -> Bool {
    guard let response = try? await request(method: "HEAD", key: key) else { return false }
    return response.statusCode == 200
  }

  /// PUT 上传。401/403 抛 unauthorized（调用方停批）；桶不存在等其他 4xx/5xx 抛 invalidResponse
  public func put(data: Data, contentType: String, key: String) async throws {
    let response = try await request(method: "PUT", key: key, body: data, contentType: contentType)
    if response.statusCode == 401 || response.statusCode == 403 {
      throw S3Error.unauthorized
    }
    guard (200..<300).contains(response.statusCode) else {
      throw S3Error.invalidResponse("S3 上传失败 HTTP \(response.statusCode)")
    }
  }

  // MARK: - SigV4 请求（path-style：{endpoint}/{bucket}/{key}）

  private func request(method: String, key: String, body: Data? = nil,
                       contentType: String? = nil) async throws -> HTTPURLResponse {
    guard let url = URL(string: "\(endpoint)/\(bucket)/\(key)") else {
      throw S3Error.invalidResponse("URL 构造失败")
    }
    let amzDate = Self.amzDateFormat(Date())
    // amzDate = yyyyMMdd'T'HHmmss'Z'（16 字符），日期段 = 去掉 'T'+6 位时间+'Z' 共 8 字符
    let dateStamp = String(amzDate.dropLast(8))   // yyyyMMdd
    // path-style：canonical URI 含桶名
    let canonicalURI = "/\(bucket)/\(Self.uriEncode(key))"
    // payload hash：无 body 用空串 hash，PUT 用 body 的 SHA256
    let payloadHash = Self.sha256Hex(body ?? Data())
    // host：非标准端口必须带（MinIO path-style 的 canonical headers 与实际请求头一致）
    let hostWithPort: String
    if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
      hostWithPort = "\(url.host ?? ""):\(port)"
    } else {
      hostWithPort = url.host ?? ""
    }
    let canonicalHeaders = "host:\(hostWithPort)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)"
    let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
    let canonicalRequest = [
      method,
      canonicalURI,
      "",                                    // canonical query（无参数）
      "\(canonicalHeaders)\n",
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    let scope = "\(dateStamp)/\(region)/s3/aws4_request"
    let stringToSign = [
      Self.algorithm,
      amzDate,
      scope,
      Self.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signature = Self.hmacSHA256Hex(
      Self.hmacSHA256(key: Self.hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8)),
                      data: Data(region.utf8)),
      chained: [Data("s3".utf8), Data("aws4_request".utf8), Data(stringToSign.utf8)]
    )
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = method
    if let body { request.httpBody = body }
    request.setValue(Self.algorithm + " Credential=" + accessKey + "/" + scope +
                     ", SignedHeaders=" + signedHeaders + ", Signature=" + signature,
                     forHTTPHeaderField: "Authorization")
    request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw S3Error.invalidResponse("响应不是 HTTP")
    }
    return http
  }

  // MARK: - 签名原语（静态、可单测）

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func hmacSHA256(key: Data, data: Data) -> Data {
    let key = SymmetricKey(data: key)
    return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
  }

  /// 链式 HMAC（签名派生用）；chained 依次作为数据输入
  static func hmacSHA256Hex(_ key: Data, chained: [Data]) -> String {
    var k = key
    for item in chained {
      k = hmacSHA256(key: k, data: item)
    }
    return k.map { String(format: "%02x", $0) }.joined()
  }

  /// SigV4 时间戳：yyyyMMdd'T'HHmmss'Z'（UTC）。dateStamp 派生用 dropLast(9)（T+HHmmss+Z 共 8 字符）
  static func amzDateFormat(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
  }

  /// URI 编码（SigV4 规则：保留 A-Za-z0-9-._~，其余百分号编码，斜杠是 key 层级不编码）
  static func uriEncode(_ raw: String) -> String {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    allowed.insert(charactersIn: "/")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
  }
}