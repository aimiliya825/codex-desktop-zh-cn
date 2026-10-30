#requires -version 5.1
<#
  Common.ps1 - codex-desktop-zh 共享函数库

  由下列入口脚本 dot-source 使用：
    Install-CodexZh.ps1 / Launch-CodexZh.ps1 / Restore-CodexZh.ps1 / Diagnostics.ps1
  以及 tests/SelfTest.ps1（仅调用纯函数，不触发启动/关闭 Codex）。

  设计原则：
    - 只定义函数与常量；加载本文件不产生副作用（不创建目录、不写文件、不读写 config.toml）。
    - 兼容 Windows PowerShell 5.1（不使用 PS7 空合并运算符、三元表达式、-Parallel、ConvertFrom-Json 哈希表参数等 7.x 特性）。
    - 所有 JSON 落盘使用 .NET UTF8 无 BOM。
    - 绝不修改 Codex 安装目录 / app.asar / WindowsApps；不读取 auth.json / token。

  Licensed under the MIT License. 详见 LICENSE 与 THIRD_PARTY_NOTICES.md。
#>

$script:CodexZhToolVersion = '1.1.0'
$script:CodexZhDefaultLocale = 'zh-CN'
$script:CodexZhNodeMinMajor = 22
$script:CodexZhPackageName = 'OpenAI.Codex'
$script:CodexZhRegistryRepo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
$script:CodexZhProtectedVersionFrom = [version]'26.900.0.0'
$script:CodexZhDetectionTrace = New-Object System.Collections.ArrayList
$script:ZhLogFilePath = ''
$script:ZhLogFileName = ''
$script:CodexZhRoot = ''
try {
    if ($PSScriptRoot) {
        $script:CodexZhRoot = Split-Path -Parent $PSScriptRoot
    }
} catch { }
if ([string]::IsNullOrWhiteSpace([string]$script:CodexZhRoot)) {
    try { $script:CodexZhRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
    try { if ($script:CodexZhRoot) { $script:CodexZhRoot = Split-Path -Parent $script:CodexZhRoot } } catch { }
}

# ===========================================================================
# 控制台与日志
# ===========================================================================
function Initialize-ZhConsole {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $global:OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

function Get-ZhTimestamp {
    return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

function Get-ZhIsoTimestamp {
    return (Get-Date).ToString('o')
}

function Write-ZhBanner {
    param([string]$Subtitle = '')
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  Codex Desktop 汉化工具  v{0}（非官方社区脚本）' -f $script:CodexZhToolVersion) -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host ('  ' + $Subtitle) -ForegroundColor Cyan
    }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  不修改 Codex 安装目录 / app.asar，仅运行时注入 + 官方设置键' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-ZhStep {
    param([string]$Message)
    Write-Host ''
    Write-Host ('[步骤] ' + $Message) -ForegroundColor Yellow
}

function Write-ZhOk {
    param([string]$Message)
    Write-Host ('  [OK] ' + $Message) -ForegroundColor Green
}

function Write-ZhWarn {
    param([string]$Message)
    Write-Host ('  [!] ' + $Message) -ForegroundColor Yellow
}

function Write-ZhBad {
    param([string]$Message)
    Write-Host ('  [X] ' + $Message) -ForegroundColor Red
}

function Write-ZhInfo {
    param([string]$Message)
    Write-Host ('  [i] ' + $Message) -ForegroundColor DarkGray
}

function Write-ZhDetail {
    param([string]$Message)
    Write-Host ('      ' + $Message) -ForegroundColor DarkGray
}

function Get-ZhToolHome {
    $base = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        try { $base = [System.IO.Path]::GetTempPath() } catch { $base = $env:TEMP }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = '.' }
    return (Join-Path $base 'CodexZhCn')
}

function Get-ZhLogDir {
    $dir = Join-Path (Get-ZhToolHome) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}

function Get-ZhResultDir {
    $dir = Join-Path (Get-ZhToolHome) 'results'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}

function Get-ZhStatePath {
    return (Join-Path (Get-ZhToolHome) 'state.json')
}

function Initialize-ZhLog {
    param([string]$Name = 'tool')
    $logDir = Get-ZhLogDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:ZhLogFileName = ('{0}-{1}.log' -f $Name, $stamp)
    $script:ZhLogFilePath = Join-Path $logDir $script:ZhLogFileName
    $header = @()
    $header += '# codex-desktop-zh 汉化工具日志'
    $header += ('# toolVersion: {0}' -f $script:CodexZhToolVersion)
    $header += ('# action: {0}' -f $Name)
    $header += ('# startedAt: {0}' -f (Get-ZhIsoTimestamp))
    $header += ('# powershell: {0}' -f $PSVersionTable.PSVersion.ToString())
    $header += ('# os: {0}' -f [System.Environment]::OSVersion.VersionString)
    $header += ('# user: {0}' -f $env:USERNAME)
    $header += ''
    try {
        [System.IO.File]::WriteAllText($script:ZhLogFilePath, (($header -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return $script:ZhLogFilePath
}

function Get-ZhLogFile {
    return $script:ZhLogFilePath
}

function Write-ZhLog {
    param(
        [string]$Level = 'INFO',
        [string]$Message = ''
    )
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] [' + $Level + '] ' + $Message
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ZhLogFilePath)) {
        try {
            [System.IO.File]::AppendAllText($script:ZhLogFilePath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    if ($Level -eq 'WARN') { Write-Host ('  [警告] ' + $Message) -ForegroundColor Yellow }
    elseif ($Level -eq 'ERROR') { Write-Host ('  [错误] ' + $Message) -ForegroundColor Red }
}

function Close-ZhLog {
    param([string]$Summary = '')
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ZhLogFilePath)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($Summary)) {
                [System.IO.File]::AppendAllText($script:ZhLogFilePath, ('# ' + $Summary + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            }
            [System.IO.File]::AppendAllText($script:ZhLogFilePath, ('# finishedAt: {0}' -f (Get-ZhIsoTimestamp)) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}

function Get-ZhNewestLogFile {
    param([string]$NamePattern = '')
    $dir = Get-ZhLogDir
    $filter = '*.log'
    if (-not [string]::IsNullOrWhiteSpace($NamePattern)) { $filter = $NamePattern + '-*.log' }
    try {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter $filter -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending)
        if ($files.Count -gt 0) { return $files[0].FullName }
    } catch { }
    return ''
}

function Read-ZhTextTail {
    param([string]$Path, [int]$Lines = 30)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -Encoding UTF8 -ErrorAction Stop) -join "`r`n")
    } catch {
        return ''
    }
}

# ===========================================================================
# JSON 辅助
# ===========================================================================
function ConvertTo-ZhJson {
    param(
        $Object,
        [int]$Depth = 12,
        [switch]$Compress
    )
    if ($null -eq $Object) { return 'null' }
    if ($Compress) { return ($Object | ConvertTo-Json -Depth $Depth -Compress) }
    return ($Object | ConvertTo-Json -Depth $Depth)
}

function Write-ZhJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Object,
        [int]$Depth = 12
    )
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-ZhJson -Object $Object -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
    return $Path
}

function Read-ZhJsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-ZhNestedValue {
    param(
        $Object,
        [string]$Path,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        if ($part -eq '') { continue }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $Default }
            $current = $current[$part]
            continue
        }
        $prop = $null
        try { $prop = $current.PSObject.Properties[$part] } catch { $prop = $null }
        if ($null -eq $prop) { return $Default }
        $current = $prop.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-ZhState {
    $path = Get-ZhStatePath
    return (Read-ZhJsonFile -Path $path)
}

function Save-ZhState {
    param($State)
    $path = Get-ZhStatePath
    Write-ZhJsonFile -Path $path -Object $State | Out-Null
    return $path
}

function Update-ZhState {
    param([hashtable]$Changes)
    $state = [ordered]@{}
    $existing = Get-ZhState
    if ($null -ne $existing) {
        foreach ($prop in $existing.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
    }
    if (-not $state.Contains('toolVersion')) { $state['toolVersion'] = $script:CodexZhToolVersion }
    if ($null -ne $Changes) {
        foreach ($key in $Changes.Keys) { $state[$key] = $Changes[$key] }
    }
    $state['updatedAt'] = Get-ZhIsoTimestamp
    Save-ZhState -State $state | Out-Null
    return $state
}

function Save-ZhActionResult {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        $Result,
        [string]$ResultPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        $ResultPath = Join-Path (Get-ZhResultDir) ('{0}-result.json' -f $Action)
    }
    Write-ZhJsonFile -Path $ResultPath -Object $Result | Out-Null
    return $ResultPath
}

function Get-ZhActionResult {
    param([Parameter(Mandatory = $true)][string]$Action)
    $path = Join-Path (Get-ZhResultDir) ('{0}-result.json' -f $Action)
    return (Read-ZhJsonFile -Path $path)
}

function New-ZhActionResult {
    param([Parameter(Mandatory = $true)][string]$Action)
    return [ordered]@{
        tool         = 'codex-desktop-zh'
        toolVersion  = $script:CodexZhToolVersion
        action       = $Action
        status       = 'failed'
        exitCode     = 2
        code         = 'UNKNOWN'
        message      = ''
        mode         = 'none'
        locale       = $script:CodexZhDefaultLocale
        codex        = $null
        config       = $null
        shutdown     = $null
        ports        = $null
        renderer     = $null
        menu         = $null
        checks       = @()
        warnings     = @()
        errors       = @()
        logs         = [ordered]@{ logFile = ''; cdpResultFile = '' }
        startedAt    = Get-ZhIsoTimestamp
        finishedAt   = ''
    }
}

# ===========================================================================
# 版本 / 检测（零 Appx cmdlet 依赖）
# ===========================================================================
function ConvertTo-ZhVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $text = $Version.Trim().TrimStart('v', 'V')
    try { return [version]$text } catch { }
    $match = [regex]::Match($text, '^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $parts = @(0, 0, 0, 0)
    for ($i = 1; $i -le 4; $i++) {
        if ($match.Groups[$i].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[$i].Value)) {
            $parts[$i - 1] = [int]$match.Groups[$i].Value
        }
    }
    try { return (New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3])) } catch { return $null }
}

