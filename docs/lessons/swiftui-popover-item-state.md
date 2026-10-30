# SwiftUI 首次弹窗缺少业务数据

## 结论速览

最终方案：把弹窗目标放进可选 `Identifiable` 状态，以 `.popover(item:)` 的闭包参数读取本次目标，不用布尔开关与另一个数组分别驱动同一个弹窗。
适用条件：SwiftUI 弹窗首次打开只显示静态内容，而本次操作刚写入的目标列表没有出现；本项目修复已实机通过，SwiftUI 内部原因尚未核实。

## ✅ 用 item 携带本次管理目标，首次打开即可显示清单（2026-10-30）

- **环境**：macOS 26.6.2（25G83），Apple Swift 6.3.3，arm64；SwiftUI 原生窗口，项目最低 macOS 14。系统与编译器版本在落盘当轮读取，未对其他系统版本作验证。
- **为何值得记**：编译和 Core 测试均通过，仍在原生验收发现只有标题、没有操作按钮；经历一次失败实测、一次修复与重新打包复验。纯数据库测试无法覆盖此类弹窗状态问题。
- **最终方案**：当前实现中的关键原文如下；完整组件以 [UpcomingWantViews.swift](../../macos/Sources/WhatShotApp/App/UpcomingWantViews.swift) 为准。

```swift
@State private var managedWork: UpcomingWork?
```

打开动作把目标与展示状态一起赋值：

```swift
managedWork = UpcomingWork(id: work.id, releaseDate: work.releaseDate, releases: visible)
```

弹窗以收到的条目读取目标，而不是读取另一份临时数组：

```swift
.popover(item: $managedWork) { selection in
  let available = selection.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) }
  let followed = available.filter { app.wantedReleaseIDs.contains($0.id) }
  let missing = available.filter { !app.wantedReleaseIDs.contains($0.id) }
```

关闭时：

```swift
managedWork = nil
```

以上为实际组件摘录，弹窗主体未在经验库重复；不可把未闭合的摘录当作独立 Swift 文件。可直接在项目根执行的实际构建命令：

```sh
scripts/build-macos-app.sh
```

- **为什么这样做**：从业务模型上让“展示哪个目标”同时决定“是否展示”，消除布尔值与目标数组两份状态之间的协调；已确认该实现修复本项目现象，不据此断言 SwiftUI 的内部刷新机制。
- **适用条件**：目标实现 `Identifiable`；管理期间应固定可操作的原始 ID，来源关闭只缩小范围，不把后来刷新出现的平台自动纳入取消操作。
- **验证证据**：来自本会话原始 CUA 无障碍输出，修复后首次打开出现以下文本和按钮：

```text
管理想看 玩具总动员5 优酷 已关注 爱奇艺 未关注 腾讯视频 未关注
button 补充关注其余 2 个平台
新增平台从现在开始记录排期变动。 取消范围：优酷 将清除上述平台的想看及排期变动记录，其他平台不受影响。
button 确认取消上述 1 个平台
```

随后补充关注实测显示 `已关注 3/3 个平台 玩具总动员5`；只取消优酷后显示 `已关注 2/3 个平台 玩具总动员5`。最终实现提交 `2d717b5`。完整验收序列见 [作品联动设计的想看归并验收](../plans/work-connections.md#想看收藏跟随作品归并2026-10-30)。
- **交叉验证**：单 agent，一次失败实机观察、一次修复后实机复验；无多 agent 交叉审查，不标“精粹”。
- **关键步骤**：先赋 item → 弹窗使用 `selection` → 重新打包并退出旧进程 → 验证第一次打开 → 验证补充及取消后的状态。
- **易错点**：仅检查构建成功或第二次打开不足以证明修复；不要先加延迟、定时器或强制刷新掩盖首开问题。此处不代表所有 `.popover(isPresented:)` 都有缺陷。

## 🔶 SwiftUI 内部为何未刷新目标数组尚未核实（2026-10-30）

- **环境**：同上。
- **当前推断**：可能涉及布尔展示状态与另一个 `@State` 数组的更新依赖／捕获时机；这是推断，没有框架内部证据。
- **已到哪一步**：原实现首开为空、改为 item 后首开正常已实测；未做脱离本组件的最小复现，也未比较 macOS 14/15 等版本。
- **下一步验证动作**：只有再次遇到同类现象时，提取最小 SwiftUI 应用，对比两种状态组织、首开与再次打开，并记录系统版本。不要为现已修复的功能另加探测逻辑。
- **为何值得继续**：防止把一次组件故障过度推广为 SwiftUI 的普遍规则。
- **交叉验证**：单 agent 推断，未验证内部原因。

## ⛔ 本组件的布尔开关与独立目标数组首开失败（2026-10-30）

- **环境**：同上；失败实现发生在 `2d717b5` 提交前，未单独提交。
- **报错原文**：没有编译或运行时异常；下面是本会话原始 CUA 输出的现象，不能伪造为异常日志：

```text
107 popover Secondary Actions: Cancel
  108 container
    109 text 管理想看 玩具总动员5
```

- **报错稳定片段**：`popover`、`管理想看`；判断失败需同时确认平台清单和补充／取消按钮缺失，不能只按关键词匹配。截图亦确认仅出现标题和片名。
- **错误原因**：事实为首开内容未包含刚写入的目标数组；SwiftUI 内部原因见上方待验证条目。
- **为何不可再采用**：不要在此组件恢复“先写 targets、再设 managing=true”的已失败实现，除非先补最小复现证明首开已可靠；不把它扩大为对布尔弹窗 API 的全面否定。
- **替代方案**：本文件成功条目的 `.popover(item:)`。
- **判定时效**：2026-10-30，本组件与上述环境；依赖升级或结构改变后可重新验证。
- **交叉验证**：单 agent 实机观察；没有虚构异常栈。
