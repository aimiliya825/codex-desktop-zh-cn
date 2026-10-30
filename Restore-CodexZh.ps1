#requires -version 5.1
<#
  Restore-CodexZh.ps1 - 还原原版 Codex（撤销汉化设置）

  行为：
    1. 若存在 config.toml.bak-zhcn 备份 → 原样恢复；否则从 config.toml 中精确删除
       [desktop] 段内的 localeOverride 行（不会删除用户其他配置、不会动 auth/模型设置）；
    2. 如 Codex 正在运行，询问后安全关闭（优雅优先、失败中止，不盲杀）；
    3. 不删除用户数据（不清理 ~/.codex 会话、登录信息、配置其他内容）。

  说明：
    - 本工具不会修改 Codex 安装目录 / app.asar / WindowsApps；
    - 如果安装前 config.toml 里本来就有 localeOverride = "zh-CN"（本工具未修改），
      默认保留并提示；如需强制删除请加 -ForceRemoveLocaleOverride。
    - 还原后从开始菜单正常启动 Codex 即可（英文或官方默认语言）。

  可选参数：
    -Yes                      跳过交互确认
    -ForceRemoveLocaleOverride 强制删除 [desktop] localeOverride（即使不是本工具写入）
    -StartOriginal            还原后立即以普通方式启动 Codex
    -CodexPath <path>         显式指定 Codex 路径（用于关闭进程归属判断）
    -NoPause                  结束后不暂停

  Licensed under the MIT License.