function Test-ZhProtectedVersion {
    param([string]$Version)
    $parsed = ConvertTo-ZhVersion -Version $Version
    if ($null -eq $parsed) { return $false }
    return ($parsed -ge $script:CodexZhProtectedVersionFrom)
}

function Add-ZhDetectionTrace {
    param([string]$Message)
    try { [void]$script:CodexZhDetectionTrace.Add(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)) } catch { }
}

function Get-ZhDetectionTrace {
    return @($script:CodexZhDetectionTrace)
}

function Read-ZhAppxManifest {
    param([string]$InstallLocation)
    if ([string]::IsNullOrWhiteSpace($InstallLocation)) { return $null }
    $manifestPath = Join-Path $InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($manifestPath)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        [xml]$doc = $text
        $identity = $null
        try { $identity = $doc.Package.Identity } catch { }
        if ($null -eq $identity) { return $null }
        $applications = @()
        try {
            foreach ($app in @($doc.Package.Applications.Application)) {
                if ($null -eq $app) { continue }
                $applications += [pscustomobject]@{
                    Id         = [string]$app.Id
                    Executable = [string]$app.Executable
                    EntryPoint = [string]$app.EntryPoint
                }
            }
        } catch { }
        $mainApp = $null
        foreach ($app in $applications) {
            if ($app.Executable -match '(?i)(ChatGPT|Codex)\.exe$') { $mainApp = $app; break }
        }
        if ($null -eq $mainApp -and $applications.Count -gt 0) { $mainApp = $applications[0] }
        return [pscustomobject]@{
            Path         = $manifestPath
            Name         = [string]$identity.Name
            Version      = [string]$identity.Version
            Publisher    = [string]$identity.Publisher
            Arch         = [string]$identity.ProcessorArchitecture
            Applications = @($applications)
            MainApp      = $mainApp
        }
    } catch {
        Add-ZhDetectionTrace ('读取 AppxManifest.xml 失败: ' + $_.Exception.Message)
        return $null
    }
}

function Find-ZhExecutable {
    param(
        [string]$InstallLocation,
        [string]$ManifestExecutable = ''
    )
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ManifestExecutable)) {
        $candidates += (Join-Path $InstallLocation ($ManifestExecutable -replace '/', '\'))
    }
    $candidates += (Join-Path $InstallLocation 'app\ChatGPT.exe')
    $candidates += (Join-Path $InstallLocation 'app\Codex.exe')
    $candidates += (Join-Path $InstallLocation 'ChatGPT.exe')
    $candidates += (Join-Path $InstallLocation 'Codex.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-ZhFullPath -Path $candidate) }
    }
    return ''
}

function Resolve-ZhFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function New-ZhInstallRecord {
    param(
        [string]$Kind = 'Store',
        [string]$InstallLocation = '',
        [string]$ExecutablePath = '',
        [string]$Version = '',
        [string]$Aumid = '',
        [string]$PackageFamilyName = '',
        [string]$PackageFullName = '',
        [string]$AppId = '',
        [string]$Source = ''
    )
    $record = [pscustomobject]@{
        Kind              = $Kind
        InstallLocation   = (Resolve-ZhFullPath -Path $InstallLocation)
        ExecutablePath    = (Resolve-ZhFullPath -Path $ExecutablePath)
        Version           = $Version
        Aumid             = $Aumid
        PackageFamilyName = $PackageFamilyName
        PackageFullName   = $PackageFullName
        AppId             = $AppId
        Source            = $Source
        IsStore           = ($Kind -eq 'Store')
        IsValid           = $false
        IsProtectedLine   = (Test-ZhProtectedVersion -Version $Version)
    }
    $exeOk = ($record.ExecutablePath -ne '' -and (Test-Path -LiteralPath $record.ExecutablePath))
    if ($record.IsStore) {
        $record.IsValid = ($exeOk -and -not [string]::IsNullOrWhiteSpace($record.Aumid))
    } else {
        $record.IsValid = $exeOk
    }
    return $record
}

function Get-ZhRegistryPackages {
    $packages = @()
    $items = @()
    try {
        $items = @(Get-ChildItem -LiteralPath $script:CodexZhRegistryRepo -ErrorAction SilentlyContinue)
    } catch {
        Add-ZhDetectionTrace ('无法枚举注册表包仓库: ' + $_.Exception.Message)
        return @()
    }
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $childName = [string]$item.PSChildName
        if ($childName -notmatch '^OpenAI\.Codex_') { continue }
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction Stop } catch { continue }
        $packageId = ''
        try { $packageId = [string]$props.PackageID } catch { }
        if ([string]::IsNullOrWhiteSpace($packageId)) { $packageId = $childName }
        $rootFolder = ''
        try { $rootFolder = [string]$props.PackageRootFolder } catch { }
        if ([string]::IsNullOrWhiteSpace($rootFolder)) { continue }
        $parts = @($packageId -split '_')
        $name = ''; $versionText = ''; $arch = ''; $publisherId = ''
        if ($parts.Count -ge 5) {
            $name = $parts[0]
            $versionText = $parts[1]
            $arch = $parts[2]
            $publisherId = $parts[$parts.Count - 1]
        } else {
            continue
        }
        $parsedVersion = ConvertTo-ZhVersion -Version $versionText
        if ($null -eq $parsedVersion) { continue }
        $packages += [pscustomobject]@{
            Name         = $name
            VersionText  = $versionText
            Version      = $parsedVersion
            Arch         = $arch
            PublisherId  = $publisherId
            PackageId    = $packageId
            RootFolder   = $rootFolder
            FamilyName   = ('{0}_{1}' -f $name, $publisherId)
            RegistryPath = $item.PSPath
        }
    }
    if ($packages.Count -eq 0) {
        Add-ZhDetectionTrace '注册表包仓库中没有 OpenAI.Codex 记录'
        return @()
    }
    return @($packages | Sort-Object -Property Version -Descending)
}

function Get-ZhInstallFromPackageRecord {
    param($PackageRecord)
    if ($null -eq $PackageRecord) { return $null }
    $root = [string]$PackageRecord.RootFolder
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    if (-not (Test-Path -LiteralPath $root)) {
        Add-ZhDetectionTrace ('候选安装目录不存在（可能已卸载）: ' + $root)
        return $null
    }
    $manifest = Read-ZhAppxManifest -InstallLocation $root
    if ($null -eq $manifest) {
        Add-ZhDetectionTrace ('无法读取包清单，跳过: ' + $root)
        return $null
    }
    $version = [string]$manifest.Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$PackageRecord.VersionText }
    $manifestExecutable = ''
    $appId = ''
    if ($null -ne $manifest.MainApp) {
        $manifestExecutable = [string]$manifest.MainApp.Executable
        $appId = [string]$manifest.MainApp.Id
    }
    if ([string]::IsNullOrWhiteSpace($appId)) { $appId = 'App' }
    $exe = Find-ZhExecutable -InstallLocation $root -ManifestExecutable $manifestExecutable
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Add-ZhDetectionTrace ('安装目录中找不到 Codex 可执行文件: ' + $root)
        return $null
    }
    $family = [string]$PackageRecord.FamilyName
    if ([string]::IsNullOrWhiteSpace($family)) {
        $family = ('{0}_{1}' -f $manifest.Name, $PackageRecord.PublisherId)
    }
    return (New-ZhInstallRecord -Kind 'Store' -InstallLocation $root -ExecutablePath $exe -Version $version `
            -Aumid ($family + '!' + $appId) -PackageFamilyName $family -PackageFullName ([string]$PackageRecord.PackageId) `
            -AppId $appId -Source 'Registry')
}

function Get-ZhPortableCandidates {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'Codex\Codex.exe')
    }
    $programFilesX86 = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates += (Join-Path $programFilesX86 'Codex\Codex.exe')
    }
    return @($candidates)
}

