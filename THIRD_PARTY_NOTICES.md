# Third-Party Notices

本项目（codex-desktop-zh）以 MIT 许可发布。以下第三方 MIT 项目的代码 / 机制 / 资源被
复制、改写或参考，特此保留其版权声明与许可信息。

This project is licensed under the MIT License. The following MIT-licensed projects were
used as references; portions of their code/resources were adapted. Their copyright
notices are preserved below.

---

## 1. shibaweidu/codex-desktop-zh

- 项目：https://github.com/shibaweidu/codex-desktop-zh
- 版本参考：v0.7.7
- 许可证：MIT
- 版权声明（原样保留）：
  - `Copyright (c) 2026 Codex Zh Launcher contributors`
- 本仓库中改写/复用的内容：
  - `assets/i18n-bootstrap.js`：Statsig 动态配置 `72216192` 强制开启 `enable_i18n` 的
    补丁思路与基础实现（本仓库增加了多全局对象名探测、属性 setter 挂钩、候选扫描等）。
  - `assets/menu-script.js`：主进程原生菜单翻译脚本与 `Menu.setApplicationMenu` hook
    的机制与基础实现（本仓库增加了 electron 加载途径与 hook 版本号）。
  - `assets/menu-translations.json`：菜单翻译字典的结构与部分词条（本仓库大幅扩充）。
  - C# 实现中的检测 / COM 激活 / CDP 客户端 / 进程关闭 / 验证脚本思路，被翻译改写为
    PowerShell 与 Node 实现。
- 原项目 LICENSE：

```
MIT License

Copyright (c) 2026 Codex Zh Launcher contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. ukinch605/codex-zh-cn-agent

- 项目：https://github.com/ukinch605/codex-zh-cn-agent
- 版本参考：v1.4.1
- 许可证：MIT
- 版权声明（原样保留）：
  - `Copyright (c) 2026 codex-zh-cn-agent contributors`
- 本仓库中改写/参考的内容：
  - `%USERPROFILE%\.codex\config.toml` 中 `[desktop] localeOverride = "zh-CN"` 的
    四分支写入、`.bak-zhcn` 备份与精确删除逻辑（`Set-ZhLocaleOverride` /
    `Restore-ZhConfigFile`，PowerShell 重新实现并区段感知）。
  - 26.900+ 受保护版本线判定与 locale-only 降级策略（`Test-ZhProtectedVersion`）。
  - 结果文件协议字段（`status` / `code` / `message` / `mode` / `updatedAt`）与
    错误码命名的设计参考。
- 原项目 LICENSE：

```
MIT License

Copyright (c) 2026 codex-zh-cn-agent contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. 明确未使用的内容

- **未**复制、解包、提取或再分发 Codex Desktop 的 `app.asar`、官方 `zh-CN` 语言包
  （`zh-CN.json` / `zh-CN-*.js`）、图标、菜单资源或任何其他 OpenAI 版权内容；
  中文界面来自用户本机已安装 Codex 的官方内置语言包，在运行时被加载。
- **未**使用 `Codex`、`ChatGPT`、`OpenAI` 商标与图标作为本项目品牌标识。
- **未**复制两个参考项目的 README 品牌/赞助/更新检查文案或项目身份信息。
- 参考项目的「复制安装目录 + patched `app.asar`」路线在本工具中**不实现**，
  因为 Codex 26.900+ 对 `app.asar` 做整包完整性校验，修改会导致应用退出。

---

## 4. 平台接口

`IApplicationActivationManager` / `ApplicationActivationManager` 的 COM GUID 与接口
定义是 Microsoft Windows 公共 API（文档化接口），不受版权保护；Chromium DevTools
Protocol 与 Electron 运行时接口为公开开发者接口。本项目对这些接口的使用属于
独立实现。
