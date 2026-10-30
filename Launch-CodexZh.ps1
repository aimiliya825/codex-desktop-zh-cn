#requires -version 5.1
<#
  Launch-CodexZh.ps1 - 已安装后再次以中文模式启动 Codex

  前提：已运行过 Install-CodexZh.ps1（config.toml 已写入 localeOverride）。
  本脚本不会再写配置，只负责：
    - 若 Codex 未运行：以带调试参数的方式启动并注入中文界面；
    - 若 Codex 正在运行且是此前由本工具启动的中文会话：直接报告已在运行；
    - 若 Codex 正在运行但不是中文会话：询问后安全重启并注入。

  可选参数：
    -Yes        跳过交互确认
    -Restart    无条件关闭并重启 Codex
    -CodexPath  显式指定 Codex 路径
    -NoPause    结束后不暂停

  Licensed under the MIT License.
#>
[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [switch]$Yes,
    [switch]$Restart,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 2

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
} catch {
    Write-Host ('无法加载 lib\Common.ps1: ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
}

function Get-ZhPreviousSessionPorts {
    $state = Get-ZhState
    if ($null -eq $state) { return $null }
    $rendererPort = Get-ZhNestedValue -Object $state -Path 'lastRendererPort' -Default 0
    $inspectorPort = Get-ZhNestedValue -Object $state -Path 'lastInspectorPort' -Default 0
    $parsedRenderer = 0
    $parsedInspector = 0
    try { $parsedRenderer = [int]$rendererPort } catch { $parsedRenderer = 0 }
    try { $parsedInspector = [int]$inspectorPort } catch { $parsedInspector = 0 }
    if ($parsedRenderer -le 0) { return $null }
    return [pscustomobject]@{ Renderer = $parsedRenderer; Inspector = $parsedInspector }
}

function Invoke-ZhLaunchMain {
    Initialize-ZhConsole
    Write-ZhBanner -Subtitle '启动中文版（已安装）'
    $logFile = Initialize-ZhLog -Name 'launch'
    Write-ZhLog 'INFO' '===== Launch-CodexZh 开始 ====='

    $result = New-ZhActionResult -Action 'launch'
    $result.startedAt = Get-ZhIsoTimestamp
    $result.logs.logFile = $logFile

    # 1. 检测
    Write-ZhStep '检测 Codex Desktop 安装'
    $install = Get-ZhCodexInstall -PreferredPath $CodexPath
    if ($null -eq $install -or -not $install.IsValid) {
        Write-ZhBad '未检测到可用的 Codex Desktop 安装。'
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'CODEX_NOT_FOUND'
        $result.message = '未检测到 Codex Desktop，请先安装 Microsoft Store 版 Codex。'
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'launch' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }
    Write-ZhOk ('Codex Desktop {0}（{1}）' -f $install.Version, $install.Kind)
    $result.codex = [ordered]@{
        found                = $true
        kind                 = $install.Kind
        version              = $install.Version
        aumid                = $install.Aumid
        installLocation      = $install.InstallLocation
        executable           = $install.ExecutablePath
        source               = $install.Source
        protectedVersionLine = [bool]$install.IsProtectedLine
    }

    # 2. 安装状态检查
    Write-ZhStep '检查汉化安装状态'
    $installedCheck = Test-ZhInstalled
    $configCheck = Test-ZhLocaleOverride
    $result.configPath = $configCheck.ConfigPath
    $configSummary = Get-ZhConfigSummary
    $result.config = [ordered]@{
        configPath        = $configCheck.ConfigPath
        verified          = [bool]$configCheck.Verified
        value             = $configCheck.Value
        backupExists      = [bool]$configSummary.BackupExists
        alreadyConfigured = $true
        modified          = $false
        locale            = $script:CodexZhDefaultLocale
    }
    if (-not $installedCheck.Installed) {
        Write-ZhBad '尚未安装汉化（config.toml 中没有 [desktop] localeOverride = "zh-CN"）。'
        Write-ZhInfo '请先运行「一键汉化.bat」或 Install-CodexZh.ps1。'
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'NOT_INSTALLED'
        $result.message = '尚未安装汉化，请先运行 Install-CodexZh.ps1（一键汉化）。'
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'launch' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }
    Write-ZhOk '已安装：config.toml 中 localeOverride = "zh-CN"'

    # 3. Node 检查
    $node = Get-ZhNodeInfo
    if (-not $node.Ok) {
        Write-ZhBad $node.Message
        Write-ZhInfo '没有 Node.js 无法进行运行时注入；可运行「一键汉化.bat -LocaleOnly」仅写语言设置。'
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'NODE_UNAVAILABLE'
        $result.message = $node.Message
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'launch' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }
    Write-ZhOk $node.Message

    # 4. 已运行处理
    $scan = Get-ZhCodexProcessScan -Install $install
    $needRestart = $true
    if ($scan.TotalPotential -gt 0 -and -not $Restart) {
        $previousPorts = Get-ZhPreviousSessionPorts
        if ($null -ne $previousPorts) {
            Write-ZhInfo ('检测到 Codex 正在运行，尝试确认是否为本工具启动的中文会话（端口 {0}）...' -f $previousPorts.Renderer)
            if (Wait-ZhRendererPort -Port $previousPorts.Renderer -TimeoutSec 2) {
                $cdpLogFile = Join-Path (Get-ZhLogDir) ('cdp-verify-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $verifyResultFile = Join-Path (Get-ZhResultDir) ('cdp-verify-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $verify = Invoke-ZhCdpDriver -ResultPath $verifyResultFile -RendererPort $previousPorts.Renderer -Mode 'verify' -LogPath $cdpLogFile
                $verifyStatus = [string](Get-ZhNestedValue -Object $verify.Result -Path 'verify.status' -Default '')
                if ($verify.ExitCode -eq 0 -and $verifyStatus -ne 'fail') {
                    Write-ZhOk 'Codex 中文会话已在运行，无需重启。'
                    [void](Show-ZhCodexWindows -Install $install)
                    $result.status = 'complete'
                    $result.exitCode = 0
                    $result.code = 'ALREADY_RUNNING'
                    $result.mode = 'runtime'
                    $result.message = 'Codex 中文会话已在运行（本工具此前启动）。'
                    $result.ports = [ordered]@{ renderer = $previousPorts.Renderer; inspector = $previousPorts.Inspector }
                    $result.renderer = [ordered]@{
                        verify = Get-ZhNestedValue -Object $verify.Result -Path 'verify'
                        target = Get-ZhNestedValue -Object $verify.Result -Path 'target'
                    }
                    $result.logs.cdpResultFile = $verifyResultFile
                    $result.finishedAt = Get-ZhIsoTimestamp
                    $saved = Save-ZhActionResult -Action 'launch' -Result $result
                    $result.logs.resultFile = $saved
                    Update-ZhState -Changes @{ lastLaunchAt = Get-ZhIsoTimestamp; lastLaunchStatus = 'complete'; lastLaunchCode = 'ALREADY_RUNNING' } | Out-Null
                    Show-ZhResultSummary -Result $result
                    Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
                    Write-ZhUserPause -NoPause:$NoPause
                    return 0
                }
                Write-ZhInfo '现有 Codex 窗口不是本工具启动的中文会话（或验证失败），需要重启。'
            } else {
                Write-ZhInfo '之前记录的调试端口已关闭，需要重启 Codex 才能注入中文。'
            }
        } else {
            Write-ZhInfo 'Codex 正在运行，需要重启才能注入中文。'
        }
        $proceed = $true
        if (-not $Yes) {
            $proceed = Read-ZhConfirmation -Prompt ('检测到 {0} 个 Codex 进程正在运行。需要关闭并重启 Codex 才能以中文启动，请先保存内容。是否继续？' -f $scan.TotalPotential) -DefaultYes
        }
        if (-not $proceed) {
            $result.status = 'failed'
            $result.exitCode = 2
            $result.code = 'USER_CANCELLED'
            $result.mode = 'locale-only'
            $result.message = '用户取消重启 Codex。'
            $result.finishedAt = Get-ZhIsoTimestamp
            $saved = Save-ZhActionResult -Action 'launch' -Result $result
            $result.logs.resultFile = $saved
            Show-ZhResultSummary -Result $result
            Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
            Write-ZhUserPause -NoPause:$NoPause
            return 2
        }
    } elseif ($scan.TotalPotential -gt 0 -and $Restart) {
        Write-ZhInfo '已指定 -Restart：将关闭现有 Codex 进程并重新以中文启动。'
    } else {
        Write-ZhInfo 'Codex 当前未运行，直接以中文模式启动。'
        $needRestart = $false
    }

    if ($needRestart -and $scan.TotalPotential -gt 0) {
        Write-ZhStep '安全关闭现有 Codex'
        $closeReport = Close-ZhCodexSafely -Install $install
        $result.shutdown = [ordered]@{
            success           = [bool]$closeReport.Success
            aborted           = [bool]$closeReport.Aborted
            reason            = $closeReport.Reason
            message           = $closeReport.Message
            initialVerified   = $closeReport.InitialVerified
            initialUnverified = $closeReport.InitialUnverified
            gracefulExited    = $closeReport.GracefulExited
            forceTerminated   = $closeReport.ForceTerminated
            remainingVerified = $closeReport.RemainingVerified
            errors            = @($closeReport.Errors)
        }
        if (-not $closeReport.Success) {
            Write-ZhBad $closeReport.Message
            $result.status = 'failed'
            $result.exitCode = 2
            $result.code = 'SHUTDOWN_FAILED'
            $result.message = $closeReport.Message
            $result.errors += @($closeReport.Errors)
            $result.finishedAt = Get-ZhIsoTimestamp
            $saved = Save-ZhActionResult -Action 'launch' -Result $result
            $result.logs.resultFile = $saved
            Show-ZhResultSummary -Result $result
            Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
            Write-ZhUserPause -NoPause:$NoPause
            return 2
        }
        Write-ZhOk $closeReport.Message
        Start-Sleep -Milliseconds 1200
    }

    # 5. 启动 + 注入
    Write-ZhStep '启动中文会话并注入官方语言包'
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
    $rendererPort = 0
    $inspectorPort = 0
    if ($null -ne $session.Ports) {
        $rendererPort = [int]$session.Ports.Renderer
        $inspectorPort = [int]$session.Ports.Inspector
    }

    if ($session.Ok) {
        $result.status = $session.Status
        $result.exitCode = [int]$session.ExitCode
        $result.code = $session.Code
        $result.mode = 'runtime'
        $menuStatus = [string](Get-ZhNestedValue -Object $session.CdpResult -Path 'menu.status' -Default '')
        if ($result.status -eq 'complete') {
            $result.message = '已以中文模式启动 Codex：中文界面已生效（官方 i18n 同时覆盖了原生菜单）。'
            if ($menuStatus -eq 'not-needed' -or $menuStatus -eq 'unavailable' -or $menuStatus -eq 'skipped') {
                $result.message = $result.message + ' 主进程 inspector 未开放属正常现象，不需要额外注入菜单。'
            }
        } elseif ($result.status -eq 'partial') {
            $result.message = '已以中文模式启动 Codex，但中文界面仅部分确认；请查看结果 JSON 与日志。'
        } else {
            $result.message = 'Codex 已启动，但中文界面状态未确认；请查看结果 JSON 与日志。'
        }
        Write-ZhLog 'INFO' ('启动成功: status={0} code={1} rendererPort={2}' -f $result.status, $result.code, $rendererPort)
    } else {
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = $session.Code
        $result.mode = 'locale-only'
        $detail = $session.Message
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '运行时注入未完成。' }
        $result.message = ('中文会话启动失败（{0}）：{1}' -f $session.Code, $detail)
        $result.errors += $detail
        Write-ZhBad $detail
        $scanAfterFailure = Get-ZhCodexProcessScan -Install $install
        if ($scanAfterFailure.TotalPotential -eq 0) {
            Write-ZhInfo '尝试以普通方式启动 Codex...'
            $fallbackStart = Start-ZhOriginalCodex -Install $install
            if ($fallbackStart.Ok) {
                Write-ZhOk $fallbackStart.Message
                [void](Show-ZhCodexWindows -Install $install)
            }
        } else {
            [void](Show-ZhCodexWindows -Install $install)
        }
    }

    $saved = Save-ZhActionResult -Action 'launch' -Result $result
    $result.logs.resultFile = $saved
    Update-ZhState -Changes @{
        lastLaunchAt      = Get-ZhIsoTimestamp
        lastLaunchStatus  = $result.status
        lastLaunchCode    = $result.code
        lastRendererPort  = $rendererPort
        lastInspectorPort = $inspectorPort
        lastCodexVersion  = $install.Version
    } | Out-Null
    Show-ZhResultSummary -Result $result
    Write-ZhInfo ('日志文件: ' + $logFile)
    Write-ZhInfo ('结果文件: ' + $saved)
    Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
    Write-ZhUserPause -NoPause:$NoPause
    return [int]$result.exitCode
}

$script:ExitCode = Invoke-ZhLaunchMain
if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