function Resolve-ZhInstallFromPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Source = 'PreferredPath'
    )
    $fullPath = Resolve-ZhFullPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($fullPath)) { return $null }
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $exe = Find-ZhExecutable -InstallLocation $fullPath
        if ([string]::IsNullOrWhiteSpace($exe)) { $exe = Find-ZhExecutable -InstallLocation (Join-Path $fullPath 'app') }
        if ([string]::IsNullOrWhiteSpace($exe)) {
            Add-ZhDetectionTrace ('指定目录中找不到 Codex 可执行文件: ' + $fullPath)
            return $null
        }
    } else {
        $exe = $fullPath
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        Add-ZhDetectionTrace ('指定的可执行文件不存在: ' + $exe)
        return $null
    }
    $fileName = ''
    try { $fileName = [System.IO.Path]::GetFileName($exe) } catch { }
    if ($fileName -notmatch '(?i)^(ChatGPT|Codex)\.exe$') {
        Add-ZhDetectionTrace ('指定文件不是 Codex 可执行文件: ' + $exe)
        return $null
    }
    $parent = ''
    try { $parent = Split-Path -Parent $exe } catch { }
    $installRoot = $parent
    if ((Split-Path -Leaf $parent) -ieq 'app') { $installRoot = Split-Path -Parent $parent }
    $isWindowsApps = $installRoot -match '(?i)\\WindowsApps\\'
    if ($isWindowsApps) {
        # 尝试用注册表记录补全 AUMID 等元数据
        $records = Get-ZhRegistryPackages
        foreach ($record in $records) {
            $recordRoot = Resolve-ZhFullPath -Path ([string]$record.RootFolder)
            if ($recordRoot -ieq $installRoot) {
                $install = Get-ZhInstallFromPackageRecord -PackageRecord $record
                if ($null -ne $install) {
                    $install.Source = $Source
                    return $install
                }
            }
        }
        $manifest = Read-ZhAppxManifest -InstallLocation $installRoot
        $family = ''
        $dirName = Split-Path -Leaf $installRoot
        $dirMatch = [regex]::Match($dirName, '^(?<name>[^_]+)_(?<ver>[0-9]+(?:\.[0-9]+){2,3})_(?<arch>[^_]*)_(?<res>[^_]*)_(?<pub>[a-z0-9]+)$')
        if ($dirMatch.Success) { $family = ('{0}_{1}' -f $dirMatch.Groups['name'].Value, $dirMatch.Groups['pub'].Value) }
        $version = ''
        $appId = 'App'
        if ($null -ne $manifest) {
            $version = [string]$manifest.Version
            if ($null -ne $manifest.MainApp -and -not [string]::IsNullOrWhiteSpace([string]$manifest.MainApp.Id)) { $appId = [string]$manifest.MainApp.Id }
        }
        if ([string]::IsNullOrWhiteSpace($version) -and $dirMatch.Success) { $version = $dirMatch.Groups['ver'].Value }
        if ([string]::IsNullOrWhiteSpace($family)) {
            Add-ZhDetectionTrace ('无法推导包族名，AUMID 不可用: ' + $installRoot)
            return $null
        }
        return (New-ZhInstallRecord -Kind 'Store' -InstallLocation $installRoot -ExecutablePath $exe -Version $version `
                -Aumid ($family + '!' + $appId) -PackageFamilyName $family -AppId $appId -Source $Source)
    }
    # 便携版
    $version = ''
    $manifest = Read-ZhAppxManifest -InstallLocation $installRoot
    if ($null -ne $manifest) { $version = [string]$manifest.Version }
    return (New-ZhInstallRecord -Kind 'Portable' -InstallLocation $installRoot -ExecutablePath $exe -Version $version -Source $Source)
}

function Get-ZhInstallFromShellAppsFolder {
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace('shell:AppsFolder')
        if ($null -eq $folder) {
            Add-ZhDetectionTrace 'shell:AppsFolder 不可用'
            return $null
        }
        $items = @($folder.Items())
        Add-ZhDetectionTrace ('shell:AppsFolder 枚举到 {0} 项' -f $items.Count)
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            $aumid = ''
            try { $aumid = [string]$item.Path } catch { }
            if ($aumid -notmatch '^OpenAI\.Codex_') { continue }
            Add-ZhDetectionTrace ('shell:AppsFolder 命中 AUMID: ' + $aumid)
            $family = ''
            if ($aumid -match '^([^!]+)!') { $family = $Matches[1] }
            if ([string]::IsNullOrWhiteSpace($family)) { continue }
            $records = Get-ZhRegistryPackages
            foreach ($record in $records) {
                $recordFamily = ('{0}_{1}' -f $record.Name, $record.PublisherId)
                if ($recordFamily -ieq $family) {
                    $install = Get-ZhInstallFromPackageRecord -PackageRecord $record
                    if ($null -ne $install) {
                        $install.Aumid = $aumid
                        $install.Source = 'ShellAppsFolder'
                        return $install
                    }
                }
            }
        }
    } catch {
        Add-ZhDetectionTrace ('shell:AppsFolder 检测失败: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }
    return $null
}

function Get-ZhInstallFromAppxModule {
    try {
        $package = Get-AppxPackage -Name $script:CodexZhPackageName -ErrorAction SilentlyContinue | Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($null -eq $package) {
            Add-ZhDetectionTrace 'Get-AppxPackage 未返回 OpenAI.Codex'
            return $null
        }
        $root = [string]$package.InstallLocation
        $manifest = Read-ZhAppxManifest -InstallLocation $root
        $version = [string]$package.Version
        $appId = 'App'
        $manifestExecutable = ''
        if ($null -ne $manifest) {
            if (-not [string]::IsNullOrWhiteSpace([string]$manifest.Version)) { $version = [string]$manifest.Version }
            if ($null -ne $manifest.MainApp) {
                $appId = [string]$manifest.MainApp.Id
                $manifestExecutable = [string]$manifest.MainApp.Executable
            }
        }
        if ([string]::IsNullOrWhiteSpace($appId)) { $appId = 'App' }
        $exe = Find-ZhExecutable -InstallLocation $root -ManifestExecutable $manifestExecutable
        if ([string]::IsNullOrWhiteSpace($exe)) { return $null }
        $family = [string]$package.PackageFamilyName
        $aumid = $family + '!' + $appId
        if (-not [string]::IsNullOrWhiteSpace([string]$package.PackageFullName)) {
            return (New-ZhInstallRecord -Kind 'Store' -InstallLocation $root -ExecutablePath $exe -Version $version `
                    -Aumid $aumid -PackageFamilyName $family -PackageFullName ([string]$package.PackageFullName) `
                    -AppId $appId -Source 'AppxModule')
        }
        return (New-ZhInstallRecord -Kind 'Store' -InstallLocation $root -ExecutablePath $exe -Version $version `
                -Aumid $aumid -PackageFamilyName $family -AppId $appId -Source 'AppxModule')
    } catch {
        Add-ZhDetectionTrace ('Get-AppxPackage 不可用: ' + $_.Exception.Message)
        return $null
    }
}

function Get-ZhInstallFromRunningProcess {
    $names = @('ChatGPT', 'Codex')
    foreach ($name in $names) {
        $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $path = Get-ZhProcessPath -Process $process
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if ($path -notmatch '(?i)\\(ChatGPT|Codex)\.exe$') { continue }
            Add-ZhDetectionTrace ('从运行中进程反查安装目录: ' + $path)
            $install = Resolve-ZhInstallFromPath -Path $path -Source 'RunningProcess'
            if ($null -ne $install) { return $install }
        }
    }
    return $null
}

function Get-ZhCodexInstall {
    param([string]$PreferredPath = '')
    $script:CodexZhDetectionTrace = New-Object System.Collections.ArrayList
    Add-ZhDetectionTrace ('开始检测 Codex Desktop（PowerShell {0}）' -f $PSVersionTable.PSVersion.ToString())

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        Add-ZhDetectionTrace ('使用显式指定的路径: ' + $PreferredPath)
        $install = Resolve-ZhInstallFromPath -Path $PreferredPath -Source 'PreferredPath'
        if ($null -ne $install -and $install.IsValid) { return $install }
        Add-ZhDetectionTrace '显式路径无效，继续自动检测'
    }

    $records = Get-ZhRegistryPackages
    foreach ($record in $records) {
        Add-ZhDetectionTrace ('尝试注册表包: ' + $record.PackageId)
        $install = Get-ZhInstallFromPackageRecord -PackageRecord $record
        if ($null -ne $install -and $install.IsValid) {
            Add-ZhDetectionTrace ('检测成功（注册表）: ' + $install.Version)
            return $install
        }
    }

    $install = Get-ZhInstallFromAppxModule
    if ($null -ne $install -and $install.IsValid) {
        Add-ZhDetectionTrace ('检测成功（Appx 模块）: ' + $install.Version)
        return $install
    }

    $install = Get-ZhInstallFromShellAppsFolder
    if ($null -ne $install -and $install.IsValid) {
        Add-ZhDetectionTrace ('检测成功（shell:AppsFolder）: ' + $install.Version)
        return $install
    }

    foreach ($candidate in (Get-ZhPortableCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            Add-ZhDetectionTrace ('发现便携版候选: ' + $candidate)
            $install = Resolve-ZhInstallFromPath -Path $candidate -Source 'PortableCandidate'
            if ($null -ne $install -and $install.IsValid) {
                Add-ZhDetectionTrace '检测成功（便携版）'
                return $install
            }
        }
    }

    $install = Get-ZhInstallFromRunningProcess
    if ($null -ne $install -and $install.IsValid) {
        Add-ZhDetectionTrace ('检测成功（运行中进程）: ' + $install.Version)
        return $install
    }

    Add-ZhDetectionTrace '未能检测到可用的 Codex Desktop 安装'
    return $null
}

# ===========================================================================
# 进程检测 / 安全关闭
# ===========================================================================
function Get-ZhProcessPath {
    param($Process)
    if ($null -eq $Process) { return $null }
    try {
        $path = $Process.Path
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) { return [string]$path }
    } catch { }
    try {
        $module = $Process.MainModule
        if ($null -ne $module) {
            $path = $module.FileName
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) { return [string]$path }
        }
    } catch { }
    return $null
}

