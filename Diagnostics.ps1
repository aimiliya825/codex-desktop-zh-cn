#requires -version 5.1
<#
  Diagnostics.ps1 - Codex 汉化工具只读诊断

  只读含义：
    - 不启动 / 不关闭 / 不注入 Codex；
    - 不写 config.toml，不修改注册表；
    - 仅在本工具自己的目录 %LOCALAPPDATA%\CodexZhCn\logs 写入一份诊断报告，
      方便用户在反馈问题时直接附上。

  输出内容：工具/系统/Node 版本、Codex 检测过程、版本兼容性、进程状态、
  config.toml 脱敏摘要、端口状态、结果 JSON 摘要、最近日志。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1
    powershell ... -File .\Diagnostics.ps1 -NoPause -Json   # 额外输出 JSON 摘要到 stdout

  退出码：0=检测到 Codex；1=未检测到 Codex；2=诊断过程异常。

  Licensed under the MIT License.
#>
[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [switch]$NoPause,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 2

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
} catch {
    Write-Host ('无法加载 lib\Common.ps1: ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
}

function Format-ZhDiagPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $formatted = $Path
    $userProfile = [string]$env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $formatted = $formatted.Replace($userProfile, '%USERPROFILE%')
    }
    $userName = [string]$env:USERNAME
    if (-not [string]::IsNullOrWhiteSpace($userName)) {
        $formatted = $formatted.Replace($userName, '%USERNAME%')
    }
    return $formatted
}

function Add-ZhDiagLine {
    param($Lines, [string]$Text)
    [void]$Lines.Add($Text)
}

