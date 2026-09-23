# 经验库索引

> vault 模式：随 git 跟踪（未被 ignore），敏感值一律脱敏。

| 文件 | 一句话问题 | 状态 | 最近更新 |
|---|---|---|---|
| [swift-codegen-escaping.md](swift-codegen-escaping.md) | heredoc+python 生成/替换 Swift 时多层转义写错（插值失效/keypath 非法/三引号冲突/多行字面量定界符/静默替换无效） | ✅ 有现成方案 | 2026-09-23 |
| [swift-testing-parallel-stub-pollution.md](swift-testing-parallel-stub-pollution.md) | Swift Testing 默认并行下 URLProtocol stub 共享 static 状态交叉污染，失败落在无关断言上 | ✅ 有现成方案 | 2026-09-23 |
| [sqlite-multi-source-kind-overwrite.md](sqlite-multi-source-kind-overwrite.md) | 多来源 upsert 互相覆盖枚举字段，条目在两个分类视图间闪烁 | ✅ 有现成方案 | 2026-09-23 |
| [client-server-deployment-skew.md](client-server-deployment-skew.md) | 客户端先行接入新端点而服务端未部署：404 静默降级 vs 如实报警的取舍 | ✅ 有现成方案 | 2026-09-23 |