function Test-ZhPathOwnedByInstall {
    param(
        $Install,
        [string]$Path
    )
    if ($null -eq $Install -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $fileName = ''
    try { $fileName = [System.IO.Path]::GetFileName($Path) } catch { return $false }
    if ($fileName -notmatch '(?i)^(ChatGPT|Codex)\.exe$') { return $false }
    $fullPath = Resolve-ZhFullPath -Path $Path
    $installLocation = [string]$Install.InstallLocation
    if ([string]::IsNullOrWhiteSpace($installLocation)) { return $false }
    $root = Resolve-ZhFullPath -Path $installLocation
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $rootWithSep = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Install.Kind -eq 'Portable') {
        $parent = ''
        try { $parent = [System.IO.Path]::GetDirectoryName($fullPath) } catch { return $false }
        if ($parent -ieq $root) { return $true }
        $resources = Join-Path $root 'resources'
        $resourcesWithSep = $resources.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($resourcesWithSep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ZhCodexProcessScan {
    param($Install)
    $verified = @()
    $unverified = @()
    $ignored = @()
    $seen = @{}
    foreach ($name in @('ChatGPT', 'Codex')) {
        $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            if ($null -eq $process) { continue }
            if ($seen.ContainsKey($process.Id)) { continue }
            $seen[$process.Id] = $true
            $path = Get-ZhProcessPath -Process $process
            if ([string]::IsNullOrWhiteSpace([string]$path)) {
                $unverified += [pscustomobject]@{ Id = [int]$process.Id; Name = [string]$process.ProcessName }
                continue
            }
            $owned = $false
            if ($null -ne $Install) {
                $owned = (Test-ZhPathOwnedByInstall -Install $Install -Path $path)
            } else {
                $owned = ($path -match '(?i)\\(ChatGPT|Codex)\.exe$')
            }
            if (-not $owned) {
                $ignored += [string]$path
                continue
            }
            $ticks = 0
            $hasWindow = $false
            try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { }
            try { $hasWindow = ($process.MainWindowHandle -ne [IntPtr]::Zero) } catch { }
            $verified += [pscustomobject]@{
                Id               = [int]$process.Id
                Name             = [string]$process.ProcessName
                Path             = (Resolve-ZhFullPath -Path $path)
                StartTimeUtcTicks = [long]$ticks
                HasMainWindow    = [bool]$hasWindow
            }
        }
    }
    return [pscustomobject]@{
        Verified       = @($verified | Sort-Object -Property Id)
        Unverified     = @($unverified | Sort-Object -Property Id)
        Ignored        = @($ignored)
        TotalPotential = ($verified.Count + $unverified.Count)
    }
}

function Get-ZhRevalidatedProcess {
    param(
        $Install,
        $Snapshot
    )
    $result = [pscustomobject]@{ Process = $null; Error = '' }
    if ($null -eq $Snapshot) { $result.Error = '快照为空'; return $result }
    $process = $null
    try {
        $process = Get-Process -Id ([int]$Snapshot.Id) -ErrorAction Stop
    } catch {
        return $result
    }
    try {
        $path = Get-ZhProcessPath -Process $process
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            $result.Error = ('PID {0} 的路径无法重新验证，已拒绝终止' -f $Snapshot.Id)
            return $result
        }
        if (-not (Test-ZhPathOwnedByInstall -Install $Install -Path $path)) {
            $result.Error = ('PID {0} 已不再属于当前 Codex 安装' -f $Snapshot.Id)
            return $result
        }
        $ticks = 0
        try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { }
        if ($ticks -ne [long]$Snapshot.StartTimeUtcTicks -or -not ((Resolve-ZhFullPath -Path $path) -ieq [string]$Snapshot.Path)) {
            $result.Error = ('PID {0} 已被其他进程复用，已拒绝终止' -f $Snapshot.Id)
            return $result
        }
        $result.Process = $process
        return $result
    } catch {
        $result.Error = ('PID {0} 重新验证失败: {1}' -f $Snapshot.Id, $_.Exception.Message)
        return $result
    } finally {
        if ($null -eq $result.Process -and $null -ne $process) {
            try { $process.Dispose() } catch { }
        }
    }
}

function Wait-ZhNoVerifiedProcess {
    param(
        $Install,
        [int]$TimeoutSec = 5,
        [int]$IntervalMs = 250
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $scan = Get-ZhCodexProcessScan -Install $Install
        if ($scan.Verified.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds $IntervalMs
    }
    $final = Get-ZhCodexProcessScan -Install $Install
    return ($final.Verified.Count -eq 0)
}

function Close-ZhCodexSafely {
    param(
        $Install,
        [int]$GracefulSec = 5,
        [int]$ForceSec = 8,
        [switch]$AllowUnverified
    )
    $report = [pscustomobject]@{
        Success           = $false
        Aborted           = $false
        Reason            = ''
        Message           = ''
        InitialVerified   = 0
        InitialUnverified = 0
        GracefulRequested = 0
        GracefulExited    = 0
        ForceAttempted    = 0
        ForceTerminated   = 0
        RemainingVerified = 0
        RemainingUnverified = 0
        FailedProcessIds  = @()
        Errors            = @()
        Details           = @()
    }
    if ($null -eq $Install) {
        $report.Reason = 'NO_INSTALL'
        $report.Message = '没有可用的 Codex 安装信息，无法安全关闭。'
        return $report
    }
    $selfPath = ''
    try { $selfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if (-not [string]::IsNullOrWhiteSpace($selfPath) -and (Test-ZhPathOwnedByInstall -Install $Install -Path $selfPath)) {
        $report.Reason = 'SELF_MATCH'
        $report.Message = '当前进程属于 Codex 安装目录，已拒绝关闭。'
        return $report
    }

    $scan = Get-ZhCodexProcessScan -Install $Install
    $report.InitialVerified = $scan.Verified.Count
    $report.InitialUnverified = $scan.Unverified.Count
    Write-ZhLog 'INFO' ('关闭前进程扫描: verified={0}, unverified={1}, ignored={2}' -f $scan.Verified.Count, $scan.Unverified.Count, $scan.Ignored.Count)
    if ($scan.Ignored.Count -gt 0) {
        foreach ($ignoredPath in $scan.Ignored) {
            $report.Details += ('忽略其他安装路径的进程: ' + $ignoredPath)
            Write-ZhLog 'INFO' ('忽略其他安装路径的进程: ' + $ignoredPath)
        }
    }
    if ($scan.Unverified.Count -gt 0) {
        foreach ($item in $scan.Unverified) {
            $report.FailedProcessIds += [int]$item.Id
            $report.Errors += ('PID {0} 的进程路径无法读取，出于安全考虑已拒绝继续。' -f $item.Id)
        }
        if (-not $AllowUnverified) {
            $report.Aborted = $true
            $report.Reason = 'UNVERIFIED_PROCESSES'
            $report.Message = ('检测到 {0} 个无法验证路径的 Codex 进程，已中止（不盲杀）。请从托盘完全退出 Codex 后重试。' -f $scan.Unverified.Count)
            return $report
        }
        $report.Details += '已指定 -AllowUnverified：将只关闭路径可验证的进程。'
    }
    if ($scan.Verified.Count -eq 0) {
        $report.Success = $true
        $report.Message = '没有正在运行的 Codex 进程，无需关闭。'
        return $report
    }

    # 1) 优雅关闭（仅主窗口）
    foreach ($snapshot in $scan.Verified) {
        if (-not $snapshot.HasMainWindow) { continue }
        $revalidated = Get-ZhRevalidatedProcess -Install $Install -Snapshot $snapshot
        if ($null -eq $revalidated.Process) {
            if (-not [string]::IsNullOrWhiteSpace($revalidated.Error)) { $report.Errors += $revalidated.Error }
            continue
        }
        try {
            $requested = $false
            try { $requested = $revalidated.Process.CloseMainWindow() } catch { }
            if ($requested) {
                $report.GracefulRequested += 1
                Write-ZhLog 'INFO' ('已请求优雅关闭 PID {0}' -f $snapshot.Id)
            }
        } finally {
            try { $revalidated.Process.Dispose() } catch { }
        }
    }
    if ($report.GracefulRequested -gt 0) {
        Write-ZhInfo ('已请求 Codex 正常退出，最多等待 {0} 秒...' -f $GracefulSec)
        [void](Wait-ZhNoVerifiedProcess -Install $Install -TimeoutSec $GracefulSec)
    } else {
        Write-ZhInfo '没有可响应关闭请求的主窗口，将直接处理后台进程。'
    }
    $afterGraceful = Get-ZhCodexProcessScan -Install $Install
    $remainingIds = @{}
    foreach ($item in $afterGraceful.Verified) { $remainingIds[[int]$item.Id] = $true }
    foreach ($snapshot in $scan.Verified) {
        if (-not $remainingIds.ContainsKey([int]$snapshot.Id)) { $report.GracefulExited += 1 }
    }
    if ($afterGraceful.Verified.Count -eq 0) {
        $report.Success = $true
        $report.Message = 'Codex 已正常退出。'
        $report.RemainingUnverified = $afterGraceful.Unverified.Count
        if ($afterGraceful.Unverified.Count -gt 0) { $report.Success = $false }
        return $report
    }

    # 2) 强制关闭（再次校验 PID + StartTime + Path）
    Write-ZhInfo ('正常退出等待结束，准备强制结束 {0} 个残留进程...' -f $afterGraceful.Verified.Count)
    $forceRequested = @()
    foreach ($snapshot in $afterGraceful.Verified) {
        $revalidated = Get-ZhRevalidatedProcess -Install $Install -Snapshot $snapshot
        if ($null -eq $revalidated.Process) {
            if (-not [string]::IsNullOrWhiteSpace($revalidated.Error)) { $report.Errors += $revalidated.Error }
            continue
        }
        try {
            $report.ForceAttempted += 1
            Write-ZhLog 'INFO' ('强制结束 PID {0}，路径 {1}' -f $snapshot.Id, $snapshot.Path)
            Stop-Process -Id $revalidated.Process.Id -Force -ErrorAction Stop
            $forceRequested += $snapshot
        } catch {
            $report.Errors += ('强制结束 PID {0} 失败: {1}' -f $snapshot.Id, $_.Exception.Message)
        } finally {
            try { $revalidated.Process.Dispose() } catch { }
        }
    }
    [void](Wait-ZhNoVerifiedProcess -Install $Install -TimeoutSec $ForceSec)
    $finalScan = Get-ZhCodexProcessScan -Install $Install
    $finalIds = @{}
    foreach ($item in $finalScan.Verified) { $finalIds[[int]$item.Id] = $true }
    foreach ($snapshot in $forceRequested) {
        if (-not $finalIds.ContainsKey([int]$snapshot.Id)) { $report.ForceTerminated += 1 }
    }
    $report.RemainingVerified = $finalScan.Verified.Count
    $report.RemainingUnverified = $finalScan.Unverified.Count
    foreach ($item in $finalScan.Verified) {
        $report.FailedProcessIds += [int]$item.Id
        $report.Errors += ('PID {0} 仍在运行' -f $item.Id)
    }
    foreach ($item in $finalScan.Unverified) {
        $report.FailedProcessIds += [int]$item.Id
        $report.Errors += ('PID {0} 路径无法验证且仍在运行' -f $item.Id)
    }
    $report.Success = ($finalScan.Verified.Count -eq 0 -and $finalScan.Unverified.Count -eq 0)
    if ($report.Success) {
        $report.Message = '全部 Codex 进程已关闭。'
    } else {
        $report.Reason = 'REMAINING_PROCESSES'
        $report.Message = ('仍有 {0} 个 Codex 进程未关闭，已停止自动重启（避免双实例）。' -f ($finalScan.Verified.Count + $finalScan.Unverified.Count))
    }
    return $report
}

# ===========================================================================
# 原生 API（COM 激活 / 窗口焦点）
# ===========================================================================
function Initialize-ZhNativeTypes {
    if ('CodexZhNative.Activation' -as [type]) { return }
    $source = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexZhNative
{
    [Flags]
    public enum ActivateOptions { None = 0x00000000, DesignMode = 0x00000001, NoErrorUi = 0x00000002, NoSplashScreen = 0x00000004 }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);
    }

    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    public class ApplicationActivationManager
    {
    }

    public static class Activation
    {
        public static int Activate(string aumid, string arguments, out uint processId)
        {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            return manager.ActivateApplication(aumid, arguments, ActivateOptions.NoErrorUi, out processId);
        }
    }

    public static class WindowTools
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder buffer, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder buffer, int maxCount);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int command);
        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        private static bool IsCodexMainWindow(IntPtr hWnd, out RECT rect)
        {
            rect = new RECT();
            var className = new StringBuilder(256);
            GetClassName(hWnd, className, 256);
            if (className.ToString().IndexOf("Chrome_WidgetWin_1", StringComparison.OrdinalIgnoreCase) < 0) return false;
            if (!GetWindowRect(hWnd, out rect)) return false;
            if ((rect.Right - rect.Left) < 400 || (rect.Bottom - rect.Top) < 300) return false;
            return true;
        }

        private static void ShowAndForeground(IntPtr hWnd, ref int focused)
        {
            if (IsIconic(hWnd)) ShowWindow(hWnd, 9);
            ShowWindow(hWnd, 5);          // SW_SHOW
            ShowWindow(hWnd, 9);          // SW_RESTORE
            ShowWindowAsync(hWnd, 9);
            SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040); // HWND_TOP|SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            focused += 1;
        }

        public static int FocusByProcessIds(int[] processIds)
        {
            if (processIds == null || processIds.Length == 0) return 0;
            var ids = new HashSet<int>(processIds);
            int focused = 0;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (!ids.Contains((int)pid)) return true;
                RECT rect;
                if (!IsCodexMainWindow(hWnd, out rect)) return true;
                ShowAndForeground(hWnd, ref focused);
                return true;
            }, IntPtr.Zero);
            return focused;
        }

        public static int FocusByTitleTokens(string[] titleTokens)
        {
            if (titleTokens == null || titleTokens.Length == 0) return 0;
            int focused = 0;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                RECT rect;
                if (!IsCodexMainWindow(hWnd, out rect)) return true;
                var title = new StringBuilder(512);
                GetWindowText(hWnd, title, 512);
                string text = title.ToString();
                bool match = false;
                for (int i = 0; i < titleTokens.Length; i++)
                {
                    if (!String.IsNullOrEmpty(titleTokens[i]) &&
                        text.IndexOf(titleTokens[i], StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        match = true;
                        break;
                    }
                }
                if (!match) return true;
                ShowAndForeground(hWnd, ref focused);
                return true;
            }, IntPtr.Zero);
            return focused;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp | Out-Null
}