#>
[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [switch]$Yes,
    [switch]$ForceRemoveLocaleOverride,
    [switch]$StartOriginal,
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

function Invoke-ZhRestoreMain {
    Initialize-ZhConsole
    Write-ZhBanner -Subtitle '还原原版（撤销汉化设置）'
    $logFile = Initialize-ZhLog -Name 'restore'
    Write-ZhLog 'INFO' '===== Restore-CodexZh 开始 ====='

    $result = New-ZhActionResult -Action 'restore'
    $result.startedAt = Get-ZhIsoTimestamp
    $result.logs.logFile = $logFile
    $configPath = Get-ZhConfigPath
    $result.configPath = $configPath

    # 1. 检测安装（可选，仅用于安全关闭进程）
    Write-ZhStep '检测 Codex Desktop（用于安全关闭进程；即使未安装也可还原配置）'
    $install = Get-ZhCodexInstall -PreferredPath $CodexPath
    if ($null -ne $install -and $install.IsValid) {
        Write-ZhOk ('检测到 Codex Desktop {0}（{1}）' -f $install.Version, $install.Kind)
        $result.codex = [ordered]@{
            found           = $true
            kind            = $install.Kind
            version         = $install.Version
            aumid           = $install.Aumid
            installLocation = $install.InstallLocation
            executable      = $install.ExecutablePath
        }
    } else {
        Write-ZhWarn '未检测到 Codex Desktop，将仅还原语言配置（不影响其他内容）。'
        $result.codex = [ordered]@{ found = $false }
    }

    # 2. 检查当前配置状态
    Write-ZhStep '检查当前语言设置'
    $state = Get-ZhState
    $configSummary = Get-ZhConfigSummary
    $backupExists = [bool]$configSummary.BackupExists
    $configPresent = [bool]$configSummary.LocaleOverridePresent
    $configModifiedByTool = $false
    if ($null -ne $state) {
        $modifiedValue = Get-ZhNestedValue -Object $state -Path 'configModified' -Default $false
        if ($modifiedValue -eq $true) { $configModifiedByTool = $true }
    }
    Write-ZhInfo ('config.toml: ' + $configPath)
    Write-ZhInfo ('备份文件: {0}（{1}）' -f (Get-ZhConfigBackupPath -ConfigPath $configPath), $(if ($backupExists) { '存在' } else { '不存在' }))
    Write-ZhInfo ('当前 localeOverride: {0}' -f $(if ($configPresent) { $configSummary.LocaleOverrideValue } else { '未设置' }))
    if (-not $backupExists -and -not $configPresent) {
        Write-ZhOk '当前没有需要还原的汉化语言设置。'
        if ($null -ne $install -and $install.IsValid) {
            $scan = Get-ZhCodexProcessScan -Install $install
            if ($scan.TotalPotential -gt 0) {
                Write-ZhInfo ('检测到 {0} 个 Codex 进程；如仍希望关闭，请重新运行并确认。' -f $scan.TotalPotential)
            }
        }
        $result.status = 'complete'
        $result.exitCode = 0
        $result.code = 'NOTHING_TO_RESTORE'
        $result.message = '当前没有需要还原的汉化语言设置。以后从开始菜单启动 Codex 即可。'
        $result.config = [ordered]@{ configPath = $configPath; restored = $false; method = 'nothing-to-do'; backupExists = $backupExists }
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'restore' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 0
    }
    if (-not $backupExists -and -not $configModifiedByTool -and -not $ForceRemoveLocaleOverride) {
        Write-ZhWarn 'config.toml 中的 localeOverride 在汉化安装前已存在（不是本工具写入），默认保留。'
        Write-ZhInfo '如需强制删除该设置，请加 -ForceRemoveLocaleOverride 重新运行。'
        $result.status = 'partial'
        $result.exitCode = 0
        $result.code = 'PRESERVED_PREEXISTING_LOCALE'
        $result.message = '检测到 localeOverride 是安装前已有设置，已保留（未修改）。如需删除请使用 -ForceRemoveLocaleOverride。'
        $result.config = [ordered]@{
            configPath   = $configPath
            restored     = $false
            method       = 'preserved-preexisting'
            value        = $configSummary.LocaleOverrideValue
            backupExists = $backupExists
        }
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'restore' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 0
    }

    # 3. 确认
    $confirmed = $true
    if (-not $Yes) {
        $confirmed = Read-ZhConfirmation -Prompt '即将还原 Codex 语言设置并关闭正在运行的 Codex（不会删除用户数据）。是否继续？' -DefaultYes
    }
    if (-not $confirmed) {
        Write-ZhWarn '用户取消还原。'
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'USER_CANCELLED'
        $result.message = '用户取消还原操作。'
        $result.finishedAt = Get-ZhIsoTimestamp
        $saved = Save-ZhActionResult -Action 'restore' -Result $result
        $result.logs.resultFile = $saved
        Show-ZhResultSummary -Result $result
        Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
        Write-ZhUserPause -NoPause:$NoPause
        return 2
    }

    # 4. 还原配置
    Write-ZhStep '还原 config.toml 语言设置'
    $restoreReport = Restore-ZhConfigFile -ConfigPath $configPath
    $result.config = [ordered]@{
        configPath   = $restoreReport.ConfigPath
        backupPath   = $restoreReport.BackupPath
        restored     = [bool]$restoreReport.Restored
        method       = $restoreReport.Method
        removedLines = [int]$restoreReport.RemovedLines
        verified     = [bool]$restoreReport.Verified
        backupExists = (Test-Path -LiteralPath $restoreReport.BackupPath)
    }
    $configOk = $false
    if (-not [string]::IsNullOrWhiteSpace($restoreReport.Error)) {
        Write-ZhBad ('还原配置失败: ' + $restoreReport.Error)
        $result.errors += $restoreReport.Error
    }
    switch ($restoreReport.Method) {
        'backup' {
            $configOk = [bool]$restoreReport.Verified
            Write-ZhOk '已从备份恢复原始 config.toml。'
        }
        'line-removal' {
            $configOk = [bool]$restoreReport.Verified
            Write-ZhOk ('已从 config.toml 精确删除 {0} 行 localeOverride（其他配置保持不变）。' -f $restoreReport.RemovedLines)
        }
        'nothing-to-do' {
            $configOk = $true
            Write-ZhInfo 'config.toml 中没有 localeOverride，无需修改。'
        }
        default { }
    }

    # 5. 关闭正在运行的 Codex（如存在）
    $shutdownSuccess = $true
    $shutdownAttempted = $false
    if ($null -ne $install -and $install.IsValid) {
        $scan = Get-ZhCodexProcessScan -Install $install
        if ($scan.TotalPotential -gt 0) {
            $shutdownAttempted = $true
            Write-ZhStep '关闭正在运行的 Codex'
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
                $shutdownSuccess = $false
                Write-ZhWarn $closeReport.Message
            } else {
                Write-ZhOk $closeReport.Message
            }
        } else {
            Write-ZhInfo 'Codex 当前未运行，无需关闭。'
        }
    }

    # 6. 可选：还原后启动原版
    if ($StartOriginal -and $null -ne $install -and $install.IsValid) {
        Write-ZhStep '以普通方式启动 Codex'
        $startResult = Start-ZhOriginalCodex -Install $install
        if ($startResult.Ok) { Write-ZhOk $startResult.Message } else { Write-ZhWarn ('启动失败：' + $startResult.Message) }
    }

    # 7. 更新状态文件
    Update-ZhState -Changes @{
        installed         = $false
        restoredAt        = Get-ZhIsoTimestamp
        lastRestoreAt     = Get-ZhIsoTimestamp
        lastRestoreMethod = $restoreReport.Method
        lastRendererPort  = 0
        lastInspectorPort = 0
        mode              = 'restored'
    } | Out-Null

    $result.finishedAt = Get-ZhIsoTimestamp
    if ($configOk -and $shutdownSuccess) {
        $result.status = 'complete'
        $result.exitCode = 0
        $result.code = 'RESTORED'
        $result.message = '已还原原版语言设置。以后从开始菜单正常启动 Codex 即可（英文或官方默认语言）。'
    } elseif ($configOk -and -not $shutdownSuccess) {
        $result.status = 'partial'
        $result.exitCode = 1
        $result.code = 'RESTORED_WITH_RUNNING_PROCESSES'
        $result.message = '语言设置已还原，但仍有 Codex 进程未关闭；请手动完全退出 Codex 后重新启动。'
    } else {
        $result.status = 'failed'
        $result.exitCode = 2
        $result.code = 'RESTORE_FAILED'
        $result.message = '还原语言设置失败：' + $restoreReport.Error
    }
    $saved = Save-ZhActionResult -Action 'restore' -Result $result
    $result.logs.resultFile = $saved
    Show-ZhResultSummary -Result $result
    Write-ZhInfo ('日志文件: ' + $logFile)
    Write-ZhInfo ('结果文件: ' + $saved)
    Write-ZhInfo '说明：本工具不删除用户数据；如需重新汉化，请再次运行「一键汉化.bat」。'
    Close-ZhLog -Summary ('status=' + $result.status + ' code=' + $result.code)
    Write-ZhUserPause -NoPause:$NoPause
    return [int]$result.exitCode
}

$script:ExitCode = Invoke-ZhRestoreMain
if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
