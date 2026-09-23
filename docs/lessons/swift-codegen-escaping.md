# Swift 代码生成与转义坑（LLM/heredoc 工作流）

结论速览：
- **方案**：LLM 批量改 Swift 优先用编辑工具做精准小段替换；必须用 heredoc+python 批量替换时，写完立刻 `od -c` 查真实字节（尤其 `\(` 插值与 keypath `\.`），别信"我写的就是对的"。
- **适用**：macOS / Claude Code 会话中用 Bash heredoc + python 修改或生成 Swift 源码的场景。

## ✅ 字符串字面量双反斜杠让 `\($0)` 插值失效（2026-09-22）

- **为何值得记**：本会话踩 2 次同型坑（keypath 双反斜杠 5 处、插值 `\\($0)` 1 处），每次都靠编译错+字节级检查才定位。
- **最终方案**：写完字节级自检：
  ```bash
  od -c 文件 | head -50   # 看真实字节
  grep -ac '\\\\(' 文件   # 数双反斜杠插值
  ```
  文件真实字节为 `\\(`（反斜杠×2 + 括号）即中招。
- **为什么这样做**：Swift 字符串 `"\\($0)"` 中 `\\` 先解析为字面反斜杠，`($0)` 变普通文本——插值失效、闭包被推断为 0 参。编译器报 `contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored`（ExternalHeatTabView.swift:210 实测），报错完全不指向转义问题，从报错反推极难。
- **适用条件**：macOS / Swift 6 工具链；任何"经多层转义到达文件"的代码生成路径（heredoc、python 替换、Write 工具的手写转义）。
- **验证证据**：od -c 显示文件真实字节为 `\\($0)`；全部修正为 `\($0)` 后编译通过（2026-09-22，6 处）。
- **易错点**：报错定位在闭包/插值行但不指向转义；`grep` 普通模式看不出来（文件里是单/双反斜杠混合），必须字节级看。

## ✅ heredoc + python 批量替换 Swift 的三重转义坑（2026-09-22）

- **为何值得记**：本会话因 heredoc 转义反复返工 4+ 次（keypath 双反斜杠、插值失效、三引号嵌套 SyntaxError、`\\($0)` 6 处），是本次接入最大的时间损耗之一。
- **最终方案**：能少用就少用。批量修改优先级：
  1. 编辑工具精准替换（小段、锚点唯一）
  2. 必须 heredoc 时，python 内用原始字符串或提前构造变量，不嵌套三引号套三引号
  3. 写入后立刻字节级验证（od -c / grep -c）
- **失败路径**（⛔ 同源）：
  - `python3 - <<'EOF'` heredoc 内写 `"""..."""` 包含 Swift 三引号文档注释 → python `SyntaxError: EOL while scanning string literal`——三引号嵌套必须换行分隔或用单引号字符串拼接。
  - heredoc 里 `\\\\.` 期望匹配文件单反斜杠——python 字符串 `\\\\` = 两个反斜杠字符，目标串匹配失败替换静默无效（`s.replace` 无异常无提示）——**替换后必须验证替换发生**（前后计数或 grep）。
- **为什么这样做**：JSON→heredoc→python→文件共四层转义，每层都可能差一个反斜杠；写错的表现是"编译错"或"静默替换失败"，都难以从现象反推。
- **验证证据**：2026-09-22 会话多轮（ExternalHeatTabView 初稿 rankKey/双反斜杠插值、SwiftUI ForEach 修复脚本等）；python `SyntaxError: EOL while scanning string literal` 原样保留。
- **易错点**：`s.replace` 无命中不报错——批量替换后必须打印验证（before/after 计数），否则静默无效。