function Activate-ZhStoreApp {
    param(
        [Parameter(Mandatory = $true)][string]$Aumid,
        [string]$Arguments = ''
    )
    $result = [pscustomobject]@{ Ok = $false; HResult = 0; ProcessId = 0; Message = '' }
    Initialize-ZhNativeTypes
    $processId = [uint32]0
    try {
        $hr = [CodexZhNative.Activation]::Activate($Aumid, $Arguments, [ref]$processId)
        $result.HResult = [int]$hr
        $result.ProcessId = [int]$processId
        if ($hr -lt 0) {
            $result.Message = ('ActivateApplication 失败，HRESULT=0x{0:X8}' -f ($hr -band 0xFFFFFFFFL))
        } else {
            $result.Ok = $true
            $result.Message = 'IApplicationActivationManager 激活成功'
        }
    } catch {
        $result.Message = 'COM 激活异常: ' + $_.Exception.Message
    }
    return $result
}

function Start-ZhOriginalCodex {
    param($Install, [int]$WaitSeconds = 3)
    $result = [pscustomobject]@{ Ok = $false; Method = ''; ProcessId = 0; Message = '' }
    if ($null -eq $Install) {
        $result.Message = '没有可用的 Codex 安装信息。'
        return $result
    }
    if ($Install.Kind -eq 'Store' -and -not [string]::IsNullOrWhiteSpace([string]$Install.Aumid)) {
        $activation = Activate-ZhStoreApp -Aumid ([string]$Install.Aumid) -Arguments ''
        if ($activation.Ok) {
            $result.Ok = $true
            $result.Method = 'IApplicationActivationManager'
            $result.ProcessId = $activation.ProcessId
            $result.Message = '已通过 IApplicationActivationManager 正常启动 Codex。'
            return $result
        }
        Write-ZhLog 'WARN' ('COM 普通启动失败，尝试 shell:AppsFolder 回退: ' + $activation.Message)
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + [string]$Install.Aumid)
            $result.Ok = $true
            $result.Method = 'shell:AppsFolder'
            $result.Message = '已通过 shell:AppsFolder 正常启动 Codex。'
            return $result
        } catch {
            $result.Message = '无法启动 Codex: ' + $_.Exception.Message
            return $result
        }
    }
    $exe = [string]$Install.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        $result.Message = '找不到 Codex 可执行文件。'
        return $result
    }
    try {
        $startInfo = @{ FilePath = $exe }
        if (-not [string]::IsNullOrWhiteSpace([string]$Install.InstallLocation)) { $startInfo['WorkingDirectory'] = [string]$Install.InstallLocation }
        $process = Start-Process @startInfo -PassThru
        $result.Ok = $true
        $result.Method = 'Start-Process'
        if ($null -ne $process) { $result.ProcessId = [int]$process.Id }
        $result.Message = '已启动便携版 Codex。'
    } catch {
        $result.Message = '启动便携版失败: ' + $_.Exception.Message
    }
    return $result
}

function Start-ZhCodexWithArguments {
    param(
        $Install,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    $result = [pscustomobject]@{ Ok = $false; Method = ''; ProcessId = 0; HResult = 0; Message = '' }
    if ($null -eq $Install) {
        $result.Message = '没有可用的 Codex 安装信息。'
        return $result
    }
    if ($Install.Kind -eq 'Store') {
        if ([string]::IsNullOrWhiteSpace([string]$Install.Aumid)) {
            $result.Message = '缺少 AUMID，无法激活 Store 版 Codex。'
            return $result
        }
        $activation = Activate-ZhStoreApp -Aumid ([string]$Install.Aumid) -Arguments $Arguments
        $result.Ok = $activation.Ok
        $result.Method = 'IApplicationActivationManager'
        $result.ProcessId = $activation.ProcessId
        $result.HResult = $activation.HResult
        $result.Message = $activation.Message
        return $result
    }
    $exe = [string]$Install.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        $result.Message = '找不到 Codex 可执行文件。'
        return $result
    }
    try {
        $startInfo = @{ FilePath = $exe; ArgumentList = $Arguments }
        if (-not [string]::IsNullOrWhiteSpace([string]$Install.InstallLocation)) { $startInfo['WorkingDirectory'] = [string]$Install.InstallLocation }
        $process = Start-Process @startInfo -PassThru
        $result.Ok = $true
        $result.Method = 'Start-Process'
        if ($null -ne $process) { $result.ProcessId = [int]$process.Id }
        $result.Message = '便携版进程已带参数启动。'
    } catch {
        $result.Message = '启动便携版失败: ' + $_.Exception.Message
    }
    return $result
}

function Focus-ZhCodexWindows {
    param($Install)
    if ($null -eq $Install) { return 0 }
    try {
        Initialize-ZhNativeTypes
    } catch {
        return 0
    }
    $focused = 0
    $scan = Get-ZhCodexProcessScan -Install $Install
    if ($scan.Verified.Count -gt 0) {
        $ids = @()
        foreach ($item in $scan.Verified) { $ids += [int]$item.Id }
        try {
            $focused = [int][CodexZhNative.WindowTools]::FocusByProcessIds([int[]]$ids)
        } catch {
            $focused = 0
        }
    }
    if ($focused -eq 0) {
        # 兜底：按窗口标题匹配（部分版本主窗口进程与激活 PID 不一致）
        try {
            $focused = [int][CodexZhNative.WindowTools]::FocusByTitleTokens([string[]]@('ChatGPT', 'Codex', 'codex'))
        } catch {
            $focused = 0
        }
    }
    return $focused
}

function Show-ZhCodexWindows {
    param($Install)
    $focused = Focus-ZhCodexWindows -Install $Install
    if ($focused -gt 0) {
        Write-ZhOk ('已显示并置前 Codex 主窗口（{0} 个窗口）。' -f $focused)
    } else {
        Write-ZhInfo '未能自动显示 Codex 主窗口；如果窗口隐藏在后台，请从任务栏点击 Codex。'
    }
    return $focused
}

# ===========================================================================
# 端口 / HTTP 探测
# ===========================================================================
function Reserve-ZhLoopbackPort {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $endpoint = [System.Net.IPEndPoint]$listener.LocalEndpoint
        return [int]$endpoint.Port
    } catch {
        throw ('无法预留本地端口: {0}' -f $_.Exception.Message)
    } finally {
        if ($null -ne $listener) { try { $listener.Stop() } catch { } }
    }
}

function New-ZhPortPair {
    $renderer = Reserve-ZhLoopbackPort
    $inspector = Reserve-ZhLoopbackPort
    $guard = 0
    while ($inspector -eq $renderer -and $guard -lt 12) {
        $inspector = Reserve-ZhLoopbackPort
        $guard += 1
    }
    return [pscustomobject]@{ Renderer = [int]$renderer; Inspector = [int]$inspector }
}

