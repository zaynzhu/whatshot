# macOS `open` 命令静默失败（应用未启动）

结论速览：
- **方案**：交付打包 App 后用 `open dist/xxx.app` 启动时，**必须 `sleep 2 && ps aux | grep xxx.app` 验证进程真实存在**——`open` 返回成功不代表 App 起来了；本会话两次遇到 open 后无进程。
- **适用**：macOS（Darwin 25.x）/ Claude Code 会话里交付/重启本机打包应用的工作流。

## 🔶 `open` 返回成功但进程不存在（2026-09-23～09-24 两次）

- **当前推断**：`open` 成功返回与 App 真正驻留运行没有因果关系。已观察两次：
  1. 2026-09-22：`open dist/WhatShot.app` → 用户反馈"没看到"，核对 `ps` 无进程、无崩溃日志（DiagnosticReports 无 WhatShot 记录）、`/Applications` 与 `~/Applications` 无旧包冲突；重新 `open` 后进程出现（路径确认为 dist 新包）。
  2. 2026-09-24：部署验收轮 `open` 后再次无进程（`ps aux | grep WhatShot.app` 为空），重新 `open` 后进程出现。
- **已排除项**：闪退（无崩溃日志）；旧实例抢占（LaunchServices 激活已存在进程——无进程可抢占）；旧包路径混淆（进程路径核对为 dist 新包）。
- **原因**：**暂未核实**。候选：open 与进程启动之间的竞态、窗口创建失败退出、Gatekeeper 二次校验、用户侧误关——均未证实，不冒充结论。
- **下一步验证动作**：再遇时当轮执行：
  ```bash
  open dist/WhatShot.app
  sleep 3
  ps aux | grep "WhatShot.app" | grep -v grep || echo "进程不存在"
  log show --predicate 'process == "WhatShot"' --last 5m --style compact | tail -20
  ```
  若 log 为空则 open 根本未触发启动；若有退出记录则看退出原因（SIGKILL/异常）。
- **为何值得继续**：本项目交付流程以 dist 包 + open 为常态动作，"以为启动了、用户看到旧状态或空窗"会造成误诊断（2026-09-22 用户报"没看到"实际就是此坑的下游）。

> 若 30 天后仍未验证：建议安排一次带 log 采集的复现，或按实际不再复现改为 ⛔/删。