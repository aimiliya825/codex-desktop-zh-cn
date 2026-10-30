# 诊断报告说明（Diagnostics.ps1）

`诊断.bat` / `Diagnostics.ps1` 是**只读**诊断工具：不启动、不关闭、不注入 Codex，
不写 `config.toml`，不修改注册表。它只会在本工具自己的目录写入一份报告：

```
%LOCALAPPDATA%\CodexZhCn\logs\diagnostics-<时间戳>.txt
```

把这份文件（或其中的内容）附到 Issue 里即可，它**不包含**敏感信息。

---

## 报告包含什么

| 报告区块 | 内容 | 说明 |
|---|---|---|
| 环境 | PowerShell 版本/edition、OS 版本、系统区域、控制台代码页、是否管理员 | 用于定位环境兼容问题 |
| Node.js | 版本、路径、是否满足 >= 22 | 运行时注入的前置条件 |
| Codex 检测 | 类型（Store/便携版）、版本、安装位置、可执行文件、AUMID、包族名、检测来源、是否 26.900+ 受保护线 | 含完整检测过程追踪（每个回退步骤） |
| 进程 | 可验证进程数/列表（PID、是否有窗口、路径）、路径不可验证的候选、被忽略的其他路径进程 | 用于判断关闭/重启失败原因 |
| 语言配置（脱敏） | `config.toml` 是否存在/大小/最后修改、包含哪些段名、`[desktop] localeOverride` 的值、`.bak-zhcn` 是否存在 | **不打印 config.toml 其他行内容** |
| 安装状态 | state.json 摘要：是否已安装、模式、最近安装/启动/还原结果、记录的调试端口 | 判断上次操作结果 |
| 端口探测 | renderer / inspector 端口是否开放 | 只在本工具启动的会话中存在 |
| 最近结果 | install/launch/restore 结果 JSON 的 status / code / message | 一眼看到上次失败原因 |
| 最近日志 | install / launch / restore / cdp 日志末尾 25 行 | 含关键阶段耗时与错误 |

## 脱敏策略

- **永远不读取/不打印**：`auth.json`、token、API key、会话内容、模型配置。
- `config.toml` 只输出「段名列表」与 `localeOverride` 一项，其他行内容不落盘。
- 路径中的 `%USERPROFILE%`、`%USERNAME%` 会被替换为环境变量占位符。
- 日志由本工具自己写入，不含敏感数据。

## 常见诊断结论

| 现象 | 报告中要看哪里 |
|---|---|
| 界面英文 | `最近结果` 的 `code`；若是 `CDP_NOT_READY` 看端口探测与日志中「等待 renderer 调试端口」 |
| 菜单英文 | `inspector 端口: 未开放（本版本不支持主进程 inspector，菜单不汉化属预期）` |
| 无法关闭 Codex | `进程` 区块的「路径不可验证的候选进程」 |
| 语言设置没生效 | `语言配置` 区块的 `[desktop] localeOverride` 值；`备份文件` 是否存在 |
| 不知道上次做了什么 | `最近结果` + `state.json` 摘要 |

## 手动收集（命令行）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1 -NoPause
```

或输出 JSON 摘要便于自动化处理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1 -NoPause -Json
```

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 检测到 Codex，诊断完成 |
| 1 | 未检测到 Codex（报告仍会生成，便于确认安装状态） |
| 2 | 诊断过程异常 |
