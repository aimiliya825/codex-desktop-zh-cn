#requires -version 5.1
<#
  Install-CodexZh.ps1 - Codex Desktop 一键汉化

  流程：
    1. 检测 Codex Desktop（Store/MSIX 或便携版；不依赖 Appx cmdlet）；
    2. 备份并写入 %USERPROFILE%\.codex\config.toml 的 [desktop] localeOverride = "zh-CN"；
    3. 安全关闭正在运行的 Codex（优雅优先，失败中止，不盲杀）；
    4. 通过 IApplicationActivationManager 带调试参数激活 Codex；
    5. 等待 renderer 调试端口，调用 lib/cdp.mjs 注入官方 i18n 强制开关并刷新、验证；
    6. 尝试注入主进程原生菜单翻译（部分版本不支持 --inspect，此时菜单保持英文）；
    7. 输出结果 JSON、日志和退出码（0=完整，1=部分，2=失败）。

  本脚本不会修改 Codex 安装目录 / app.asar / WindowsApps 下任何文件，
  不会读取 auth.json、token 或修改模型配置。

  用法：
    双击「一键汉化.bat」，或在 PowerShell 中执行：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexZh.ps1
    可选参数：
      -Yes                跳过交互确认（自动关闭并重启 Codex）
      -LocaleOnly         仅写官方语言设置（不启动注入；适用于没有 Node 的环境）
      -CodexPath <path>   显式指定 Codex.exe / ChatGPT.exe 或安装目录
      -NoPause            结束后不暂停（适合自动化）
      -AllowUnverified    遇到无法验证路径的 Codex 进程时仍继续（默认中止）

  Licensed under the MIT License.
