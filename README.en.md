# codex-desktop-zh — Codex Desktop Chinese UI launcher

A zero-dependency **PowerShell 5.1 + Node.js** tool that switches the Microsoft Store
edition of **Codex Desktop** to Simplified Chinese at runtime.

It does **not** modify `WindowsApps`, does **not** touch `app.asar`, and does **not** copy
the installation directory. Localization is achieved by runtime-injecting the app's own
official i18n bundle plus writing the official `localeOverride` setting. Everything is
reversible with one click.

> Unofficial community project. Not affiliated with or endorsed by OpenAI or Microsoft.

---

## Verified configuration

| Item | Result |
|---|---|
| Codex Desktop | **26.1023.6621.0 / 26.1027.3384.0** (Microsoft Store, Windows 11 x64) |
| UI language | Full Simplified Chinese: menu bar **文件 / 编辑 / 视图 / 帮助**, sidebar **新聊天 / 插件 / 自动化任务**, input placeholder **随心输入** |
| CDP verification | `documentElement.lang=zh-CN`, 8 Chinese markers, 229+ Chinese characters, 0 English markers |
| How it takes effect | 26.1027+: the official i18n loads Chinese by itself 10~30 s after launch (`mode=official-locale`); 26.1023: runtime injection forces the gate (`mode=runtime-injection`). Neither edits installed files |
| Official i18n | Codex's bundled `zh-CN` resources load successfully; **native menus are covered by the official i18n**, no main-process injection needed |
| Main-process inspector | `--inspect` is not exposed on this build — **normal**, not a failure (menus come from official i18n) |

---

## Important limitations

1. **Localized through runtime / official locale**: on 26.1027+ the official i18n reads
   `localeOverride` and usually switches to Chinese 10~30 s after launch. On older builds
   (e.g. 26.1023) only the Codex session started through `Install-CodexZh.ps1` /
   `Launch-CodexZh.ps1` (or the `.bat` wrappers) is localized. Launching Codex from the
   Start menu may show English again; use 「启动汉化版.bat」 for another Chinese session.
2. **Native menus come from the official i18n**: on the verified build the menu bar turns
   Chinese together with the UI. Main-process menu injection (`assets/menu-script.js`) is an
   optional enhancement for versions whose official i18n does not cover some items. A closed
   `--inspect` port is normal and never causes a "partial" verdict.
3. **26.900+ builds verify `app.asar` integrity**: any byte change makes the app exit
   within seconds (`0x80000003`). This tool never edits official files.
4. **Node.js >= 22 is required** for runtime mode; without Node it degrades to locale-only.

---

## How it works

```
1. Detect Codex        HKCU\...\AppModel\Repository\Packages (Appx-free) -> Appx module
                       -> shell:AppsFolder -> portable paths -> running process
2. Write config        %USERPROFILE%\.codex\config.toml
                       [desktop]
                       localeOverride = "zh-CN"     (official setting, backed up first)
3. Safe shutdown       graceful CloseMainWindow -> revalidate PID+StartTime+Path -> kill
                       unverifiable processes abort the operation (never blind-kill)
4. Activate            IApplicationActivationManager.ActivateApplication(AUMID,
                       "--remote-debugging-port=<P1> --inspect=127.0.0.1:<P2> --lang=zh-CN")
5. Inject (cdp.mjs)    first wait up to 30 s for the official locale to take effect; if the UI
                       is already Chinese, skip injection entirely (mode=official-locale).
                       Otherwise: enumerate all Codex renderer pages (main index.html first,
                       plus detached windows) -> per-page Page.addScriptToEvaluateOnNewDocument(
                       i18n-bootstrap.js) -> Runtime.evaluate(bootstrap + wait) ->
                       location.reload() -> re-enumerate ALL page targets after the reload and
                       verify each for up to 90 s, keeping the best result
                       -> optional main-process inspector menu script (not required on the
                          verified build: menu.status=not-needed)
6. Show & focus        Win32 ShowWindow + SetForegroundWindow on Codex main windows
                       (PID-verified) so the app does not stay hidden in the background
7. Report              JSON result + Chinese summary + exit code 0/1/2
```

Why Chinese appears: Codex ships an offline `zh-CN` bundle gated by Statsig dynamic config
`72216192` (`enable_i18n`, default `false`). `i18n-bootstrap.js` wraps the Statsig client
(`getDynamicConfig` / `getLayer`), forces `enable_i18n = true`, `locale_source = 'SYSTEM'`,
and overrides `navigator.language`. Together with the official `localeOverride` setting,
the bundled Chinese resources (including menu labels) load in memory. Nothing is written
to disk except the official config key.