function Invoke-ZhHttpGet {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 2000
    )
    $result = [pscustomobject]@{ Ok = $false; StatusCode = 0; Content = ''; Error = '' }
    $request = $null
    $response = $null
    $reader = $null
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.Method = 'GET'
        $response = $request.GetResponse()
        $result.StatusCode = [int]$response.StatusCode
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $result.Content = $reader.ReadToEnd()
        $result.Ok = ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300)
    } catch {
        $inner = $_.Exception
        $guard = 0
        while ($null -ne $inner.InnerException -and $guard -lt 6) { $inner = $inner.InnerException; $guard += 1 }
        $result.Error = [string]$inner.Message
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
        if ($null -ne $response) { try { $response.Dispose() } catch { } }
    }
    return $result
}

function Wait-ZhHttpPortReady {
    param(
        [int]$Port,
        [int]$TimeoutSec = 25,
        [string]$Path = '/json/version',
        [int]$IntervalMs = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastError = ''
    while ((Get-Date) -lt $deadline) {
        $response = Invoke-ZhHttpGet -Url ('http://127.0.0.1:{0}{1}' -f $Port, $Path) -TimeoutMs 1500
        if ($response.Ok) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($response.Error)) { $lastError = $response.Error }
        Start-Sleep -Milliseconds $IntervalMs
    }
    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        Write-ZhLog 'WARN' ('等待端口 {0} 失败，最后错误: {1}' -f $Port, $lastError)
    }
    return $false
}

function Wait-ZhRendererPort {
    param([int]$Port, [int]$TimeoutSec = 25)
    return (Wait-ZhHttpPortReady -Port $Port -TimeoutSec $TimeoutSec -Path '/json/version')
}

function Wait-ZhInspectorPort {
    param([int]$Port, [int]$TimeoutSec = 5)
    return (Wait-ZhHttpPortReady -Port $Port -TimeoutSec $TimeoutSec -Path '/json/list')
}

# ===========================================================================
# 语言配置文件（config.toml [desktop] localeOverride）
# ===========================================================================
function Get-ZhConfigPath {
    $profileDir = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profileDir)) {
        try { $profileDir = [System.Environment]::GetFolderPath('UserProfile') } catch { }
    }
    return (Join-Path $profileDir '.codex\config.toml')
}

function Get-ZhConfigBackupPath {
    param([string]$ConfigPath = '')
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-ZhConfigPath }
    return ($ConfigPath + '.bak-zhcn')
}

function Get-ZhConfigSegments {
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return @() }
    return @([regex]::Split($Content, '(?<=\n)'))
}

function Get-ZhLineEnding {
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return "`r`n" }
    if ($Content -match "`r`n") { return "`r`n" }
    if ($Content -match "`n") { return "`n" }
    return "`r`n"
}

function Get-ZhSegmentLineEnding {
    param([string]$Segment)
    if ($null -eq $Segment) { return '' }
    if ($Segment.EndsWith("`r`n")) { return "`r`n" }
    if ($Segment.EndsWith("`n")) { return "`n" }
    return ''
}

function Get-ZhLocaleOverrideValue {
    param([string]$Content)
    $result = [pscustomobject]@{ Present = $false; Value = ''; InDesktopSection = $false }
    $inDesktop = $false
    foreach ($segment in (Get-ZhConfigSegments -Content $Content)) {
        $line = ([string]$segment).TrimEnd("`r", "`n")
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $inDesktop = ($Matches[1].Trim() -eq 'desktop')
            continue
        }
        if (-not $inDesktop) { continue }
        if ($line -match '^\s*localeOverride\s*=\s*(?<quote>[''"])(?<value>.*)\k<quote>\s*$') {
            $result.Present = $true
            $result.InDesktopSection = $true
            $result.Value = [string]$Matches['value']
        }
    }
    return $result
}

function Update-ZhLocaleOverrideContent {
    param(
        [string]$Content,
        [string]$Locale
    )
    $localeLine = 'localeOverride = "' + $Locale + '"'
    $segments = @(Get-ZhConfigSegments -Content $Content)
    $inDesktop = $false
    $desktopIndex = -1
    $desktopEol = Get-ZhLineEnding -Content $Content
    $replaced = $false
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = [string]$segments[$index]
        $line = $segment.TrimEnd("`r", "`n")
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $inDesktop = ($Matches[1].Trim() -eq 'desktop')
            if ($inDesktop -and $desktopIndex -lt 0) {
                $desktopIndex = $index
                $segmentEol = Get-ZhSegmentLineEnding -Segment $segment
                if (-not [string]::IsNullOrEmpty($segmentEol)) { $desktopEol = $segmentEol }
            }
            continue
        }
        if ($inDesktop -and -not $replaced -and $line -match '^\s*localeOverride\s*=') {
            $segmentEol = Get-ZhSegmentLineEnding -Segment $segment
            if ([string]::IsNullOrEmpty($segmentEol)) { $segmentEol = $desktopEol }
            $segments[$index] = $localeLine + $segmentEol
            $replaced = $true
        }
    }
    if ($replaced) { return ($segments -join '') }
    if ($desktopIndex -ge 0) {
        $list = New-Object System.Collections.ArrayList
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $segment = [string]$segments[$index]
            [void]$list.Add($segment)
            if ($index -eq $desktopIndex) {
                $segmentEol = Get-ZhSegmentLineEnding -Segment $segment
                if ([string]::IsNullOrEmpty($segmentEol)) {
                    [void]$list.Add($desktopEol + $localeLine + $desktopEol)
                } else {
                    [void]$list.Add($localeLine + $segmentEol)
                }
            }
        }
        return ($list -join '')
    }
    $eol = Get-ZhLineEnding -Content $Content
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ('[desktop]' + $eol + $localeLine + $eol)
    }
    return ($Content.TrimEnd() + $eol + $eol + '[desktop]' + $eol + $localeLine + $eol)
}

function Remove-ZhLocaleOverrideContent {
    param([string]$Content)
    $result = [pscustomobject]@{ Content = $Content; Removed = 0 }
    if ([string]::IsNullOrEmpty($Content)) { return $result }
    $segments = @(Get-ZhConfigSegments -Content $Content)
    $inDesktop = $false
    $kept = New-Object System.Collections.ArrayList
    foreach ($segment in $segments) {
        $line = ([string]$segment).TrimEnd("`r", "`n")
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $inDesktop = ($Matches[1].Trim() -eq 'desktop')
            [void]$kept.Add($segment)
            continue
        }
        if ($inDesktop -and $line -match '^\s*localeOverride\s*=') {
            $result.Removed += 1
            continue
        }
        [void]$kept.Add($segment)
    }
    $result.Content = ($kept -join '')
    if ($result.Removed -gt 0 -and $result.Content.Trim() -eq '[desktop]') { $result.Content = '' }
    return $result
}

function Test-ZhLocaleOverride {
    param(
        [string]$ConfigPath = '',
        [string]$Locale = ''
    )
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-ZhConfigPath }
    if ([string]::IsNullOrWhiteSpace($Locale)) { $Locale = $script:CodexZhDefaultLocale }
    $result = [pscustomobject]@{ ConfigPath = $ConfigPath; Exists = $false; Present = $false; Value = ''; Verified = $false }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $result }
    $result.Exists = $true
    try {
        $content = [System.IO.File]::ReadAllText($ConfigPath)
        $current = Get-ZhLocaleOverrideValue -Content $content
        $result.Present = $current.Present
        $result.Value = $current.Value
        $result.Verified = ($current.Present -and $current.InDesktopSection -and $current.Value -ieq $Locale)
    } catch { }
    return $result
}

function Set-ZhLocaleOverride {
    param(
        [string]$ConfigPath = '',
        [string]$Locale = ''
    )
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-ZhConfigPath }
    if ([string]::IsNullOrWhiteSpace($Locale)) { $Locale = $script:CodexZhDefaultLocale }
    $result = [pscustomobject]@{
        ConfigPath        = $ConfigPath
        BackupPath        = (Get-ZhConfigBackupPath -ConfigPath $ConfigPath)
        Created           = $false
        Modified          = $false
        AlreadyConfigured = $false
        PreviousValue     = ''
        Verified          = $false
        Error             = ''
    }
    try {
        $configDir = Split-Path -Parent $ConfigPath
        if (-not [string]::IsNullOrWhiteSpace($configDir) -and -not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        $exists = Test-Path -LiteralPath $ConfigPath
        $content = ''
        if ($exists) { $content = [System.IO.File]::ReadAllText($ConfigPath) }
        $current = Get-ZhLocaleOverrideValue -Content $content
        $result.PreviousValue = [string]$current.Value
        if ($current.Present -and $current.InDesktopSection -and $current.Value -ieq $Locale) {
            $result.AlreadyConfigured = $true
            $result.Verified = $true
            Write-ZhLog 'INFO' ('config.toml 已包含 [desktop] localeOverride = "{0}"，无需修改' -f $Locale)
            return $result
        }
        if ($exists -and -not [string]::IsNullOrWhiteSpace($content) -and -not (Test-Path -LiteralPath $result.BackupPath)) {
            Copy-Item -LiteralPath $ConfigPath -Destination $result.BackupPath -Force
            Write-ZhLog 'INFO' ('已备份原配置: ' + $result.BackupPath)
        }
        $result.Created = (-not $exists)
        $updated = Update-ZhLocaleOverrideContent -Content $content -Locale $Locale
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ConfigPath, $updated, $encoding)
        $result.Modified = $true
        $check = Test-ZhLocaleOverride -ConfigPath $ConfigPath -Locale $Locale
        $result.Verified = $check.Verified
        if (-not $check.Verified) {
            $result.Error = '写入后复验失败：config.toml 中未找到 [desktop] localeOverride。'
            Write-ZhLog 'ERROR' $result.Error
        } else {
            Write-ZhLog 'INFO' ('已写入 [desktop] localeOverride = "{0}"（备份: {1}）' -f $Locale, $result.BackupPath)
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-ZhLog 'ERROR' ('写入 localeOverride 失败: ' + $result.Error)
    }
    return $result
}

