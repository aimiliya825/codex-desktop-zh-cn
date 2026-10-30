#requires -version 5.1
<#
  SelfTest.ps1 - codex-desktop-zh 离线自测（不启动 / 不关闭 / 不注入 Codex）

  覆盖内容：
    - 仓库文件结构完整性（脚本 / 资产 / 文档 / 批处理）
    - PowerShell 5.1 兼容性：UTF-8 BOM、语法解析、禁用 7.x 特性
    - 资产 JSON / JS 语法（JSON 用 ConvertFrom-Json，JS 用 node --check）
    - config.toml 写入 / 还原逻辑（基于 tests/fixtures 临时副本，不碰真实配置）
    - 版本判定、路径归属、JSON 落盘（UTF-8 无 BOM）、端口、结果契约
    - Codex 检测逻辑（只读：读注册表/清单，不启动进程）
    - 敏感信息 / 危险写入 / 外部网络调用扫描
    - 批处理包装、README / LICENSE / THIRD_PARTY_NOTICES 检查

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\SelfTest.ps1
  退出码：0=全部通过；1=存在 FAIL。

  Licensed under the MIT License.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:Failures = @()
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-zh-selftest-' + [guid]::NewGuid().ToString('N'))

function Write-TestSection {
    param([string]$Title)
    Write-Host ''
    Write-Host ('【' + $Title + '】') -ForegroundColor Yellow
}

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:PassCount += 1
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } else {
        $script:FailCount += 1
        $script:Failures += $Name
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '（' + $Detail + '）' } else { '' })) -ForegroundColor Red
    }
}

function Assert-False {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    Assert-True -Name $Name -Condition (-not $Condition) -Detail $Detail
}

function Assert-Equal {
    param(
        [string]$Name,
        $Expected,
        $Actual
    )
    $isEqual = $false
    try { $isEqual = ($Expected -eq $Actual) } catch { $isEqual = $false }
    $detail = ''
    if (-not $isEqual) { $detail = ('期望: {0}，实际: {1}' -f $Expected, $Actual) }
    Assert-True -Name $Name -Condition $isEqual -Detail $detail
}

function Assert-Match {
    param(
        [string]$Name,
        [string]$Text,
        [string]$Pattern
    )
    $matched = $false
    try { $matched = ($Text -match $Pattern) } catch { $matched = $false }
    Assert-True -Name $Name -Condition $matched -Detail ('未匹配: ' + $Pattern)
}

function Assert-NotMatch {
    param(
        [string]$Name,
        [string]$Text,
        [string]$Pattern
    )
    $matched = $false
    try { $matched = ($Text -match $Pattern) } catch { $matched = $false }
    Assert-True -Name $Name -Condition (-not $matched) -Detail ('不应匹配: ' + $Pattern)
}

function Skip-Test {
    param([string]$Name, [string]$Reason = '')
    $script:SkipCount += 1
    Write-Host ('  [SKIP] ' + $Name + $(if ($Reason) { '（' + $Reason + '）' } else { '' })) -ForegroundColor DarkGray
}

function Get-RepoFile {
    param([string]$RelativePath)
    return (Join-Path $script:RepoRoot ($RelativePath -replace '/', '\'))
}

function Get-RepoText {
    param([string]$RelativePath)
    $path = Get-RepoFile -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
}

function Test-Utf8Bom {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 3) { return $false }
        return ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    } catch {
        return $false
    }
}

function Test-Utf8NoBom {
    param([string]$Path)
    return (-not (Test-Utf8Bom -Path $Path))
}