---

## Safety

| Item | Behavior |
|---|---|
| Official files | Never modified. No writes under `WindowsApps`, no `app.asar` edits, no directory copies |
| Files written | Only `%USERPROFILE%\.codex\config.toml` key `[desktop] localeOverride`, backup `config.toml.bak-zhcn` |
| Tool data | `%LOCALAPPDATA%\CodexZhCn\` (logs / results / state.json) |
| Never touched | `auth.json`, tokens, API keys, chat history, model settings |
| Process shutdown | Only processes whose path belongs to the current install; unverifiable paths abort; PID+start-time revalidation before force-kill |
| Reversible | `Restore-CodexZh.ps1` restores the backup or removes the exact key line; user data untouched |
| Privileges | No admin rights, no UAC prompt |

---

## Requirements

- Windows 10/11 x64
- Codex Desktop from Microsoft Store (or a portable build)
- Windows PowerShell 5.1 (built in)
- Node.js >= 22 (runtime injection; zero npm dependencies)

---

## Usage

```powershell
git clone https://github.com/<your-name>/codex-desktop-zh.git
cd codex-desktop-zh

# 1) one-click install & launch (Chinese UI)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexZh.ps1

# 2) later launches (does not rewrite config)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-CodexZh.ps1

# 3) restore original language settings
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-CodexZh.ps1

# 4) read-only diagnostics
powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1
```

Double-clickable wrappers (Chinese file names):
`一键汉化.bat` (install), `启动汉化版.bat` (launch), `还原原版.bat` (restore),
`诊断.bat` (diagnostics).

Useful switches: `-Yes` (skip confirmation), `-LocaleOnly` (write config only),
`-CodexPath <path>` (portable build), `-NoPause` (automation).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Complete: Chinese UI confirmed (native menus covered by official i18n — expected on 26.1023) |
| `1` | Partial: UI only partially Chinese / not fully confirmed (see `renderer.verified` and logs) |
| `2` | Failed: injection or shutdown/launch failed; result JSON contains locale-only fallback and log paths |

Logs and results: `%LOCALAPPDATA%\CodexZhCn\logs` and `...\results`.
See [docs/diagnostics.md](docs/diagnostics.md) for report fields.

### Self test (does not launch Codex)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\SelfTest.ps1
```

---

## FAQ highlights

- **Menus still English?** On 26.1023 the official i18n covers the menu bar; no injection is
  needed. The tool reports `menu.status=not-needed` and `--inspect` being closed is normal.
- **Why launch via the script every time?** Localization is runtime-only: no persistent
  changes, no startup entries, no shortcut hijacking.
- **Window seems hidden?** The script shows and foregrounds the main window with Win32
  `ShowWindow` + `SetForegroundWindow` after injection.
- **Does it touch my account/model/chat data?** No. Only one official language key is written.

---

## Compatibility

| Version | UI localization | Native menus |
|---|---|---|
| `26.1023.6621.0` (**verified**) | yes, via CDP | yes — covered by official i18n |
| other `26.900+` | depends on CDP port | usually official i18n |
| `< 26.900` | same mechanism | same mechanism |
| portable builds | same mechanism | same mechanism (`-CodexPath`) |

After a Codex update, run the installer again (idempotent).

---

## Uninstall

1. Run `Restore-CodexZh.ps1` (restores language settings, keeps user data);
2. Delete this repository folder;
3. Optionally delete `%LOCALAPPDATA%\CodexZhCn\`;
4. No need to uninstall or reinstall Codex — official files were never modified.

---

## License & credits

MIT — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Mechanism and some assets are adapted from
[shibaweidu/codex-desktop-zh](https://github.com/shibaweidu/codex-desktop-zh) and
[ukinch605/codex-zh-cn-agent](https://github.com/ukinch605/codex-zh-cn-agent), both MIT.
No OpenAI/Codex official binaries or language-pack files are bundled.

---

## Disclaimer

Third-party, unofficial tool; not affiliated with or endorsed by OpenAI or Microsoft.
Localization uses the Chromium DevTools Protocol and Electron runtime, which is a
developer/debugging technique and may break with Codex updates. Use at your own risk.
If Codex misbehaves after an update, run `Restore-CodexZh.ps1` and fully quit Codex.