function Restore-ZhConfigFile {
    param([string]$ConfigPath = '')
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-ZhConfigPath }
    $result = [pscustomobject]@{
        ConfigPath = $ConfigPath
        BackupPath = (Get-ZhConfigBackupPath -ConfigPath $ConfigPath)
        Restored   = $false
        Method     = 'none'
        RemovedLines = 0
        Verified   = $false
        Error      = ''
    }
    try {
        $backupPath = $result.BackupPath
        if (Test-Path -LiteralPath $backupPath) {
            $backupContent = [System.IO.File]::ReadAllText($backupPath)
            if (Test-Path -LiteralPath $ConfigPath) {
                Copy-Item -LiteralPath $backupPath -Destination $ConfigPath -Force
            } else {
                Copy-Item -LiteralPath $backupPath -Destination $ConfigPath -Force
            }
            Remove-Item -LiteralPath $backupPath -Force
            $result.Restored = $true
            $result.Method = 'backup'
            $restoredContent = ''
            if (Test-Path -LiteralPath $ConfigPath) { $restoredContent = [System.IO.File]::ReadAllText($ConfigPath) }
            $result.Verified = ($restoredContent -eq $backupContent)
            if (-not $result.Verified) { $result.Error = '从备份还原后内容校验不一致。' }
            Write-ZhLog 'INFO' ('已从备份还原 config.toml: ' + $backupPath)
            return $result
        }
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            $result.Verified = $true
            $result.Method = 'absent'
            return $result
        }
        $content = [System.IO.File]::ReadAllText($ConfigPath)
        $removed = Remove-ZhLocaleOverrideContent -Content $content
        if ($removed.Removed -gt 0) {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($ConfigPath, $removed.Content, $encoding)
            $result.Restored = $true
            $result.Method = 'line-removal'
            $result.RemovedLines = $removed.Removed
            $check = Test-ZhLocaleOverride -ConfigPath $ConfigPath
            $result.Verified = (-not $check.Present)
            if (-not $result.Verified) { $result.Error = '删除 localeOverride 后复验仍检测到该设置。' }
            Write-ZhLog 'INFO' ('已从 config.toml 精确删除 {0} 行 localeOverride' -f $removed.Removed)
        } else {
            $result.Verified = $true
            $result.Method = 'nothing-to-do'
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-ZhLog 'ERROR' ('还原 config.toml 失败: ' + $result.Error)
    }
    return $result
}

function Get-ZhConfigSummary {
    param([string]$ConfigPath = '')
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-ZhConfigPath }
    $summary = [pscustomobject]@{
        Path                  = $ConfigPath
        Exists                = $false
        SizeBytes             = 0
        LastWriteTime         = ''
        DesktopSection        = $false
        LocaleOverridePresent = $false
        LocaleOverrideValue   = ''
        BackupExists          = $false
        SectionNames          = @()
    }
    $summary.BackupExists = (Test-Path -LiteralPath (Get-ZhConfigBackupPath -ConfigPath $ConfigPath))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $summary }
    try {
        $file = Get-Item -LiteralPath $ConfigPath
        $summary.Exists = $true
        $summary.SizeBytes = [long]$file.Length
        $summary.LastWriteTime = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $content = [System.IO.File]::ReadAllText($ConfigPath)
        $sections = @()
        foreach ($match in [regex]::Matches($content, '(?m)^\s*\[([^\]]+)\]\s*$')) {
            $name = $match.Groups[1].Value.Trim()
            if ($sections -notcontains $name) { $sections += $name }
        }
        $summary.SectionNames = $sections
        $summary.DesktopSection = ($sections -contains 'desktop')
        $current = Get-ZhLocaleOverrideValue -Content $content
        $summary.LocaleOverridePresent = $current.Present
        $summary.LocaleOverrideValue = [string]$current.Value
    } catch { }
    return $summary
}

function Test-ZhInstalled {
    param([string]$ConfigPath = '')
    $state = Get-ZhState
    $config = Test-ZhLocaleOverride -ConfigPath $ConfigPath
    $stateInstalled = $false
    if ($null -ne $state) {
        $value = Get-ZhNestedValue -Object $state -Path 'installed' -Default $false
        if ($value -eq $true) { $stateInstalled = $true }
    }
    $reason = ''
    $installed = $false
    if ($stateInstalled -and $config.Verified) {
        $installed = $true
        $reason = 'state+config'
    } elseif ($config.Verified) {
        $installed = $true
        $reason = 'config-only'
    } elseif ($stateInstalled) {
        $reason = 'state-only'
    } else {
        $reason = 'not-installed'
    }
    return [pscustomobject]@{
        Installed      = $installed
        StateInstalled = $stateInstalled
        ConfigVerified = $config.Verified
        Reason         = $reason
    }
}

# ===========================================================================
# Node / CDP 驱动调用
# ===========================================================================
function Get-ZhNodeInfo {
    $result = [pscustomobject]@{
        Available = $false
        Path      = ''
        Version   = ''
        Major     = 0
        Minimum   = $script:CodexZhNodeMinMajor
        Ok        = $false
        Message   = ''
    }
    $candidates = @()
    try {
        $command = Get-Command -Name 'node.exe' -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) { $candidates += [string]$command.Source }
    } catch { }
    try {
        $command = Get-Command -Name 'node' -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) { $candidates += [string]$command.Source }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    }
    $programFilesX86 = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates += (Join-Path $programFilesX86 'nodejs\node.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    }
    $foundPath = ''
    $foundVersion = ''
    $unique = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        if ($unique.ContainsKey($candidate)) { continue }
        $unique[$candidate] = $true
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        if ($foundPath -eq '') { $foundPath = $candidate }
        $versionText = ''
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $versionText = [string](& $candidate -p 'process.versions.node' 2>$null | Select-Object -First 1)
        } catch {
            $versionText = ''
        } finally {
            $ErrorActionPreference = $oldPreference
        }
        $versionText = $versionText.Trim()
        if ($versionText -match '^\d+\.\d+\.\d+') {
            $parsed = ConvertTo-ZhVersion -Version $versionText
            if ($null -ne $parsed) {
                $result.Available = $true
                $result.Path = $candidate
                $result.Version = $versionText
                $result.Major = [int]$parsed.Major
                if ($parsed.Major -ge $script:CodexZhNodeMinMajor) {
                    $result.Ok = $true
                    $result.Message = ('Node.js {0} 可用（{1}）' -f $versionText, $candidate)
                    return $result
                }
                $foundVersion = $versionText
            }
        }
    }
    if ($foundPath -ne '' -and $foundVersion -ne '') {
        $result.Available = $true
        $result.Path = $foundPath
        $result.Version = $foundVersion
        $result.Message = ('Node.js 版本过低（{0}），运行时注入需要 >= {1}。' -f $foundVersion, $script:CodexZhNodeMinMajor)
        return $result
    }
    if ($foundPath -ne '' -and $foundVersion -eq '') {
        $result.Available = $false
        $result.Path = $foundPath
        $result.Message = ('找到 node（{0}），但无法读取其版本。' -f $foundPath)
        return $result
    }
    $result.Message = ('未找到 Node.js。运行时汉化需要 Node.js >= {0}，请安装后重试（https://nodejs.org/）。' -f $script:CodexZhNodeMinMajor)
    return $result
}

function Invoke-ZhCdpDriver {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [int]$RendererPort = 0,
        [int]$InspectorPort = 0,
        [string]$Mode = 'inject',
        [string]$LogPath = ''
    )
    $driver = Join-Path $script:CodexZhRoot 'lib\cdp.mjs'
    $assetsDir = Join-Path $script:CodexZhRoot 'assets'
    $node = Get-ZhNodeInfo
    $result = [pscustomobject]@{
        ExitCode   = -1
        Result     = $null
        Code       = 'CDP_FAILED'
        Status     = 'failed'
        Output     = @()
        ResultFile = $ResultPath
        Error      = ''
    }
    if (-not $node.Ok) {
        $result.Code = 'NODE_UNAVAILABLE'
        $result.Error = $node.Message
        return $result
    }
    if (-not (Test-Path -LiteralPath $driver)) {
        $result.Code = 'TOOL_FILES_MISSING'
        $result.Error = '缺少 CDP 驱动文件: ' + $driver
        return $result
    }
    $arguments = @(
        $driver,
        '--mode', $Mode,
        '--renderer-port', [string]$RendererPort,
        '--inspector-port', [string]$InspectorPort,
        '--assets-dir', $assetsDir,
        '--result', $ResultPath,
        '--locale', $script:CodexZhDefaultLocale
    )
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $arguments += @('--log-file', $LogPath) }
    Write-ZhLog 'INFO' ('调用 CDP 驱动: {0} {1}' -f $node.Path, ($arguments -join ' '))
    $output = @()
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $node.Path @arguments 2>&1)
        $result.ExitCode = [int]$LASTEXITCODE
    } catch {
        $result.ExitCode = -1
        $result.Error = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $result.Output = @($output)
    foreach ($line in $output) { Write-ZhLog 'CDP' ([string]$line) }
    if (Test-Path -LiteralPath $ResultPath) {
        $parsed = Read-ZhJsonFile -Path $ResultPath
        if ($null -ne $parsed) {
            $result.Result = $parsed
            $codeValue = Get-ZhNestedValue -Object $parsed -Path 'code' -Default ''
            $statusValue = Get-ZhNestedValue -Object $parsed -Path 'status' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$codeValue)) { $result.Code = [string]$codeValue }
            if (-not [string]::IsNullOrWhiteSpace([string]$statusValue)) { $result.Status = [string]$statusValue }
        }
    } elseif ([string]::IsNullOrWhiteSpace($result.Error)) {
        $result.Error = 'CDP 驱动未生成结果文件: ' + $ResultPath
    }
    Write-ZhLog 'INFO' ('CDP 驱动退出码 {0}，状态 {1}，代码 {2}' -f $result.ExitCode, $result.Status, $result.Code)
    return $result
}