function Invoke-ZhDiagnosticsMain {
    Initialize-ZhConsole
    $logFile = Initialize-ZhLog -Name 'diagnostics'
    Write-ZhLog 'INFO' '===== Diagnostics 开始（只读） ====='
    $lines = New-Object System.Collections.ArrayList
    $jsonSummary = [ordered]@{
        tool          = 'codex-desktop-zh'
        toolVersion   = $script:CodexZhToolVersion
        generatedAt   = Get-ZhIsoTimestamp
        powershell    = $PSVersionTable.PSVersion.ToString()
        node          = $null
        codex         = $null
        processes     = $null
        config        = $null
        ports         = $null
        results       = $null
        logs          = [ordered]@{ logFile = $logFile; reportFile = '' }
    }

    Add-ZhDiagLine -Lines $lines -Text '============================================================'
    Add-ZhDiagLine -Lines $lines -Text ('  Codex Desktop 汉化工具 - 只读诊断报告  v{0}' -f $script:CodexZhToolVersion)
    Add-ZhDiagLine -Lines $lines -Text ('  生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-ZhDiagLine -Lines $lines -Text '============================================================'
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 环境 ----------------
    Add-ZhDiagLine -Lines $lines -Text '【环境】'
    Add-ZhDiagLine -Lines $lines -Text ('  PowerShell: {0}（{1}）' -f $PSVersionTable.PSVersion.ToString(), $PSVersionTable.PSEdition)
    Add-ZhDiagLine -Lines $lines -Text ('  操作系统: ' + [System.Environment]::OSVersion.VersionString)
    Add-ZhDiagLine -Lines $lines -Text ('  系统区域: ' + (Get-Culture).Name)
    try {
        Add-ZhDiagLine -Lines $lines -Text ('  控制台代码页: ' + [Console]::OutputEncoding.CodePage)
    } catch { }
    $isAdmin = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Add-ZhDiagLine -Lines $lines -Text ('  管理员权限: ' + $isAdmin)
    $node = Get-ZhNodeInfo
    $nodeText = '未找到'
    if ($node.Available) { $nodeText = ('{0}（{1}）' -f $node.Version, (Format-ZhDiagPath -Path $node.Path)) }
    Add-ZhDiagLine -Lines $lines -Text ('  Node.js: ' + $nodeText)
    Add-ZhDiagLine -Lines $lines -Text ('  检测结论: ' + $node.Message)
    $jsonSummary.node = [ordered]@{
        available = [bool]$node.Available
        ok        = [bool]$node.Ok
        version   = $node.Version
        path      = Format-ZhDiagPath -Path $node.Path
        message   = $node.Message
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 安装检测 ----------------
    Add-ZhDiagLine -Lines $lines -Text '【Codex 检测】'
    $install = Get-ZhCodexInstall -PreferredPath $CodexPath
    if ($null -ne $install -and $install.IsValid) {
        Add-ZhDiagLine -Lines $lines -Text ('  状态: 已检测到')
        Add-ZhDiagLine -Lines $lines -Text ('  类型: ' + $install.Kind)
        Add-ZhDiagLine -Lines $lines -Text ('  版本: ' + $install.Version)
        Add-ZhDiagLine -Lines $lines -Text ('  安装位置: ' + (Format-ZhDiagPath -Path $install.InstallLocation))
        Add-ZhDiagLine -Lines $lines -Text ('  可执行文件: ' + (Format-ZhDiagPath -Path $install.ExecutablePath))
        Add-ZhDiagLine -Lines $lines -Text ('  AUMID: ' + $install.Aumid)
        Add-ZhDiagLine -Lines $lines -Text ('  包族名: ' + $install.PackageFamilyName)
        Add-ZhDiagLine -Lines $lines -Text ('  检测来源: ' + $install.Source)
        Add-ZhDiagLine -Lines $lines -Text ('  受保护版本线（26.900+）: ' + $install.IsProtectedLine)
        if ($install.IsProtectedLine) {
            Add-ZhDiagLine -Lines $lines -Text '  说明: 该版本对 app.asar 做整包完整性校验，本工具不修改任何官方文件，仅运行时注入。'
        }
        $jsonSummary.codex = [ordered]@{
            found                = $true
            kind                 = $install.Kind
            version              = $install.Version
            aumid                = $install.Aumid
            installLocation      = Format-ZhDiagPath -Path $install.InstallLocation
            executable           = Format-ZhDiagPath -Path $install.ExecutablePath
            packageFamilyName    = $install.PackageFamilyName
            source               = $install.Source
            protectedVersionLine = [bool]$install.IsProtectedLine
        }
    } else {
        Add-ZhDiagLine -Lines $lines -Text '  状态: 未检测到 Codex Desktop'
        Add-ZhDiagLine -Lines $lines -Text '  提示: 请确认已通过 Microsoft Store 安装 Codex；如为便携版请加 -CodexPath 指定。'
        $jsonSummary.codex = [ordered]@{ found = $false }
    }
    Add-ZhDiagLine -Lines $lines -Text '  检测过程:'
    foreach ($traceLine in (Get-ZhDetectionTrace)) {
        Add-ZhDiagLine -Lines $lines -Text ('    ' + (Format-ZhDiagPath -Path $traceLine))
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 进程 ----------------
    Add-ZhDiagLine -Lines $lines -Text '【进程】'
    $scan = Get-ZhCodexProcessScan -Install $install
    Add-ZhDiagLine -Lines $lines -Text ('  可验证的 Codex 进程: {0} 个' -f $scan.Verified.Count)
    foreach ($item in $scan.Verified) {
        Add-ZhDiagLine -Lines $lines -Text ('    PID {0} | 窗口={1} | 路径={2}' -f $item.Id, $item.HasMainWindow, (Format-ZhDiagPath -Path $item.Path))
    }
    Add-ZhDiagLine -Lines $lines -Text ('  路径不可验证的候选进程: {0} 个（工具不会盲杀）' -f $scan.Unverified.Count)
    foreach ($item in $scan.Unverified) {
        Add-ZhDiagLine -Lines $lines -Text ('    PID {0} | 名称={1}' -f $item.Id, $item.Name)
    }
    Add-ZhDiagLine -Lines $lines -Text ('  其他路径的 Codex 进程（忽略）: {0} 个' -f $scan.Ignored.Count)
    foreach ($ignoredPath in $scan.Ignored) {
        Add-ZhDiagLine -Lines $lines -Text ('    ' + (Format-ZhDiagPath -Path $ignoredPath))
    }
    $jsonSummary.processes = [ordered]@{
        verifiedCount   = $scan.Verified.Count
        unverifiedCount = $scan.Unverified.Count
        ignoredCount    = $scan.Ignored.Count
        verified        = @($scan.Verified | ForEach-Object { [ordered]@{ pid = $_.Id; hasWindow = $_.HasMainWindow; path = (Format-ZhDiagPath -Path $_.Path) } })
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 语言配置（脱敏） ----------------
    Add-ZhDiagLine -Lines $lines -Text '【语言配置（仅展示相关项，其他内容已脱敏）】'
    $configPath = Get-ZhConfigPath
    $configSummary = Get-ZhConfigSummary
    Add-ZhDiagLine -Lines $lines -Text ('  config.toml: ' + (Format-ZhDiagPath -Path $configPath))
    Add-ZhDiagLine -Lines $lines -Text ('  存在: {0} | 大小: {1} 字节 | 最后修改: {2}' -f $configSummary.Exists, $configSummary.SizeBytes, $configSummary.LastWriteTime)
    Add-ZhDiagLine -Lines $lines -Text ('  包含的段: ' + (($configSummary.SectionNames) -join ', '))
    $localeText = '未设置'
    if ($configSummary.LocaleOverridePresent) { $localeText = $configSummary.LocaleOverrideValue }
    Add-ZhDiagLine -Lines $lines -Text ('  [desktop] localeOverride: ' + $localeText)
    Add-ZhDiagLine -Lines $lines -Text ('  备份文件 config.toml.bak-zhcn: ' + $(if ($configSummary.BackupExists) { '存在' } else { '不存在' }))
    Add-ZhDiagLine -Lines $lines -Text '  说明: 为避免泄露隐私，本报告不打印 config.toml 其他行的内容。'
    $jsonSummary.config = [ordered]@{
        path                  = Format-ZhDiagPath -Path $configPath
        exists                = [bool]$configSummary.Exists
        sizeBytes             = [long]$configSummary.SizeBytes
        desktopSection        = [bool]$configSummary.DesktopSection
        localeOverridePresent = [bool]$configSummary.LocaleOverridePresent
        localeOverrideValue   = $configSummary.LocaleOverrideValue
        backupExists          = [bool]$configSummary.BackupExists
        sectionNames          = @($configSummary.SectionNames)
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 安装状态 / 端口 ----------------
    Add-ZhDiagLine -Lines $lines -Text '【汉化安装状态】'
    $installedCheck = Test-ZhInstalled
    Add-ZhDiagLine -Lines $lines -Text ('  已安装: {0}（{1}）' -f $installedCheck.Installed, $installedCheck.Reason)
    $state = Get-ZhState
    $lastRendererPort = 0
    $lastInspectorPort = 0
    if ($null -ne $state) {
        $lastRendererPort = [int](Get-ZhNestedValue -Object $state -Path 'lastRendererPort' -Default 0)
        $lastInspectorPort = [int](Get-ZhNestedValue -Object $state -Path 'lastInspectorPort' -Default 0)
        Add-ZhDiagLine -Lines $lines -Text ('  安装时间: ' + [string](Get-ZhNestedValue -Object $state -Path 'installedAt' -Default '未知'))
        Add-ZhDiagLine -Lines $lines -Text ('  当前模式: ' + [string](Get-ZhNestedValue -Object $state -Path 'mode' -Default '未知'))
        Add-ZhDiagLine -Lines $lines -Text ('  最近安装: {0} / {1}' -f [string](Get-ZhNestedValue -Object $state -Path 'lastInstallStatus' -Default ''), [string](Get-ZhNestedValue -Object $state -Path 'lastInstallCode' -Default ''))
        Add-ZhDiagLine -Lines $lines -Text ('  最近启动: {0} / {1}' -f [string](Get-ZhNestedValue -Object $state -Path 'lastLaunchStatus' -Default ''), [string](Get-ZhNestedValue -Object $state -Path 'lastLaunchCode' -Default ''))
        Add-ZhDiagLine -Lines $lines -Text ('  最近还原: ' + [string](Get-ZhNestedValue -Object $state -Path 'lastRestoreAt' -Default '无'))
        Add-ZhDiagLine -Lines $lines -Text ('  记录的调试端口: renderer={0}, inspector={1}' -f $lastRendererPort, $lastInspectorPort)
    } else {
        Add-ZhDiagLine -Lines $lines -Text '  状态文件: 不存在（可能尚未安装过，或为手动安装）'
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    Add-ZhDiagLine -Lines $lines -Text '【端口探测（只读 HTTP）】'
    $rendererReady = $false
    $inspectorReady = $false
    if ($lastRendererPort -gt 0) {
        $rendererReady = Wait-ZhHttpPortReady -Port $lastRendererPort -TimeoutSec 1 -Path '/json/version' -IntervalMs 100
        Add-ZhDiagLine -Lines $lines -Text ('  renderer 端口 {0}: {1}' -f $lastRendererPort, $(if ($rendererReady) { '开放（调试会话运行中）' } else { '未开放' }))
    } else {
        Add-ZhDiagLine -Lines $lines -Text '  renderer 端口: 无记录（当前 Codex 可能不是本工具启动的会话）'
    }
    if ($lastInspectorPort -gt 0) {
        $inspectorReady = Wait-ZhHttpPortReady -Port $lastInspectorPort -TimeoutSec 1 -Path '/json/list' -IntervalMs 100
        Add-ZhDiagLine -Lines $lines -Text ('  inspector 端口 {0}: {1}' -f $lastInspectorPort, $(if ($inspectorReady) { '开放（可注入原生菜单）' } else { '未开放（本版本不支持主进程 inspector，菜单不汉化属预期）' }))
    } else {
        Add-ZhDiagLine -Lines $lines -Text '  inspector 端口: 无记录'
    }
    Add-ZhDiagLine -Lines $lines -Text '  提示: 端口只在本工具启动的会话中存在；从开始菜单正常启动的 Codex 不会开放调试端口。'
    $jsonSummary.ports = [ordered]@{
        rendererPort      = $lastRendererPort
        rendererOpen      = [bool]$rendererReady
        inspectorPort     = $lastInspectorPort
        inspectorOpen     = [bool]$inspectorReady
    }
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 结果 JSON ----------------
    Add-ZhDiagLine -Lines $lines -Text '【最近结果】'
    $resultsSummary = [ordered]@{}
    foreach ($action in @('install', 'launch', 'restore')) {
        $actionResult = Get-ZhActionResult -Action $action
        if ($null -ne $actionResult) {
            $statusText = [string](Get-ZhNestedValue -Object $actionResult -Path 'status' -Default '')
            $codeText = [string](Get-ZhNestedValue -Object $actionResult -Path 'code' -Default '')
            $messageText = [string](Get-ZhNestedValue -Object $actionResult -Path 'message' -Default '')
            $finishedText = [string](Get-ZhNestedValue -Object $actionResult -Path 'finishedAt' -Default '')
            Add-ZhDiagLine -Lines $lines -Text ('  {0}: status={1} code={2} finishedAt={3}' -f $action, $statusText, $codeText, $finishedText)
            if (-not [string]::IsNullOrWhiteSpace($messageText)) {
                Add-ZhDiagLine -Lines $lines -Text ('    message: ' + (Format-ZhDiagPath -Path $messageText))
            }
            $resultsSummary[$action] = [ordered]@{ status = $statusText; code = $codeText; finishedAt = $finishedText }
        } else {
            Add-ZhDiagLine -Lines $lines -Text ('  {0}: 无结果文件' -f $action)
            $resultsSummary[$action] = $null
        }
    }
    $jsonSummary.results = $resultsSummary
    Add-ZhDiagLine -Lines $lines -Text ''

    # ---------------- 最近日志 ----------------
    Add-ZhDiagLine -Lines $lines -Text '【最近日志（末尾 25 行）】'
    foreach ($logPattern in @('install', 'launch', 'restore', 'cdp')) {
        $newest = Get-ZhNewestLogFile -NamePattern $logPattern
        if ([string]::IsNullOrWhiteSpace($newest)) {
            Add-ZhDiagLine -Lines $lines -Text ('  {0}: 无日志' -f $logPattern)
            continue
        }
        Add-ZhDiagLine -Lines $lines -Text ('  --- {0}（{1}）---' -f (Split-Path -Leaf $newest), (Format-ZhDiagPath -Path $newest))
        $tail = Read-ZhTextTail -Path $newest -Lines 25
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            foreach ($tailLine in ($tail -split "`r?`n")) {
                if ($tailLine -eq '') { continue }
                Add-ZhDiagLine -Lines $lines -Text ('    ' + (Format-ZhDiagPath -Path $tailLine))
            }
        }
    }
    Add-ZhDiagLine -Lines $lines -Text ''
    Add-ZhDiagLine -Lines $lines -Text '【重要说明】'
    Add-ZhDiagLine -Lines $lines -Text '  - 本报告不包含 auth.json、token、API key、模型配置等内容。'
    Add-ZhDiagLine -Lines $lines -Text '  - 本工具不修改 Codex 安装目录 / app.asar / WindowsApps 下任何文件。'
    Add-ZhDiagLine -Lines $lines -Text '  - 26.900+ 版本不开放主进程 inspector 时，原生菜单无法汉化，界面汉化不受影响。'

    # ---------------- 输出与保存 ----------------
    Write-Host ''
    foreach ($line in $lines) { Write-Host $line }
    $reportLines = @('# codex-desktop-zh 只读诊断报告')
    $reportLines += ('# generatedAt: ' + (Get-ZhIsoTimestamp))
    $reportLines += ''
    $reportLines += @($lines)
    $reportPath = Join-Path (Get-ZhLogDir) ('diagnostics-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $reportText = ($reportLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($reportPath, $reportText, (New-Object System.Text.UTF8Encoding($false)))
    $jsonSummary.logs.reportFile = $reportPath
    Write-Host ''
    Write-Host ('诊断报告已保存: ' + $reportPath) -ForegroundColor Green
    Write-Host ('诊断日志: ' + $logFile) -ForegroundColor DarkGray
    Write-ZhLog 'INFO' ('诊断报告已保存: ' + $reportPath)
    Close-ZhLog -Summary 'diagnostics complete'
    if ($Json) {
        Write-Output (ConvertTo-ZhJson -Object $jsonSummary -Depth 8)
    }
    Write-ZhUserPause -NoPause:$NoPause
    if ($null -ne $install -and $install.IsValid) { return 0 }
    return 1
}

$script:ExitCode = Invoke-ZhDiagnosticsMain
if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