function Get-RelativeRepoPath {
    param([string]$FullPath)
    if ($FullPath.StartsWith($script:RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($script:RepoRoot.Length).TrimStart('\')
    }
    return $FullPath
}

# ===========================================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  codex-desktop-zh 离线自测（不会启动/关闭 Codex）' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ('  仓库根目录: ' + $script:RepoRoot)
Write-Host ('  PowerShell: ' + $PSVersionTable.PSVersion.ToString())

New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

try {
    # -----------------------------------------------------------------------
    Write-TestSection '文件结构'
    $requiredFiles = @(
        'Install-CodexZh.ps1',
        'Launch-CodexZh.ps1',
        'Restore-CodexZh.ps1',
        'Diagnostics.ps1',
        'lib/Common.ps1',
        'lib/cdp.mjs',
        'assets/i18n-bootstrap.js',
        'assets/locale-script.js',
        'assets/menu-script.js',
        'assets/menu-translations.json',
        'tests/SelfTest.ps1',
        '一键汉化.bat',
        '启动汉化版.bat',
        '还原原版.bat',
        '诊断.bat',
        'README.md',
        'README.en.md',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'CHANGELOG.md',
        '.gitignore',
        'docs/diagnostics.md'
    )
    foreach ($requiredFile in $requiredFiles) {
        $fullPath = Get-RepoFile -RelativePath $requiredFile
        Assert-True -Name ('文件存在: ' + $requiredFile) -Condition (Test-Path -LiteralPath $fullPath)
    }
    $fixtureFiles = @(
        'tests/fixtures/config-empty.toml',
        'tests/fixtures/config-desktop.toml',
        'tests/fixtures/config-locale-enus.toml',
        'tests/fixtures/config-other.toml',
        'tests/fixtures/config-dual-sections.toml',
        'tests/fixtures/cdp-result-complete.json',
        'tests/fixtures/cdp-result-partial.json',
        'tests/fixtures/cdp-result-failed.json'
    )
    foreach ($fixtureFile in $fixtureFiles) {
        Assert-True -Name ('夹具存在: ' + $fixtureFile) -Condition (Test-Path -LiteralPath (Get-RepoFile -RelativePath $fixtureFile))
    }

    # -----------------------------------------------------------------------
    Write-TestSection 'PowerShell 编码与语法（PS 5.1 兼容）'
    $ps1Files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    Assert-True -Name '找到 PowerShell 脚本' -Condition ($ps1Files.Count -ge 5) -Detail ('count=' + $ps1Files.Count)
    foreach ($ps1File in $ps1Files) {
        $relative = Get-RelativeRepoPath -FullPath $ps1File.FullName
        Assert-True -Name ('UTF-8 BOM: ' + $relative) -Condition (Test-Utf8Bom -Path $ps1File.FullName)
        $parseErrors = $null
        $tokens = $null
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile($ps1File.FullName, [ref]$tokens, [ref]$parseErrors)
        } catch {
            $parseErrors = @($_.Exception.Message)
        }
        $parseOk = ($null -eq $parseErrors -or @($parseErrors).Count -eq 0)
        $parseDetail = ''
        if (-not $parseOk) {
            $parseDetail = (@($parseErrors) | ForEach-Object { $_.Message }) -join '; '
        }
        Assert-True -Name ('语法解析: ' + $relative) -Condition $parseOk -Detail $parseDetail
        $text = [System.IO.File]::ReadAllText($ps1File.FullName)
        Assert-Match -Name ('#requires 5.1: ' + $relative) -Text $text -Pattern '(?i)^#requires\s+-version\s+5\.1'
    }
    # 禁止的 PowerShell 7 专有语法（测试脚本自身除外）
    $ps7Patterns = @(
        @{ Name = '空合并运算符 ??'; Pattern = '\?\?' },
        @{ Name = '-AsHashtable'; Pattern = '-AsHashtable' },
        @{ Name = 'ForEach-Object -Parallel'; Pattern = 'ForEach-Object\s+-Parallel' },
        @{ Name = 'utf8NoBOM'; Pattern = 'utf8NoBOM' },
        @{ Name = 'pwsh 7 调用'; Pattern = '\bpwsh(\.exe)?\b' }
    )
    foreach ($ps1File in $ps1Files) {
        $relative = Get-RelativeRepoPath -FullPath $ps1File.FullName
        if ($relative -ieq 'tests\SelfTest.ps1' -or $relative -ieq 'tests/SelfTest.ps1') { continue }
        $text = [System.IO.File]::ReadAllText($ps1File.FullName)
        foreach ($ps7Pattern in $ps7Patterns) {
            Assert-NotMatch -Name ('无 PS7 特性(' + $ps7Pattern.Name + '): ' + $relative) -Text $text -Pattern $ps7Pattern.Pattern
        }
    }

    # -----------------------------------------------------------------------
    Write-TestSection 'JSON / JS 资产'
    $translationsPath = Get-RepoFile -RelativePath 'assets/menu-translations.json'
    $translationsRaw = [System.IO.File]::ReadAllText($translationsPath)
    $translations = $null
    try { $translations = $translationsRaw | ConvertFrom-Json } catch { $translations = $null }
    Assert-True -Name 'menu-translations.json 可解析' -Condition ($null -ne $translations)
    $translationGroups = @('common', 'windows', 'macos')
    foreach ($group in $translationGroups) {
        $groupValue = $null
        if ($null -ne $translations) { $groupValue = $translations.PSObject.Properties[$group].Value }
        Assert-True -Name ('翻译分组存在: ' + $group) -Condition ($null -ne $groupValue)
    }
    $commonCount = 0
    if ($null -ne $translations) {
        $commonValue = $translations.PSObject.Properties['common'].Value
        if ($null -ne $commonValue) { $commonCount = @($commonValue.PSObject.Properties).Count }
    }
    Assert-True -Name 'common 词条数量 >= 100' -Condition ($commonCount -ge 100) -Detail ('count=' + $commonCount)
    $requiredTranslations = @{
        'Toggle Sidebar' = '切换侧边栏'
        'Start Performance Trace' = '开始性能跟踪'
        'Force Reload' = '强制重新加载'
        'Toggle Developer Tools' = '切换开发者工具'
        'Minimize' = '最小化'
        'Toggle Full Screen' = '切换全屏'
    }
    foreach ($key in $requiredTranslations.Keys) {
        $actual = ''
        if ($null -ne $translations) {
            $prop = $translations.common.PSObject.Properties[$key]
            if ($null -ne $prop) { $actual = [string]$prop.Value }
        }
        Assert-Equal -Name ('翻译词条: ' + $key) -Expected $requiredTranslations[$key] -Actual $actual
    }
    # 每个分组内部不应有重复 key（避免半角/全角近似词条覆盖）
    foreach ($group in $translationGroups) {
        $groupPattern = '"' + $group + '"\s*:\s*\{(?<body>[\s\S]*?)\r?\n  \}'
        $groupMatch = [regex]::Match($translationsRaw, $groupPattern)
        if (-not $groupMatch.Success) {
            Assert-True -Name ('分组可定位: ' + $group) -Condition $false
            continue
        }
        $keyNames = @([regex]::Matches($groupMatch.Groups['body'].Value, '"([^"]+)"\s*:') | ForEach-Object { $_.Groups[1].Value })
        $duplicateKeys = @($keyNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Assert-True -Name ('无重复 key: ' + $group) -Condition ($duplicateKeys.Count -eq 0) -Detail ($duplicateKeys -join ', ')
    }
    Assert-True -Name 'menu-translations.json 为 UTF-8 无 BOM' -Condition (Test-Utf8NoBom -Path $translationsPath)
    foreach ($jsonAsset in @('tests/fixtures/cdp-result-complete.json', 'tests/fixtures/cdp-result-partial.json', 'tests/fixtures/cdp-result-failed.json')) {
        $jsonRaw = Get-RepoText -RelativePath $jsonAsset
        $parsed = $null
        try { $parsed = $jsonRaw | ConvertFrom-Json } catch { $parsed = $null }
        Assert-True -Name ('JSON 可解析: ' + $jsonAsset) -Condition ($null -ne $parsed)
    }

    # -----------------------------------------------------------------------
    Write-TestSection 'Node.js 语法检查'
    $nodeCommand = $null
    try { $nodeCommand = Get-Command -Name 'node.exe' -ErrorAction SilentlyContinue } catch { $nodeCommand = $null }
    if ($null -eq $nodeCommand) {
        try { $nodeCommand = Get-Command -Name 'node' -ErrorAction SilentlyContinue } catch { $nodeCommand = $null }
    }
    if ($null -eq $nodeCommand) {
        Skip-Test -Name 'node --check JS 语法' -Reason '未安装 Node.js'
    } else {
        $nodePath = [string]$nodeCommand.Source
        $nodeVersionText = ''
        try {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $nodeVersionText = [string](& $nodePath -p 'process.versions.node' 2>$null | Select-Object -First 1)
            $ErrorActionPreference = $oldPreference
        } catch {
            $nodeVersionText = ''
        }
        $nodeVersionText = $nodeVersionText.Trim()
        $nodeMajor = 0
        try { $nodeMajor = [int](($nodeVersionText -split '\.')[0]) } catch { $nodeMajor = 0 }
        Assert-True -Name ('Node.js 版本 >= 22（{0}）' -f $nodeVersionText) -Condition ($nodeMajor -ge 22)
        foreach ($jsFile in @('lib/cdp.mjs', 'assets/i18n-bootstrap.js', 'assets/menu-script.js', 'assets/locale-script.js')) {
            $fullPath = Get-RepoFile -RelativePath $jsFile
            $checkOutput = ''
            $checkExit = -1
            $oldPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $checkOutput = [string](& $nodePath '--check' $fullPath 2>&1 | Out-String)
                $checkExit = [int]$LASTEXITCODE
            } catch {
                $checkExit = -1
                $checkOutput = $_.Exception.Message
            } finally {
                $ErrorActionPreference = $oldPreference
            }
            Assert-True -Name ('node --check: ' + $jsFile) -Condition ($checkExit -eq 0) -Detail ($checkOutput.Trim())
        }
    }

    # -----------------------------------------------------------------------
    Write-TestSection '注入脚本资产内容'
    $bootstrapText = Get-RepoText -RelativePath 'assets/i18n-bootstrap.js'
    Assert-Match -Name 'i18n-bootstrap 含 Statsig 配置 id 72216192' -Text $bootstrapText -Pattern '72216192'
    Assert-Match -Name 'i18n-bootstrap 强制 enable_i18n' -Text $bootstrapText -Pattern 'enable_i18n'
    Assert-Match -Name 'i18n-bootstrap 强制 locale_source' -Text $bootstrapText -Pattern 'locale_source'
    Assert-Match -Name 'i18n-bootstrap 包装 getDynamicConfig' -Text $bootstrapText -Pattern 'getDynamicConfig'
    Assert-Match -Name 'i18n-bootstrap 包装 getLayer' -Text $bootstrapText -Pattern 'getLayer'
    Assert-Match -Name 'i18n-bootstrap 覆盖 navigator 语言' -Text $bootstrapText -Pattern 'Navigator'
    Assert-Match -Name 'i18n-bootstrap 暴露 __codexZhI18nState' -Text $bootstrapText -Pattern '__codexZhI18nState'
    Assert-NotMatch -Name 'i18n-bootstrap 不触碰 app.asar' -Text $bootstrapText -Pattern 'app\.asar'
    Assert-NotMatch -Name 'i18n-bootstrap 不读取敏感文件' -Text $bootstrapText -Pattern 'auth\.json|token'

    $menuScriptText = Get-RepoText -RelativePath 'assets/menu-script.js'
    Assert-Match -Name 'menu-script hook Menu.setApplicationMenu' -Text $menuScriptText -Pattern 'Menu\.setApplicationMenu'
    Assert-Match -Name 'menu-script 含翻译占位符' -Text $menuScriptText -Pattern '__TRANSLATIONS_JSON__'
    Assert-Match -Name 'menu-script 含平台占位符' -Text $menuScriptText -Pattern '__PLATFORM_JSON__'
    Assert-Match -Name 'menu-script 支持 Go to Chat 动态翻译' -Text $menuScriptText -Pattern 'Go to Chat'
    Assert-Match -Name 'menu-script 返回 application-menu-empty' -Text $menuScriptText -Pattern 'application-menu-empty'
    Assert-Match -Name 'menu-script 暴露翻译函数' -Text $menuScriptText -Pattern '__codexZhLauncherTranslateMenu'
    Assert-NotMatch -Name 'menu-script 不触碰 app.asar' -Text $menuScriptText -Pattern 'app\.asar'

    $localeScriptText = Get-RepoText -RelativePath 'assets/locale-script.js'
    Assert-Match -Name 'locale-script 触发 location.reload' -Text $localeScriptText -Pattern 'location\.reload'
    Assert-Match -Name 'locale-script 读取 i18n 状态' -Text $localeScriptText -Pattern '__codexZhI18nState'
    Assert-NotMatch -Name 'locale-script 不再使用已移除的 vscode bridge' -Text $localeScriptText -Pattern 'vscode://codex/set-setting'
    Assert-NotMatch -Name 'locale-script 不访问 electronBridge' -Text $localeScriptText -Pattern 'electronBridge'

    $cdpText = Get-RepoText -RelativePath 'lib/cdp.mjs'
    Assert-Match -Name 'cdp.mjs 使用 Page.addScriptToEvaluateOnNewDocument' -Text $cdpText -Pattern 'Page\.addScriptToEvaluateOnNewDocument'
    Assert-Match -Name 'cdp.mjs 使用 Runtime.evaluate' -Text $cdpText -Pattern 'Runtime\.evaluate'
    Assert-Match -Name 'cdp.mjs 轮询 /json/list' -Text $cdpText -Pattern '/json/list'
    Assert-Match -Name 'cdp.mjs 刷新页面' -Text $cdpText -Pattern 'location\.reload'
    Assert-Match -Name 'cdp.mjs 输出 --result 文件' -Text $cdpText -Pattern '--result'
    Assert-Match -Name 'cdp.mjs 菜单不可用时标记 not-needed（官方 i18n 覆盖）' -Text $cdpText -Pattern "status: 'not-needed'"
    Assert-Match -Name 'cdp.mjs 标注 official-i18n' -Text $cdpText -Pattern 'official-i18n'
    Assert-Match -Name 'cdp.mjs 多 target 注入（targetsInjected）' -Text $cdpText -Pattern 'targetsInjected'
    Assert-Match -Name 'cdp.mjs 刷新后重新枚举并逐个验证' -Text $cdpText -Pattern 'verifyAllTargets'
    Assert-Match -Name 'cdp.mjs 错误分类 CDP_TARGET_TIMEOUT' -Text $cdpText -Pattern 'CDP_TARGET_TIMEOUT'
    $imports = @([regex]::Matches($cdpText, "(?m)^\s*import\s+.+from\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    $nonBuiltinImports = @($imports | Where-Object { $_ -notmatch '^node:' })
    Assert-True -Name 'cdp.mjs 仅使用 Node 内置模块（零 npm 依赖）' -Condition ($nonBuiltinImports.Count -eq 0) -Detail ($nonBuiltinImports -join ',')

    # -----------------------------------------------------------------------
    Write-TestSection '共享函数库单元测试（不触碰真实 config）'
    $commonPath = Get-RepoFile -RelativePath 'lib/Common.ps1'
    . $commonPath

    # 版本判定
    Assert-Equal -Name 'ConvertTo-ZhVersion 解析 4 段版本' -Expected ([version]'26.1023.6621.0') -Actual (ConvertTo-ZhVersion -Version '26.1023.6621.0')
    Assert-Equal -Name 'ConvertTo-ZhVersion 解析 v 前缀' -Expected ([version]'24.14.1') -Actual (ConvertTo-ZhVersion -Version 'v24.14.1')
    Assert-True -Name 'ConvertTo-ZhVersion 非法输入返回 null' -Condition ($null -eq (ConvertTo-ZhVersion -Version 'abc'))
    Assert-True -Name '26.1023.6621.0 属于受保护版本线' -Condition (Test-ZhProtectedVersion -Version '26.1023.6621.0')
    Assert-True -Name '26.900.0.0 属于受保护版本线' -Condition (Test-ZhProtectedVersion -Version '26.900.0.0')
    Assert-False -Name '26.899.9999.0 不属于受保护版本线' -Condition (Test-ZhProtectedVersion -Version '26.899.9999.0')
    Assert-True -Name '27.0.0.0 属于受保护版本线' -Condition (Test-ZhProtectedVersion -Version '27.0.0.0')
    Assert-False -Name '空版本号不属于受保护版本线' -Condition (Test-ZhProtectedVersion -Version '')

    # 退出码契约
    Assert-Equal -Name '退出码: complete=0' -Expected 0 -Actual (ConvertTo-ZhExitCode -Status 'complete')
    Assert-Equal -Name '退出码: partial=1' -Expected 1 -Actual (ConvertTo-ZhExitCode -Status 'partial')
    Assert-Equal -Name '退出码: failed=2' -Expected 2 -Actual (ConvertTo-ZhExitCode -Status 'failed')
    Assert-Equal -Name '退出码: 未知状态=2' -Expected 2 -Actual (ConvertTo-ZhExitCode -Status 'whatever')

    # 嵌套取值：同时支持有序字典 / 哈希表 / PSCustomObject（结果汇总面板依赖）
    $nestedDict = [ordered]@{ a = 'x'; nested = [ordered]@{ b = 2 } }
    Assert-Equal -Name 'Get-ZhNestedValue 支持 OrderedDictionary' -Expected 'x' -Actual (Get-ZhNestedValue -Object $nestedDict -Path 'a')
    Assert-Equal -Name 'Get-ZhNestedValue 支持嵌套字典' -Expected 2 -Actual (Get-ZhNestedValue -Object $nestedDict -Path 'nested.b')
    $nestedPso = [pscustomobject]@{ a = 'y'; nested = [pscustomobject]@{ b = 3 } }
    Assert-Equal -Name 'Get-ZhNestedValue 支持 PSCustomObject' -Expected 3 -Actual (Get-ZhNestedValue -Object $nestedPso -Path 'nested.b')
    Assert-Equal -Name 'Get-ZhNestedValue 缺失路径返回默认值' -Expected 'dft' -Actual (Get-ZhNestedValue -Object $nestedDict -Path 'nope.deep' -Default 'dft')

    # config 写入 / 还原（临时夹具）
    $configWork = Join-Path $script:TempRoot 'config'
    New-Item -ItemType Directory -Path $configWork -Force | Out-Null
    $fixturesRoot = Join-Path $PSScriptRoot 'fixtures'

    # 1) 空文件 → 创建 [desktop] 段
    $caseEmpty = Join-Path $configWork 'empty.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-empty.toml') -Destination $caseEmpty -Force
    $setEmpty = Set-ZhLocaleOverride -ConfigPath $caseEmpty -Locale 'zh-CN'
    Assert-True -Name '空 config.toml 写入成功并复验' -Condition ([bool]$setEmpty.Verified) -Detail $setEmpty.Error
    Assert-True -Name '空 config.toml 写入时无需备份' -Condition (-not (Test-Path -LiteralPath $setEmpty.BackupPath))
    $emptyContent = [System.IO.File]::ReadAllText($caseEmpty)
    Assert-Match -Name '空 config.toml 生成 [desktop] 段' -Text $emptyContent -Pattern '\[desktop\]'
    Assert-Match -Name '空 config.toml 生成 localeOverride' -Text $emptyContent -Pattern 'localeOverride = "zh-CN"'
    $restoreEmpty = Restore-ZhConfigFile -ConfigPath $caseEmpty
    Assert-True -Name '空 config.toml 还原成功' -Condition ([bool]$restoreEmpty.Restored)
    Assert-Equal -Name '空 config.toml 还原方式为精确删除行' -Expected 'line-removal' -Actual $restoreEmpty.Method
    $emptyAfter = [System.IO.File]::ReadAllText($caseEmpty)
    Assert-True -Name '空 config.toml 还原后无 localeOverride' -Condition ($emptyAfter.Trim().Length -eq 0)

    # 2) 已有 [desktop] 段但无 localeOverride → 段内插入；备份/还原
    $caseDesktop = Join-Path $configWork 'desktop.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-desktop.toml') -Destination $caseDesktop -Force
    $originalDesktop = [System.IO.File]::ReadAllText($caseDesktop)
    $setDesktop = Set-ZhLocaleOverride -ConfigPath $caseDesktop -Locale 'zh-CN'
    Assert-True -Name '已有 [desktop] 段写入成功' -Condition ([bool]$setDesktop.Verified)
    Assert-True -Name '已有配置生成 .bak-zhcn 备份' -Condition (Test-Path -LiteralPath $setDesktop.BackupPath)
    $backupContent = [System.IO.File]::ReadAllText($setDesktop.BackupPath)
    Assert-Equal -Name '备份内容与原始配置一致' -Expected $originalDesktop -Actual $backupContent
    $desktopContent = [System.IO.File]::ReadAllText($caseDesktop)
    Assert-Match -Name '[desktop] 段内已写入 localeOverride' -Text $desktopContent -Pattern '(?s)\[desktop\][^\[]*localeOverride = "zh-CN"'
    $restoreDesktop = Restore-ZhConfigFile -ConfigPath $caseDesktop
    Assert-Equal -Name '从备份还原方式正确' -Expected 'backup' -Actual $restoreDesktop.Method
    Assert-True -Name '从备份还原成功' -Condition ([bool]$restoreDesktop.Verified)
    Assert-Equal -Name '还原后内容与原始配置一致' -Expected $originalDesktop -Actual ([System.IO.File]::ReadAllText($caseDesktop))
    Assert-False -Name '还原后备份文件已清理' -Condition (Test-Path -LiteralPath $setDesktop.BackupPath)

    # 3) 已有 localeOverride = "en-US" → 替换；还原恢复原值
    $caseEnUs = Join-Path $configWork 'enus.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-locale-enus.toml') -Destination $caseEnUs -Force
    $originalEnUs = [System.IO.File]::ReadAllText($caseEnUs)
    $setEnUs = Set-ZhLocaleOverride -ConfigPath $caseEnUs -Locale 'zh-CN'
    Assert-Equal -Name '记录原 localeOverride 值' -Expected 'en-US' -Actual $setEnUs.PreviousValue
    Assert-True -Name '替换 en-US 为 zh-CN 成功' -Condition ([bool]$setEnUs.Verified)
    $restoreEnUs = Restore-ZhConfigFile -ConfigPath $caseEnUs
    Assert-True -Name 'en-US 配置可完整还原' -Condition ([bool]$restoreEnUs.Verified)
    Assert-Equal -Name 'en-US 还原后内容与原始一致' -Expected $originalEnUs -Actual ([System.IO.File]::ReadAllText($caseEnUs))

    # 4) 无 [desktop] 段的普通配置 → 追加；保留原有内容
    $caseOther = Join-Path $configWork 'other.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-other.toml') -Destination $caseOther -Force
    $originalOther = [System.IO.File]::ReadAllText($caseOther)
    $setOther = Set-ZhLocaleOverride -ConfigPath $caseOther -Locale 'zh-CN'
    Assert-True -Name '无 [desktop] 段时追加写入成功' -Condition ([bool]$setOther.Verified)
    $otherContent = [System.IO.File]::ReadAllText($caseOther)
    Assert-Match -Name '追加后保留原有 [general] 段' -Text $otherContent -Pattern '\[general\]'
    Assert-Match -Name '追加后新增 [desktop] 段' -Text $otherContent -Pattern '\[desktop\]'
    $restoreOther = Restore-ZhConfigFile -ConfigPath $caseOther
    Assert-True -Name '无 [desktop] 段配置可还原' -Condition ([bool]$restoreOther.Verified)

    # 5) 区段感知：只删除 [desktop] 下的 localeOverride，保留 [general] 下的
    $caseDual = Join-Path $configWork 'dual.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-dual-sections.toml') -Destination $caseDual -Force
    $removeDual = Remove-ZhLocaleOverrideContent -Content ([System.IO.File]::ReadAllText($caseDual))
    Assert-Equal -Name '区段感知删除只移除 1 行' -Expected 1 -Actual $removeDual.Removed
    Assert-Match -Name '删除后保留 [general] 下的 localeOverride' -Text $removeDual.Content -Pattern '(?s)\[general\][^\[]*localeOverride = "en-US"'
    Assert-NotMatch -Name '删除后 [desktop] 下无 localeOverride' -Text $removeDual.Content -Pattern '(?s)\[desktop\][^\[]*localeOverride'

    # 6) 幂等性
    $caseIdem = Join-Path $configWork 'idem.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-desktop.toml') -Destination $caseIdem -Force
    $idemFirst = Set-ZhLocaleOverride -ConfigPath $caseIdem -Locale 'zh-CN'
    $idemSecond = Set-ZhLocaleOverride -ConfigPath $caseIdem -Locale 'zh-CN'
    Assert-True -Name '首次写入 modified=true' -Condition ([bool]$idemFirst.Modified)
    Assert-False -Name '第二次写入 modified=false（幂等）' -Condition ([bool]$idemSecond.Modified)
    Assert-True -Name '第二次写入 alreadyConfigured=true' -Condition ([bool]$idemSecond.AlreadyConfigured)
    $idemContent = [System.IO.File]::ReadAllText($caseIdem)
    $idemCount = ([regex]::Matches($idemContent, 'localeOverride')).Count
    Assert-Equal -Name '重复写入后仅有 1 处 localeOverride' -Expected 1 -Actual $idemCount

    # 7) 行尾风格保留（LF 不被改成 CRLF）
    $caseLf = Join-Path $configWork 'lf.toml'
    Copy-Item -LiteralPath (Join-Path $fixturesRoot 'config-locale-enus.toml') -Destination $caseLf -Force
    [void](Set-ZhLocaleOverride -ConfigPath $caseLf -Locale 'zh-CN')
    $lfContent = [System.IO.File]::ReadAllText($caseLf)
    Assert-NotMatch -Name 'LF 配置文件写入后不引入 CRLF' -Text $lfContent -Pattern "`r`n"

    # 8) 配置摘要只暴露段名与 localeOverride（脱敏检查）
    $summary = Get-ZhConfigSummary -ConfigPath $caseIdem
    Assert-True -Name 'config 摘要包含 desktop 段' -Condition ($summary.DesktopSection)
    Assert-True -Name 'config 摘要包含 localeOverride' -Condition ($summary.LocaleOverridePresent)
    Assert-Equal -Name 'config 摘要 localeOverride 值正确' -Expected 'zh-CN' -Actual $summary.LocaleOverrideValue
    $summarySerialized = ConvertTo-ZhJson -Object $summary -Depth 6
    Assert-NotMatch -Name 'config 摘要不泄露其他配置值' -Text $summarySerialized -Pattern 'gpt-5|theme'

    # 9) JSON 落盘：UTF-8 无 BOM + 中文往返
    $jsonTestPath = Join-Path $script:TempRoot 'json-test.json'
    Write-ZhJsonFile -Path $jsonTestPath -Object ([ordered]@{ name = '中文测试'; nested = @{ value = 42 }; list = @(1, 2, 3) }) | Out-Null
    Assert-True -Name 'JSON 文件为 UTF-8 无 BOM' -Condition (Test-Utf8NoBom -Path $jsonTestPath)
    $jsonRoundTrip = Read-ZhJsonFile -Path $jsonTestPath
    Assert-Equal -Name 'JSON 中文往返正确' -Expected '中文测试' -Actual ([string]$jsonRoundTrip.name)
    Assert-Equal -Name 'JSON 嵌套值往返正确' -Expected 42 -Actual ([int]$jsonRoundTrip.nested.value)

    # 10) 端口对
    $portPair = New-ZhPortPair
    Assert-True -Name '端口对非空且互不相同' -Condition ($portPair.Renderer -gt 0 -and $portPair.Inspector -gt 0 -and $portPair.Renderer -ne $portPair.Inspector) -Detail ('{0}/{1}' -f $portPair.Renderer, $portPair.Inspector)

    # 11) 嵌套取值
    $nestedFixture = Read-ZhJsonFile -Path (Get-RepoFile -RelativePath 'tests/fixtures/cdp-result-partial.json')
    Assert-Equal -Name 'Get-ZhNestedValue 读取嵌套字段' -Expected 'zh-CN' -Actual (Get-ZhNestedValue -Object $nestedFixture -Path 'renderer.verify.navigatorLanguage')
    Assert-Equal -Name 'Get-ZhNestedValue 读取菜单原因' -Expected 'inspector-port-not-open' -Actual (Get-ZhNestedValue -Object $nestedFixture -Path 'menu.reason')
    Assert-Equal -Name 'Get-ZhNestedValue 缺省值' -Expected 'fallback' -Actual (Get-ZhNestedValue -Object $nestedFixture -Path 'not.exist.path' -Default 'fallback')

    # 12) 进程路径归属（纯路径运算，不枚举真实进程）
    $fakeInstallRoot = Join-Path $script:TempRoot 'fake-install'
    $fakeAppDir = Join-Path $fakeInstallRoot 'app'
    New-Item -ItemType Directory -Path $fakeAppDir -Force | Out-Null
    [void](New-Item -ItemType File -Path (Join-Path $fakeAppDir 'ChatGPT.exe') -Force)
    $fakeStoreInstall = [pscustomobject]@{ Kind = 'Store'; InstallLocation = $fakeInstallRoot }
    $fakePortableInstall = [pscustomobject]@{ Kind = 'Portable'; InstallLocation = $fakeInstallRoot }
    Assert-True -Name '路径归属: 安装目录内 exe 属于当前安装' -Condition (Test-ZhPathOwnedByInstall -Install $fakeStoreInstall -Path (Join-Path $fakeAppDir 'ChatGPT.exe'))
    Assert-False -Name '路径归属: 安装目录外 exe 不属于当前安装' -Condition (Test-ZhPathOwnedByInstall -Install $fakeStoreInstall -Path (Join-Path $script:TempRoot 'other\ChatGPT.exe'))
    Assert-False -Name '路径归属: 非 Codex 可执行文件被拒绝' -Condition (Test-ZhPathOwnedByInstall -Install $fakeStoreInstall -Path (Join-Path $fakeAppDir 'notepad.exe'))
    Assert-True -Name '路径归属: 便携版根目录 exe 属于当前安装' -Condition (Test-ZhPathOwnedByInstall -Install $fakePortableInstall -Path (Join-Path $fakeInstallRoot 'ChatGPT.exe'))

    # 13) 结果对象契约
    $contractResult = New-ZhActionResult -Action 'install'
    Assert-True -Name '结果对象包含 status' -Condition ($contractResult.Contains('status'))
    Assert-True -Name '结果对象包含 exitCode' -Condition ($contractResult.Contains('exitCode'))
    Assert-True -Name '结果对象包含 code' -Condition ($contractResult.Contains('code'))
    Assert-True -Name '结果对象包含 renderer/menu/checks' -Condition ($contractResult.Contains('renderer') -and $contractResult.Contains('menu') -and $contractResult.Contains('checks'))
    $contractPath = Join-Path $script:TempRoot 'contract.json'
    Write-ZhJsonFile -Path $contractPath -Object $contractResult | Out-Null
    $contractBack = Read-ZhJsonFile -Path $contractPath
    Assert-Equal -Name '结果对象 JSON 往返 status' -Expected 'failed' -Actual ([string]$contractBack.status)

    # -----------------------------------------------------------------------
    Write-TestSection '结果契约（CDP 结果夹具 + 主脚本代码约定）'
    $resultFixtures = @(
        @{ File = 'tests/fixtures/cdp-result-complete.json'; Status = 'complete'; Code = 'OK'; ExitCode = 0 },
        @{ File = 'tests/fixtures/cdp-result-partial.json'; Status = 'partial'; Code = 'PARTIAL_RENDERER'; ExitCode = 1 },
        @{ File = 'tests/fixtures/cdp-result-failed.json'; Status = 'failed'; Code = 'CDP_NOT_READY'; ExitCode = 2 }
    )
    foreach ($fixture in $resultFixtures) {
        $fixtureData = Read-ZhJsonFile -Path (Get-RepoFile -RelativePath $fixture.File)
        Assert-Equal -Name ('夹具 status: ' + $fixture.File) -Expected $fixture.Status -Actual ([string]$fixtureData.status)
        Assert-Equal -Name ('夹具 code: ' + $fixture.File) -Expected $fixture.Code -Actual ([string]$fixtureData.code)
        Assert-Equal -Name ('夹具 exitCode: ' + $fixture.File) -Expected $fixture.ExitCode -Actual ([int]$fixtureData.exitCode)
        Assert-Equal -Name ('夹具 exitCode 与状态契约一致: ' + $fixture.File) -Expected ([int]$fixtureData.exitCode) -Actual (ConvertTo-ZhExitCode -Status ([string]$fixtureData.status))
    }
    $installText = Get-RepoText -RelativePath 'Install-CodexZh.ps1'
    Assert-Match -Name 'Install 脚本含 CODEX_NOT_FOUND 错误码' -Text $installText -Pattern 'CODEX_NOT_FOUND'
    Assert-Match -Name 'Install 脚本含 LOCALE_ONLY_FALLBACK 降级码' -Text $installText -Pattern 'LOCALE_ONLY_FALLBACK'
    Assert-Match -Name 'Install 脚本含 SHUTDOWN_FAILED 错误码' -Text $installText -Pattern 'SHUTDOWN_FAILED'
    Assert-Match -Name 'Install 脚本含 CONFIG_WRITE_FAILED 错误码' -Text $installText -Pattern 'CONFIG_WRITE_FAILED'
    Assert-Match -Name 'Install 脚本写入 localeOverride' -Text $installText -Pattern 'Set-ZhLocaleOverride'
    Assert-Match -Name 'Install 脚本调用 CDP 驱动' -Text $installText -Pattern 'Start-ZhRuntimeSession'
    $launchText = Get-RepoText -RelativePath 'Launch-CodexZh.ps1'
    Assert-Match -Name 'Launch 脚本检查已安装状态' -Text $launchText -Pattern 'Test-ZhInstalled'
    Assert-Match -Name 'Launch 脚本含 NOT_INSTALLED 错误码' -Text $launchText -Pattern 'NOT_INSTALLED'
    Assert-Match -Name 'Launch 脚本支持 ALREADY_RUNNING 短路' -Text $launchText -Pattern 'ALREADY_RUNNING'
    $restoreText = Get-RepoText -RelativePath 'Restore-CodexZh.ps1'
    Assert-Match -Name 'Restore 脚本调用配置还原' -Text $restoreText -Pattern 'Restore-ZhConfigFile'
    Assert-Match -Name 'Restore 脚本不删除用户数据' -Text $restoreText -Pattern '不删除用户数据'

    # -----------------------------------------------------------------------
    Write-TestSection 'Codex 检测逻辑（只读）'
    try {
        $detectedInstall = Get-ZhCodexInstall
        if ($null -ne $detectedInstall -and $detectedInstall.IsValid) {
            Assert-True -Name '只读检测可找到 Codex' -Condition $true
            Assert-True -Name '检测结果版本号可解析' -Condition ($null -ne (ConvertTo-ZhVersion -Version ([string]$detectedInstall.Version))) -Detail ([string]$detectedInstall.Version)
            Assert-True -Name '检测结果可执行文件存在' -Condition (Test-Path -LiteralPath $detectedInstall.ExecutablePath)
            Assert-True -Name '检测结果安装目录存在' -Condition (Test-Path -LiteralPath $detectedInstall.InstallLocation)
            if ($detectedInstall.IsStore) {
                Assert-Match -Name 'Store 版 AUMID 形如 PFN!AppId' -Text ([string]$detectedInstall.Aumid) -Pattern '^[^!]+![^!]+$'
            } else {
                Assert-True -Name '便携版检测结果无 AUMID' -Condition ([string]::IsNullOrWhiteSpace([string]$detectedInstall.Aumid))
            }
            Assert-True -Name '检测过程有追踪记录' -Condition (@(Get-ZhDetectionTrace).Count -gt 0)
        } else {
            Skip-Test -Name 'Codex 检测（本机未安装 Codex Desktop）'
        }
    } catch {
        Assert-True -Name 'Codex 只读检测不抛异常' -Condition $false -Detail $_.Exception.Message
    }

    # 函数引用完整性：入口脚本调用的 Write-Zh* 必须在 Common.ps1 中有定义
    $commonSource = [System.IO.File]::ReadAllText((Get-RepoFile -RelativePath 'lib/Common.ps1'))
    $entrySource = ''
    foreach ($entryFile in @('Install-CodexZh.ps1', 'Launch-CodexZh.ps1', 'Restore-CodexZh.ps1', 'Diagnostics.ps1')) {
        $entrySource += [System.IO.File]::ReadAllText((Get-RepoFile -RelativePath $entryFile))
    }
    $definedWrite = @{}
    foreach ($writeMatch in [regex]::Matches($commonSource, '(?m)^\s*function\s+(Write-Zh[A-Za-z0-9]+)')) {
        $definedWrite[$writeMatch.Groups[1].Value] = $true
    }
    $missingWrite = @()
    foreach ($writeMatch in [regex]::Matches($entrySource, '\b(Write-Zh[A-Za-z0-9]+)\b')) {
        $writeName = $writeMatch.Groups[1].Value
        if (-not $definedWrite.ContainsKey($writeName) -and $missingWrite -notcontains $writeName) { $missingWrite += $writeName }
    }
    Assert-True -Name '入口脚本引用的 Write-Zh* 均有定义' -Condition ($missingWrite.Count -eq 0) -Detail ($missingWrite -join ', ')

    # -----------------------------------------------------------------------
    Write-TestSection '敏感信息与危险操作扫描'
    $sourceFiles = @()
    $sourceFiles += @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            ($_.Extension -in @('.ps1', '.mjs', '.js')) -and
            ($_.FullName -notlike '*\tests\*')
        })
    $secretFindings = @()
    $dangerousFindings = @()
    $externalUrlFindings = @()
    foreach ($sourceFile in $sourceFiles) {
        $relative = Get-RelativeRepoPath -FullPath $sourceFile.FullName
        $text = [System.IO.File]::ReadAllText($sourceFile.FullName)
        if ($text -match '(?i)(Get-Content|ReadAllText|OpenRead|Get-Item|Copy-Item)[^\r\n]{0,160}auth\.json|auth\.json[^\r\n]{0,160}(Get-Content|ReadAllText|OpenRead)') {
            $secretFindings += ($relative + ': auth.json 读写')
        }
        if ($text -match 'sk-[A-Za-z0-9]{20,}') { $secretFindings += ($relative + ': sk- 形式密钥') }
        if ($text -match 'Bearer\s+[A-Za-z0-9._\-]{10,}') { $secretFindings += ($relative + ': Bearer token') }
        if ($text -match '(?i)(WriteAllText|AppendAllText|Set-Content|Add-Content|Copy-Item|Remove-Item|Move-Item)[^\r\n]{0,160}(app\.asar|WindowsApps)') {
            $dangerousFindings += ($relative + ': 可能写入 app.asar/WindowsApps')
        }
        $urlMatches = [regex]::Matches($text, 'https?://[^\s''"\)\]]+')
        foreach ($urlMatch in $urlMatches) {
            $url = $urlMatch.Value
            if ($url -notmatch '^https?://(127\.0\.0\.1|localhost)' -and $url -notmatch '^https://nodejs\.org(:\d+)?(/|$)') {
                $externalUrlFindings += ($relative + ': ' + $url)
            }
        }
        if ($text -match '(?i)\b(Invoke-WebRequest|Invoke-RestMethod|curl\.exe|wget\.exe)\b') {
            $externalUrlFindings += ($relative + ': 使用网络下载命令')
        }
    }
    Assert-True -Name '源码中无 auth.json 读取' -Condition ($secretFindings.Count -eq 0) -Detail (($secretFindings | Select-Object -First 5) -join '; ')
    Assert-True -Name '源码中无 app.asar/WindowsApps 写入' -Condition ($dangerousFindings.Count -eq 0) -Detail (($dangerousFindings | Select-Object -First 5) -join '; ')
    Assert-True -Name '源码中无外部网络地址/下载命令（仅允许 127.0.0.1）' -Condition ($externalUrlFindings.Count -eq 0) -Detail (($externalUrlFindings | Select-Object -First 5) -join '; ')
    # 批处理 / 文档允许提到 GitHub 地址，但源码（ps1/mjs/js）只允许本地回环地址
    Assert-True -Name '扫描到源码文件' -Condition ($sourceFiles.Count -ge 6) -Detail ('count=' + $sourceFiles.Count)

    # -----------------------------------------------------------------------
    Write-TestSection '批处理包装（GBK/ANSI）'
    $batExpectations = @{
        '一键汉化.bat' = 'Install-CodexZh.ps1'
        '启动汉化版.bat' = 'Launch-CodexZh.ps1'
        '还原原版.bat' = 'Restore-CodexZh.ps1'
        '诊断.bat' = 'Diagnostics.ps1'
    }
    $gbk = [System.Text.Encoding]::GetEncoding(936)
    foreach ($batName in $batExpectations.Keys) {
        $batPath = Join-Path $script:RepoRoot $batName
        Assert-True -Name ('批处理存在: ' + $batName) -Condition (Test-Path -LiteralPath $batPath)
        if (-not (Test-Path -LiteralPath $batPath)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($batPath)
        $batText = $gbk.GetString($bytes)
        Assert-Match -Name ('批处理调用 powershell: ' + $batName) -Text $batText -Pattern '(?i)powershell(\.exe)?\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File'
        Assert-Match -Name ('批处理目标脚本: ' + $batName) -Text $batText -Pattern ([regex]::Escape($batExpectations[$batName]))
        Assert-Match -Name ('批处理使用 %~dp0: ' + $batName) -Text $batText -Pattern '%~dp0'
        $hasCrLf = ($batText -match "`r`n")
        Assert-True -Name ('批处理换行为 CRLF: ' + $batName) -Condition $hasCrLf
    }

    # -----------------------------------------------------------------------
    Write-TestSection '文档与许可证'
    $readmeText = Get-RepoText -RelativePath 'README.md'
    foreach ($section in @('工作原理', '安全性', '系统要求', '使用', '卸载', '常见问题', '版本兼容', '免责声明')) {
        Assert-Match -Name ('README 含章节: ' + $section) -Text $readmeText -Pattern ([regex]::Escape($section))
    }
    Assert-Match -Name 'README 说明 26.1023 实测版本' -Text $readmeText -Pattern '26\.1023\.6621\.0'
    Assert-Match -Name 'README 说明 26.900+ 受保护版本线' -Text $readmeText -Pattern '26\.900'
    Assert-Match -Name 'README 说明退出码 0/1/2' -Text $readmeText -Pattern '退出码'
    $readmeEn = Get-RepoText -RelativePath 'README.en.md'
    Assert-Match -Name 'README.en.md 存在且含 Disclaimer' -Text $readmeEn -Pattern '(?i)Disclaimer'
    $licenseText = Get-RepoText -RelativePath 'LICENSE'
    Assert-Match -Name 'LICENSE 为 MIT' -Text $licenseText -Pattern '^MIT License'
    Assert-Match -Name 'LICENSE 含版权声明' -Text $licenseText -Pattern 'Copyright \(c\) 2026'
    $noticesText = Get-RepoText -RelativePath 'THIRD_PARTY_NOTICES.md'
    Assert-Match -Name 'THIRD_PARTY_NOTICES 保留 shibaweidu 版权来源' -Text $noticesText -Pattern 'shibaweidu/codex-desktop-zh'
    Assert-Match -Name 'THIRD_PARTY_NOTICES 保留 ukinch605 版权来源' -Text $noticesText -Pattern 'ukinch605/codex-zh-cn-agent'
    Assert-Match -Name 'THIRD_PARTY_NOTICES 声明 MIT' -Text $noticesText -Pattern 'MIT'
    $changelogText = Get-RepoText -RelativePath 'CHANGELOG.md'
    Assert-Match -Name 'CHANGELOG 含 1.0.0 版本' -Text $changelogText -Pattern '1\.0\.0'
    $gitignoreText = Get-RepoText -RelativePath '.gitignore'
    Assert-Match -Name '.gitignore 忽略 logs/' -Text $gitignoreText -Pattern '(?m)^logs/'
    Assert-Match -Name '.gitignore 忽略 results/' -Text $gitignoreText -Pattern '(?m)^results/'
    Assert-Match -Name '.gitignore 忽略 config 备份' -Text $gitignoreText -Pattern 'bak-zhcn'
    $diagnosticsDoc = Get-RepoText -RelativePath 'docs/diagnostics.md'
    Assert-Match -Name '诊断文档说明报告位置' -Text $diagnosticsDoc -Pattern '%LOCALAPPDATA%'

    # -----------------------------------------------------------------------
    Write-TestSection '仓库清洁度'
    Assert-False -Name '仓库内无 logs 目录' -Condition (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'logs'))
    Assert-False -Name '仓库内无 results 目录' -Condition (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'results'))
    $strayConfigBackups = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter '*.bak-zhcn' -File -ErrorAction SilentlyContinue)
    Assert-True -Name '仓库内无 config.toml.bak-zhcn' -Condition ($strayConfigBackups.Count -eq 0)
    $selfTestText = [System.IO.File]::ReadAllText((Get-RepoFile -RelativePath 'tests/SelfTest.ps1'))
    Assert-NotMatch -Name '自测脚本不启动 Codex 运行时' -Text $selfTestText -Pattern '(?m)^\s*Start-ZhRuntimeSession\s'
    Assert-NotMatch -Name '自测脚本不关闭 Codex 进程' -Text $selfTestText -Pattern '(?m)^\s*Close-ZhCodexSafely\s'
    Assert-NotMatch -Name '自测脚本不调用 COM 激活' -Text $selfTestText -Pattern '(?m)^\s*Activate-ZhStoreApp\s'

} catch {
    Assert-True -Name '自测脚本未发生意外异常' -Condition $false -Detail ($_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
    try { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
$summaryColor = 'Green'
if ($script:FailCount -gt 0) { $summaryColor = 'Red' }
Write-Host ('  自测结果: PASS {0} / FAIL {1} / SKIP {2}' -f $script:PassCount, $script:FailCount, $script:SkipCount) -ForegroundColor $summaryColor
Write-Host '============================================================' -ForegroundColor Cyan
if ($script:FailCount -gt 0) {
    Write-Host ''
    Write-Host '失败项：' -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host ('  - ' + $failure) -ForegroundColor Red }
    exit 1
}
exit 0
