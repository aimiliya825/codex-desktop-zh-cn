# Changelog

本项目遵循语义化版本；日期格式为 `YYYY-MM-DD`。

## [1.1.0] - 2026-10-30

真机适配 Codex Desktop `26.1027.3384.0`（Microsoft Store 自动升级后的版本）。

### 新增

- 启动后先等待官方 locale 生效（默认最多 30 秒）：26.1027+ 官方 i18n 读取
  `localeOverride` 后约 10~30 秒自动加载中文，此时跳过运行时注入与页面刷新
  （结果 JSON 中 `renderer.mode=official-locale`、`skippedInjection=true`）。
- 注入分支的验证窗口从 30 秒延长到 90 秒并持续轮询，避免应用启动较慢时误判 `partial`。
- 结果 JSON 新增 `renderer.mode` / `renderer.preverify` / `renderer.skippedInjection`，
  检查项新增 `official-locale`。

### 修复

- 修复结果汇总面板读取有序字典（`[ordered]@{}`）失败，导致控制台误显示「结果：失败」的问题
  （`Get-ZhNestedValue` 增加 `IDictionary` 分支）。
- 修复缺少 `Write-ZhUserPause` 定义导致脚本末尾报错、退出码被改成 1 的问题。
- 修复 `assets/menu-translations.json` 大小写重复键导致 Windows PowerShell 5.1
  `ConvertFrom-Json` 解析失败的问题。
- 修复自测脚本对注释/文档的误报；新增「入口脚本引用的 Write-Zh* 均有定义」「嵌套取值」
  等测试（自测共 277 项全部通过）。

### 真机验证

- `26.1027.3384.0`：一键汉化 `exit=0`，`mode=official-locale`，中文 marker 8 项，
  中文字符 229+；还原脚本 `exit=0`（`config.toml` 恢复、备份清理）。
- `26.1023.6621.0`：运行时注入模式已验证（中文 marker 7 项，中文 229 字符）。

## [1.0.0] - 2026-10-30

首个公开版本：纯 PowerShell 5.1 + Node.js 的一键汉化脚本仓库。

### 新增

- `Install-CodexZh.ps1`：检测 → 备份并写 `config.toml` 的 `[desktop] localeOverride`
  → 安全关闭 Codex → `IApplicationActivationManager` 带调试参数激活 → 等待端口
  → 调用 `lib/cdp.mjs` 注入并验证 → 中文摘要 + JSON 结果。失败时自动降级 locale-only。
- `Launch-CodexZh.ps1`：已安装后再次以中文启动；不重复写配置；可识别本工具此前启动的
  中文会话（`ALREADY_RUNNING`）。
- `Restore-CodexZh.ps1`：优先从 `config.toml.bak-zhcn` 还原，否则精确删除
  `[desktop]` 段内的 `localeOverride` 行；不删除用户数据。
- `Diagnostics.ps1`：只读诊断（版本、AUMID、进程、config 脱敏摘要、端口、最近结果与日志），
  报告保存到 `%LOCALAPPDATA%\CodexZhCn\logs\diagnostics-*.txt`。
- `lib/cdp.mjs`：零 npm 依赖的 CDP 驱动（Node >= 22 内置 fetch / WebSocket）。
  渲染进程 target 打分发现、`Page.addScriptToEvaluateOnNewDocument`、
  bootstrap 等待、`location.reload()`、重连验证、主进程 inspector 菜单注入；
  超时/重试/错误分类；结果写入 `--result` JSON。
- `assets/`：`i18n-bootstrap.js`（Statsig 72216192 强制开启 + navigator 覆盖，
  增加多全局名探测与 setter 挂钩）、`locale-script.js`（刷新页面）、
  `menu-script.js`（原生菜单翻译 + `Menu.setApplicationMenu` hook）、
  `menu-translations.json`（142+ 条 Windows 菜单词条）。
- 批处理包装：`一键汉化.bat` / `启动汉化版.bat` / `还原原版.bat` / `诊断.bat`。
- `tests/SelfTest.ps1`：不启动 Codex 的静态 / 单元自测（脚本语法与编码、
  JSON 资产、Node 语法、config 写入/还原临时夹具、退出码映射、敏感信息扫描）。
- 文档：`README.md`（中文）、`README.en.md`、`docs/diagnostics.md`、
  `LICENSE`（MIT）、`THIRD_PARTY_NOTICES.md`、`.gitignore`。

### 兼容性说明（真机验证）

- **已验证版本：Codex Desktop `26.1023.6621.0`（Microsoft Store，Windows 11）**。
  注入后主窗口整页中文：菜单栏 文件/编辑/视图/帮助、侧栏 新聊天/插件/自动化任务、
  输入框 随心输入；CDP 验证 `documentElement.lang=zh-CN`、中文 marker 7 项、
  中文字符 229、英文 marker 0。
- 该版本属 26.900+ 受保护版本线：不修改任何官方文件；界面与原生菜单均由官方 i18n 覆盖。
- 该版本不开放主进程 `--inspect` 端口 —— **属正常现象**：菜单已由官方 i18n 覆盖，
  因此 `menu.status=not-needed`，不影响整体结果，不再据此判 partial。
- 注入流程按真机结论增强：枚举全部 Codex 渲染页面（主窗口 + detached-window），
  逐个注入；`location.reload()` 后**重新枚举 page targets 并逐个验证**取最优；
  注入完成后用 Win32 `ShowWindow` + `SetForegroundWindow` 显示并置前主窗口。
- 未实现「复制安装目录 + patched `app.asar`」路线：26.900+ 会做整包完整性校验，
  修改会导致应用数秒后退出（`0x80000003`）。

### 安全

- 不读取 `auth.json`、token、API key；不修改模型配置；不联网请求 OpenAI。
- 关闭 Codex 前做路径归属校验，强杀前复验 PID + 启动时间 + 路径；
  路径不可验证时默认中止。

### 已知限制

- 汉化仅在通过本工具启动的 Codex 会话中生效（无常驻进程、无启动项、无快捷方式劫持）。
- 每次 Codex 更新后建议重新运行「一键汉化」。