function Start-ZhRuntimeSession {
    param(
        $Install,
        [int]$MaxAttempts = 2,
        [int]$RendererReadySec = 25
    )
    $result = [pscustomobject]@{
        Ok             = $false
        Status         = 'failed'
        ExitCode       = 2
        Code           = 'LAUNCH_FAILED'
        Message        = ''
        Attempts       = 0
        Ports          = $null
        Node           = $null
        Cdp            = $null
        CdpResult      = $null
        CdpResultFile  = ''
        Activation     = $null
        InspectorReady = $false
        LogFile        = ''
    }
    $node = Get-ZhNodeInfo
    $result.Node = $node
    if (-not $node.Ok) {
        $result.Code = 'NODE_UNAVAILABLE'
        $result.Message = $node.Message
        Write-ZhLog 'WARN' $node.Message
        return $result
    }
    $lastMessage = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result.Attempts = $attempt
        Write-ZhStep ('启动 Codex 中文会话（第 {0}/{1} 次尝试）' -f $attempt, $MaxAttempts)
        $preScan = Get-ZhCodexProcessScan -Install $Install
        if ($preScan.TotalPotential -gt 0) {
            Write-ZhInfo ('启动前检测到 {0} 个 Codex 进程，先安全关闭...' -f $preScan.TotalPotential)
            $closeReport = Close-ZhCodexSafely -Install $Install
            if (-not $closeReport.Success) {
                $result.Code = 'SHUTDOWN_FAILED'
                $result.Message = $closeReport.Message
                return $result
            }
            Start-Sleep -Milliseconds 1200
        }
        $ports = New-ZhPortPair
        $argumentLine = '--remote-debugging-address=127.0.0.1 --remote-debugging-port={0} --inspect=127.0.0.1:{1} --lang={2}' -f $ports.Renderer, $ports.Inspector, $script:CodexZhDefaultLocale
        Write-ZhInfo ('调试参数: ' + $argumentLine)
        Write-ZhLog 'INFO' ('激活参数: ' + $argumentLine)
        $activation = Start-ZhCodexWithArguments -Install $Install -Arguments $argumentLine
        $result.Activation = $activation
        if (-not $activation.Ok) {
            $lastMessage = $activation.Message
            Write-ZhLog 'WARN' ('启动失败: ' + $lastMessage)
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds 1500; continue }
            $result.Code = 'ACTIVATION_FAILED'
            $result.Message = $lastMessage
            return $result
        }
        Write-ZhOk ('Codex 已启动（{0}，PID {1}）' -f $activation.Method, $activation.ProcessId)
        $result.Ports = $ports
        Start-Sleep -Milliseconds 500
        Write-ZhInfo ('等待 renderer 调试端口 {0}（最多 {1} 秒）...' -f $ports.Renderer, $RendererReadySec)
        $rendererReady = Wait-ZhRendererPort -Port $ports.Renderer -TimeoutSec $RendererReadySec
        if (-not $rendererReady) {
            $scanAfter = Get-ZhCodexProcessScan -Install $Install
            if ($scanAfter.TotalPotential -eq 0) {
                $lastMessage = '启动后未检测到 Codex 进程（可能被系统或安全软件终止）。'
            } else {
                $lastMessage = ('renderer 调试端口 {0} 在 {1} 秒内未就绪。' -f $ports.Renderer, $RendererReadySec)
            }
            Write-ZhLog 'WARN' $lastMessage
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds 1000 }
            continue
        }
        Write-ZhOk ('renderer 调试端口已就绪: ' + $ports.Renderer)
        # 注入前先尝试显示并置前主窗口（部分版本注入后窗口可能在后台/隐藏）
        [void](Show-ZhCodexWindows -Install $Install)
        $inspectorReady = Wait-ZhInspectorPort -Port $ports.Inspector -TimeoutSec 4
        $result.InspectorReady = $inspectorReady
        if ($inspectorReady) {
            Write-ZhOk ('主进程 inspector 端口已就绪: ' + $ports.Inspector + '（可选增强：原生菜单脚本）')
        } else {
            Write-ZhInfo ('主进程 inspector 端口 {0} 未开放：属正常现象，官方 i18n 已覆盖原生菜单，无需注入。' -f $ports.Inspector)
        }
        $cdpLogFile = Join-Path (Get-ZhLogDir) ('cdp-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $cdpResultFile = Join-Path (Get-ZhResultDir) ('cdp-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Write-ZhInfo '正在注入中文语言包并验证...'
        $cdp = Invoke-ZhCdpDriver -ResultPath $cdpResultFile -RendererPort $ports.Renderer -InspectorPort $ports.Inspector -Mode 'inject' -LogPath $cdpLogFile
        $result.Cdp = $cdp
        $result.CdpResult = $cdp.Result
        $result.CdpResultFile = $cdpResultFile
        $result.LogFile = $cdpLogFile
        $result.ExitCode = $cdp.ExitCode
        $result.Status = $cdp.Status
        $result.Code = $cdp.Code
        if ($cdp.ExitCode -eq 0 -or $cdp.ExitCode -eq 1) {
            $result.Ok = $true
            [void](Show-ZhCodexWindows -Install $Install)
            return $result
        }
        $lastMessage = $cdp.Error
        if ([string]::IsNullOrWhiteSpace($lastMessage)) {
            $lastMessage = ('CDP 注入失败（代码 {0}）。' -f $cdp.Code)
        }
        Write-ZhLog 'WARN' $lastMessage
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds 1200 }
    }
    $result.Ok = $false
    $result.Message = $lastMessage
    if ($result.Code -eq 'CDP_FAILED' -or $result.Code -eq 'LAUNCH_FAILED') {
        $result.Code = 'CDP_NOT_READY'
    }
    [void](Show-ZhCodexWindows -Install $Install)
    return $result
}

# ===========================================================================
# 结果展示
# ===========================================================================
function ConvertTo-ZhExitCode {
    param([string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return 2 }
    switch ($Status.Trim().ToLowerInvariant()) {
        'complete' { return 0 }
        'partial' { return 1 }
        'failed' { return 2 }
        default { return 2 }
    }
}

function Show-ZhResultSummary {
    param($Result)
    if ($null -eq $Result) { return }
    $status = [string](Get-ZhNestedValue -Object $Result -Path 'status' -Default 'unknown')
    $message = [string](Get-ZhNestedValue -Object $Result -Path 'message' -Default '')
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    switch ($status) {
        'complete' { Write-Host '  结果：完整汉化成功' -ForegroundColor Green }
        'partial'  { Write-Host '  结果：部分完成（中文界面已生效，部分项未完成）' -ForegroundColor Yellow }
        default    { Write-Host '  结果：失败' -ForegroundColor Red }
    }
    if (-not [string]::IsNullOrWhiteSpace($message)) { Write-Host ('  ' + $message) -ForegroundColor Gray }
    $rendererStatus = [string](Get-ZhNestedValue -Object $Result -Path 'renderer.verify.status' -Default '')
    $navigatorLanguage = [string](Get-ZhNestedValue -Object $Result -Path 'renderer.verify.navigatorLanguage' -Default '')
    $documentLanguage = [string](Get-ZhNestedValue -Object $Result -Path 'renderer.verify.documentLanguage' -Default '')
    $zhMatches = Get-ZhNestedValue -Object $Result -Path 'renderer.verify.zhMatches' -Default 0
    $chineseChars = Get-ZhNestedValue -Object $Result -Path 'renderer.verify.chineseChars' -Default 0
    if (-not [string]::IsNullOrWhiteSpace($rendererStatus)) {
        Write-Host ('  界面汉化: {0}（语言={1}/{2}，中文标记={3}，中文字符={4}）' -f $rendererStatus, $navigatorLanguage, $documentLanguage, $zhMatches, $chineseChars) -ForegroundColor Gray
    }
    $menuStatus = [string](Get-ZhNestedValue -Object $Result -Path 'menu.status' -Default '')
    $menuReason = [string](Get-ZhNestedValue -Object $Result -Path 'menu.reason' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($menuStatus)) {
        $menuText = $menuStatus
        if ($menuStatus -eq 'not-needed') {
            $menuText = '官方 i18n 已覆盖，无需注入（not-needed）'
        } elseif ($menuStatus -eq 'unavailable' -or $menuStatus -eq 'skipped') {
            $menuText = '未注入（可选增强，官方 i18n 已覆盖）'
        } elseif ($menuStatus -eq 'ok' -or $menuStatus -eq 'partial') {
            $menuText = $menuStatus + '（可选增强）'
        }
        $detail = $menuText
        if (-not [string]::IsNullOrWhiteSpace($menuReason)) { $detail = $detail + '；' + $menuReason }
        Write-Host ('  原生菜单: ' + $detail) -ForegroundColor Gray
    }
    $logFile = [string](Get-ZhNestedValue -Object $Result -Path 'logs.logFile' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($logFile)) { Write-Host ('  日志: ' + $logFile) -ForegroundColor DarkGray }
    $resultFile = [string](Get-ZhNestedValue -Object $Result -Path 'logs.resultFile' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($resultFile)) { Write-Host ('  结果: ' + $resultFile) -ForegroundColor DarkGray }
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
}

function Wait-ZhUserPause {
    param([switch]$NoPause)
    if ($NoPause) { return }
    Write-Host ''
    try { [void](Read-Host '按 Enter 键退出') } catch { }
}

function Read-ZhConfirmation {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [switch]$DefaultYes
    )
    $suffix = ' [Y/n] '
    if (-not $DefaultYes) { $suffix = ' [y/N] ' }
    Write-Host ''
    Write-Host ($Prompt + $suffix) -ForegroundColor Yellow
    $answer = ''
    try { $answer = [string](Read-Host '请输入') } catch { $answer = '' }
    $answer = $answer.Trim().ToLowerInvariant()
    if ($answer -eq '') { return [bool]$DefaultYes }
    if ($answer -eq 'y' -or $answer -eq 'yes') { return $true }
    if ($answer -eq 'n' -or $answer -eq 'no') { return $false }
    return [bool]$DefaultYes
}

function Write-ZhUserPause {
    param([switch]$NoPause)
    if ($NoPause) { return }
    try {
        if ([Console]::IsInputRedirected) { return }
        if ($Host.Name -ne 'ConsoleHost') { return }
        Write-Host ''
        Write-Host '按回车键退出...' -ForegroundColor DarkGray
        [void][Console]::ReadLine()
    } catch { }
}