#>
[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [switch]$Yes,
    [switch]$LocaleOnly,
    [switch]$NoPause,
    [switch]$AllowUnverified
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 2

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
} catch {
    Write-Host ('无法加载 lib\Common.ps1: ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
}

function Invoke-ZhInstallMain {
    Initialize-ZhConsole
    Write-ZhBanner -Subtitle '一键汉化（安装）'
    $logFile = Initialize-ZhLog -Name 'install'
    Write-ZhLog 'INFO' '===== Install-CodexZh 开始 ====='
    Write-ZhLog 'INFO' ('参数: Yes={0} LocaleOnly={1} CodexPath={2} AllowUnverified={3}' -f [bool]$Yes, [bool]$LocaleOnly, $CodexPath, [bool]$AllowUnverified)

    $result = New-ZhActionResult -Action 'install'
    $result.startedAt = Get-ZhIsoTimestamp
    $result.logs.logFile = $logFile
    $configPath = Get-ZhConfigPath
    $result.configPath = $configPath

    # ---------------------------------------------------------------
    # 1. 检测
    # ---------------------------------------------------------------
    Write-ZhStep '检测 Codex Desktop 安装'
    $install = Get-ZhCodexInstall -PreferredPath $CodexPath
    if ($null -eq $install -or -not $install.IsValid) {
        Write-ZhBad '未检测到可用的 Codex Desktop 安装。'
        Write-ZhInfo '请先通过 Microsoft Store 安装 Codex Desktop（包名 OpenAI.Codex）。'
        Get-ZhDetectionTrace | ForEach-Object { Write-ZhDetail $_ }
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'CODEX_NOT_FOUND'
        $result.message = '未检测到 Codex Desktop。请先安装 Microsoft Store 版 Codex，或使用 -CodexPath 指定便携版路径。'
        $result.errors += 'CODEX_NOT_FOUND'
        $saved = Save-ZhActionResult -Action 'install' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Write-ZhLog 'ERROR' '未检测到 Codex Desktop'
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }
    Write-ZhOk ('检测到 Codex Desktop {0}（{1}）' -f $install.Version, $install.Kind)
    Write-ZhDetail ('安装位置: ' + $install.InstallLocation)
    Write-ZhDetail ('可执行文件: ' + $install.ExecutablePath)
    if ($install.IsStore) { Write-ZhDetail ('AUMID: ' + $install.Aumid) }
    if ($install.IsProtectedLine) {
        Write-ZhDetail '版本线 26.900+：本工具不修改 app.asar（整包完整性校验会导致应用退出），仅运行时注入 + 官方语言设置。'
    }
    $result.codex = [ordered]@{
        found             = $true
        kind              = $install.Kind
        version           = $install.Version
        aumid             = $install.Aumid
        installLocation   = $install.InstallLocation
        executable        = $install.ExecutablePath
        source            = $install.Source
        protectedVersionLine = [bool]$install.IsProtectedLine
    }
    Write-ZhLog 'INFO' ('检测结果: kind={0} version={1} aumid={2} install={3}' -f $install.Kind, $install.Version, $install.Aumid, $install.InstallLocation)

    # ---------------------------------------------------------------
    # 2. Node 检查（决定完整模式还是 locale-only 降级）
    # ---------------------------------------------------------------
    Write-ZhStep '检查 Node.js 运行时'
    $node = Get-ZhNodeInfo
    $effectiveMode = 'runtime'
    if ($LocaleOnly) {
        $effectiveMode = 'locale-only'
        Write-ZhInfo '已指定 -LocaleOnly：只写官方语言设置，不启动运行时注入。'
    } elseif (-not $node.Ok) {
        $effectiveMode = 'locale-only'
        Write-ZhWarn $node.Message
        Write-ZhInfo '将自动降级为 locale-only 模式（只写官方语言设置）。中文界面是否出现取决于官方 i18n 是否放开。'
        Write-ZhLog 'WARN' ('Node 不可用，降级 locale-only: ' + $node.Message)
    } else {
        Write-ZhOk $node.Message
    }

    # ---------------------------------------------------------------
    # 3. 备份并写入 config.toml（唯一会写入的官方配置文件）
    # ---------------------------------------------------------------
    Write-ZhStep ('写入官方语言设置（{0} 的 [desktop] localeOverride）' -f $configPath)
    $configResult = Set-ZhLocaleOverride -ConfigPath $configPath -Locale $script:CodexZhDefaultLocale
    $result.config = [ordered]@{
        configPath        = $configResult.ConfigPath
        backupPath        = $configResult.BackupPath
        created           = [bool]$configResult.Created
        modified          = [bool]$configResult.Modified
        alreadyConfigured = [bool]$configResult.AlreadyConfigured
        verified          = [bool]$configResult.Verified
        locale            = $script:CodexZhDefaultLocale
        previousValue     = $configResult.PreviousValue
    }
    if (-not $configResult.Verified) {
        Write-ZhBad ('写入语言设置失败: ' + $configResult.Error)
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'CONFIG_WRITE_FAILED'
        $result.message = '写入 config.toml 的 [desktop] localeOverride 失败：' + $configResult.Error
        $result.errors += $configResult.Error
        Save-ZhActionResult -Action 'install' -Result $result | Out-Null
        Show-ZhResultSummary -Result $result
        Write-ZhLog 'ERROR' $result.message
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }
    if ($configResult.Modified) {
        Write-ZhOk ('已写入 localeOverride = "{0}"（原配置备份: {1}）' -f $script:CodexZhDefaultLocale, $configResult.BackupPath)
    } else {
        Write-ZhOk ('config.toml 已包含 localeOverride = "{0}"，无需修改' -f $script:CodexZhDefaultLocale)
    }
    Update-ZhState -Changes @{
        installed          = $true
        installedAt        = Get-ZhIsoTimestamp
        locale             = $script:CodexZhDefaultLocale
        codexVersion       = $install.Version
        aumid              = $install.Aumid
        installLocation    = $install.InstallLocation
        executable         = $install.ExecutablePath
        configPath         = $configPath
        configBackupPath   = $configResult.BackupPath
        configModified     = [bool]$configResult.Modified
        configCreated      = [bool]$configResult.Created
        configAlreadyZhCn  = [bool]$configResult.AlreadyConfigured
        mode               = $effectiveMode
    } | Out-Null

    # ---------------------------------------------------------------
    # 4. locale-only 分支
    # ---------------------------------------------------------------
    if ($effectiveMode -eq 'locale-only') {
        Write-ZhStep '以 locale-only 模式完成安装'
        $scan = Get-ZhCodexProcessScan -Install $install
        $restartDeclined = $false
        if ($scan.TotalPotential -gt 0) {
            if (-not $Yes) {
                $confirmed = Read-ZhConfirmation -Prompt ('检测到 {0} 个 Codex 进程正在运行，需要重启 Codex 才能应用语言设置。是否立即关闭并重启？' -f $scan.TotalPotential) -DefaultYes
                if (-not $confirmed) { $restartDeclined = $true }
            }
            if (-not $restartDeclined) {
                $closeReport = Close-ZhCodexSafely -Install $install -AllowUnverified:$AllowUnverified
                $result.shutdown = [ordered]@{
                    success = [bool]$closeReport.Success
                    aborted = [bool]$closeReport.Aborted
                    reason  = $closeReport.Reason
                    message = $closeReport.Message
                    initialVerified = $closeReport.InitialVerified
                    gracefulExited  = $closeReport.GracefulExited
                    forceTerminated = $closeReport.ForceTerminated
                    remainingVerified = $closeReport.RemainingVerified
                }
                if (-not $closeReport.Success) {
                    Write-ZhBad $closeReport.Message
                    $result.status = 'failed'
                    $result.exitCode = 2
                    $result.code = 'SHUTDOWN_FAILED'
                    $result.mode = 'locale-only'
                    $result.message = $closeReport.Message
                    Save-ZhActionResult -Action 'install' -Result $result | Out-Null
                    Show-ZhResultSummary -Result $result
                    Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
                    Write-ZhUserPause -NoPause:$NoPause
                    return 2
                }
                Start-Sleep -Milliseconds 1000
            }
        }
        if (-not $restartDeclined) {
            $startResult = Start-ZhOriginalCodex -Install $install
            if ($startResult.Ok) {
                Write-ZhOk $startResult.Message
                [void](Show-ZhCodexWindows -Install $install)
            } else {
                Write-ZhWarn ('未能自动启动 Codex：' + $startResult.Message)
            }
        }
        if ($LocaleOnly) {
            $result.status = 'complete'
            $result.exitCode = 0
            $result.code = 'LOCALE_ONLY'
            $result.message = '已按 -LocaleOnly 写入官方语言设置。中文化效果取决于官方 i18n；如需完整运行时汉化，请安装 Node.js >= 22 后重新运行本脚本。'
        } elseif ($restartDeclined) {
            $result.status = 'partial'
            $result.exitCode = 1
            $result.code = 'RESTART_DECLINED'
            $result.message = '语言设置已写入，但 Codex 尚未重启；请手动完全退出并重新打开 Codex 以应用语言设置。'
        } else {
            $result.status = 'partial'
            $result.exitCode = 1
            $result.code = 'LOCALE_ONLY_FALLBACK'
            $result.message = '已降级为 locale-only：语言设置已写入。中文界面是否出现取决于官方 i18n；完整汉化需要 Node.js >= 22 且 Codex 支持调试端口。'
            $result.warnings += $node.Message
        }
        $result.mode = 'locale-only'
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'install' -Result $result
        $result.logs.resultFile = $saved
        Update-ZhState -Changes @{ lastInstallAt = Get-ZhIsoTimestamp; lastInstallStatus = $result.status; lastInstallCode = $result.code; mode = $result.mode } | Out-Null
        Write-ZhLog 'INFO' ('locale-only 完成: status={0} code={1}' -f $result.status, $result.code)
        Show-ZhResultSummary -Result $result
        Write-ZhInfo ('日志文件: ' + $logFile)
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return [int]$result.exitCode
    }

    # ---------------------------------------------------------------
    # 5. 完整运行时模式：关闭旧进程
    # ---------------------------------------------------------------
    $scan = Get-ZhCodexProcessScan -Install $install
    if ($scan.TotalPotential -gt 0) {
        Write-ZhStep ('准备重启 Codex（检测到 {0} 个进程）' -f $scan.TotalPotential)
        $proceed = $true
        if (-not $Yes) {
            $proceed = Read-ZhConfirmation -Prompt '汉化需要关闭并重启 Codex。请先保存正在编辑的内容；是否继续？' -DefaultYes
        }
        if (-not $proceed) {
            $result.status = 'failed'
            $result.exitCode = 2
            $result.code = 'USER_CANCELLED'
            $result.mode = 'locale-only'
            $result.message = '用户取消重启。语言设置已写入 config.toml，下次正常启动 Codex 时生效（仅 locale-only，菜单不汉化）。'
            $result.finishedAt = Get-ZhIsoTimestamp
            Save-ZhActionResult -Action 'install' -Result $result | Out-Null
            Show-ZhResultSummary -Result $result
            Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
            Write-ZhUserPause -NoPause:$NoPause
            return 2
        }
        $closeReport = Close-ZhCodexSafely -Install $install -AllowUnverified:$AllowUnverified
        $result.shutdown = [ordered]@{
            success           = [bool]$closeReport.Success
            aborted           = [bool]$closeReport.Aborted
            reason            = $closeReport.Reason
            message           = $closeReport.Message
            initialVerified   = $closeReport.InitialVerified
            initialUnverified = $closeReport.InitialUnverified
            gracefulRequested = $closeReport.GracefulRequested
            gracefulExited    = $closeReport.GracefulExited
            forceAttempted    = $closeReport.ForceAttempted
            forceTerminated   = $closeReport.ForceTerminated
            remainingVerified = $closeReport.RemainingVerified
            errors            = @($closeReport.Errors)
        }
        if (-not $closeReport.Success) {
            Write-ZhBad $closeReport.Message
            foreach ($closeError in $closeReport.Errors) { Write-ZhDetail $closeError }
            $result.status = 'failed'
            $result.exitCode = 2
            $result.code = 'SHUTDOWN_FAILED'
            $result.mode = 'runtime'
            $result.message = $closeReport.Message + '（已停止自动重启，避免双实例；语言设置已写入，可稍后重试。）'
            $result.errors += @($closeReport.Errors)
            $result.finishedAt = Get-ZhIsoTimestamp
            Save-ZhActionResult -Action 'install' -Result $result | Out-Null
            Show-ZhResultSummary -Result $result
            Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
            Write-ZhUserPause -NoPause:$NoPause
            return 2
        }
        Write-ZhOk $closeReport.Message
        Start-Sleep -Milliseconds 1200
    } else {
        Write-ZhInfo 'Codex 当前未运行，无需关闭。'
    }

    # ---------------------------------------------------------------
    # 6. 启动 + 注入 + 验证
    # ---------------------------------------------------------------
    Write-ZhStep '以中文模式启动 Codex 并注入官方语言包'
    $session = Start-ZhRuntimeSession -Install $install -MaxAttempts 2 -RendererReadySec 25
    $result.ports = $session.Ports
    if ($null -ne $session.CdpResult) {
        $result.renderer = $session.CdpResult.renderer
        $result.menu = $session.CdpResult.menu
        $result.checks = @($session.CdpResult.checks)
        $result.logs.cdpResultFile = $session.CdpResultFile
        if ($session.CdpResult.warnings) { $result.warnings += @($session.CdpResult.warnings) }
        if ($session.CdpResult.errors) { $result.errors += @($session.CdpResult.errors) }
    }
    $result.finishedAt = Get-ZhIsoTimestamp

    if ($session.Ok) {
        $result.status = $session.Status
        $result.exitCode = [int]$session.ExitCode
        $result.code = $session.Code
        $result.mode = 'runtime'
        $menuStatus = [string](Get-ZhNestedValue -Object $session.CdpResult -Path 'menu.status' -Default '')
        if ($result.status -eq 'complete') {
            $result.message = '汉化完成：中文界面已生效（官方 i18n 同时覆盖了原生菜单）。'
            if ($menuStatus -eq 'not-needed' -or $menuStatus -eq 'unavailable' -or $menuStatus -eq 'skipped') {
                $result.message = $result.message + ' 主进程 inspector 未开放属正常现象，不需要额外注入菜单。'
            }
        } elseif ($result.status -eq 'partial') {
            $result.message = '中文界面已部分生效（部分页面尚未确认中文）；请查看结果 JSON 中的 renderer.verified 与日志。'
        } else {
            $result.message = '中文界面状态未确认；请查看日志与结果 JSON。'
        }
        Write-ZhLog 'INFO' ('运行时汉化成功: status={0} code={1}' -f $result.status, $result.code)
    } else {
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = $session.Code
        $result.mode = 'locale-only'
        $detail = $session.Message
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '运行时注入未完成。' }
        $result.message = ('运行时注入失败（{0}）：{1} 已保留 localeOverride 作为 locale-only 降级；请查看日志后重试。' -f $session.Code, $detail)
        $result.errors += $detail
        Write-ZhBad $detail
        $scanAfterFailure = Get-ZhCodexProcessScan -Install $install
        if ($scanAfterFailure.TotalPotential -eq 0) {
            Write-ZhInfo '尝试以普通方式启动 Codex（locale-only）...'
            $fallbackStart = Start-ZhOriginalCodex -Install $install
            if ($fallbackStart.Ok) {
                Write-ZhOk $fallbackStart.Message
                [void](Show-ZhCodexWindows -Install $install)
            } else {
                Write-ZhWarn ('普通启动也失败：' + $fallbackStart.Message)
            }
        } else {
            Write-ZhInfo 'Codex 进程仍在运行，保留当前窗口；重启后 locale-only 设置生效。'
            [void](Show-ZhCodexWindows -Install $install)
        }
    }

    $saved = Save-ZhActionResult -Action 'install' -Result $result
    $result.logs.resultFile = $saved
    Update-ZhState -Changes @{
        lastInstallAt     = Get-ZhIsoTimestamp
        lastInstallStatus = $result.status
        lastInstallCode   = $result.code
        mode              = $result.mode
    } | Out-Null
    Show-ZhResultSummary -Result $result
    Write-ZhInfo ('日志文件: ' + $logFile)
    Write-ZhInfo ('结果文件: ' + $saved)
    if ($result.mode -eq 'locale-only' -and -not $LocaleOnly) {
        Write-ZhInfo 'locale-only 降级说明：仅写官方 localeOverride，界面是否中文取决于官方 i18n 开关；不会修改任何官方文件。'
    }
    Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
    Write-ZhUserPause -NoPause:$NoPause
    return [int]$result.exitCode
}

$script:ExitCode = Invoke-ZhInstallMain
if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
