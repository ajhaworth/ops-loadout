# smoke.ps1 - Windows setup smoke tests
#
# Runs everywhere: syntax, pure-logic and config-consistency checks.
# Windows only: the dry-run invocations, which need winget/registry/USERPROFILE.
#
#   pwsh tests/windows/smoke.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ("$Expected" -eq "$Actual") {
        $script:Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

function Write-Skipped {
    param([string]$Message)
    $script:Skipped++
    Write-Host "  [SKIP] $Message" -ForegroundColor DarkGray
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title" -ForegroundColor Cyan
}

Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\dotfiles.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\packages.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\registry.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\comfyui.psm1") -Force

$onWindows = Test-IsWindowsPlatform

# ---------------------------------------------------------------------------
Write-Section "PowerShell syntax"

$psFiles = @()
$psFiles += Get-ChildItem -Path (Join-Path $repoRoot "lib\windows") -Filter "*.psm1" -Recurse
$psFiles += Get-ChildItem -Path (Join-Path $repoRoot "platforms\windows") -Filter "*.ps1" -Recurse
$psFiles += Get-ChildItem -Path (Join-Path $repoRoot "tests\windows") -Filter "*.ps1"
$psFiles += Get-Item (Join-Path $repoRoot "setup.ps1")

foreach ($file in $psFiles) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    $errorCount = 0
    if ($parseErrors) { $errorCount = $parseErrors.Count }
    $relative = $file.FullName.Substring($repoRoot.Length + 1)
    Assert-Equal 0 $errorCount "parses cleanly: $relative"
    if ($errorCount -gt 0) {
        foreach ($e in $parseErrors) {
            Write-Host "         $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor DarkRed
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section "Profile parsing"

$windowsProfile = Read-Profile -ProfileName "windows"
Assert-True ($null -ne $windowsProfile) "windows profile loads"
Assert-True (Assert-ProfileOS -Profile $windowsProfile -ExpectedOS "windows" -ProfileName "windows") "windows profile validates on Windows"

$workProfile = Read-Profile -ProfileName "work"
Assert-True (-not (Assert-ProfileOS -Profile $workProfile -ExpectedOS "windows" -ProfileName "work")) "work profile is rejected on Windows"

Assert-True (Test-ProfileFlag -Profile $windowsProfile -Flag 'DEFINITELY_NOT_SET') "unset profile flags default to enabled"
Assert-True (-not (Test-ProfileFlag -Profile $windowsProfile -Flag 'PROFILE_DEBLOAT')) "PROFILE_DEBLOAT is disabled"

# ---------------------------------------------------------------------------
Write-Section "Helper functions"

Assert-Equal 'WINGET_SOFTWARE_DEV' (Get-CategoryVar -Prefix 'WINGET' -Category 'software-dev') "Get-CategoryVar hyphen to underscore"
Assert-Equal 'CHOCO_GAMING' (Get-CategoryVar -Prefix 'CHOCO' -Category 'gaming') "Get-CategoryVar simple category"
Assert-Equal 'Apply-Explorer' (Get-ApplyFunctionName -BaseName 'explorer') "Get-ApplyFunctionName simple"
Assert-Equal 'Apply-FileExplorer' (Get-ApplyFunctionName -BaseName 'file-explorer') "Get-ApplyFunctionName hyphenated"

Assert-Equal 'C:\Users\me\x' (Expand-PathToken -Text '%USERPROFILE%\x' -Token '%USERPROFILE%' -Value 'C:\Users\me') "Expand-PathToken substitutes"
Assert-Equal 'C:\Users\me\x' (Expand-PathToken -Text '%userprofile%\x' -Token '%USERPROFILE%' -Value 'C:\Users\me') "Expand-PathToken is case-insensitive"
Assert-Equal 'a$1b' (Expand-PathToken -Text 'aTOKb' -Token 'TOK' -Value '$1') "Expand-PathToken treats value literally"
Assert-Equal 'no tokens here' (Expand-PathToken -Text 'no tokens here' -Token '%X%' -Value 'y') "Expand-PathToken leaves other text alone"

$tempList = Join-Path ([IO.Path]::GetTempPath()) "pkglist_test.txt"
@(
    '# a comment',
    '',
    'Package.One',
    'Package.Two  # trailing comment',
    '   ',
    'choco-pkg --pre'
) | Set-Content -Path $tempList
$parsed = @(Read-PackageList -FilePath $tempList)
Remove-Item -LiteralPath $tempList -Force
Assert-Equal 3 $parsed.Count "Read-PackageList strips comments and blanks"
Assert-Equal 'Package.Two' $parsed[1] "Read-PackageList strips inline comments"
Assert-Equal 'choco-pkg --pre' $parsed[2] "Read-PackageList keeps package flags"

# ---------------------------------------------------------------------------
Write-Section "Package lists match profile variables"

$packagesDir = Join-Path $repoRoot "config\packages\windows"
$knownVars = @{}

foreach ($manager in @('winget', 'choco', 'github', 'comfynodes')) {
    $prefix = 'CHOCO'
    if ($manager -eq 'winget') { $prefix = 'WINGET' }
    if ($manager -eq 'github') { $prefix = 'GITHUB' }
    if ($manager -eq 'comfynodes') { $prefix = 'COMFYNODES' }

    $managerDir = Join-Path $packagesDir $manager
    if (-not (Test-Path -LiteralPath $managerDir)) { continue }

    foreach ($file in Get-ChildItem -LiteralPath $managerDir -Filter "*.txt") {
        $varName = Get-CategoryVar -Prefix $prefix -Category $file.BaseName
        $knownVars[$varName] = $true
        $packages = @(Read-PackageList -FilePath $file.FullName)
        Assert-True ($packages.Count -gt 0) "$manager/$($file.Name) is not empty"

        # A malformed spec only fails at install time otherwise
        if ($manager -eq 'github') {
            foreach ($package in $packages) {
                $parsed = $null
                try { $parsed = ConvertFrom-GitHubPackageSpec -Spec $package } catch { $parsed = $null }
                Assert-True ($null -ne $parsed) "github spec parses: $package"
            }
        }
        if ($manager -eq 'comfynodes') {
            foreach ($package in $packages) {
                $parsed = $null
                try { $parsed = ConvertFrom-ComfyNodeSpec -Spec $package } catch { $parsed = $null }
                Assert-True ($null -ne $parsed) "comfynode spec parses: $package"
            }
        }
    }
}

# Every WINGET_*/CHOCO_*/GITHUB_*/COMFYNODES_* variable in the profile must have
# a backing file, otherwise a deleted category silently lingers in the profile.
foreach ($key in $windowsProfile.Keys) {
    if ($key -match '^(WINGET|CHOCO|GITHUB|COMFYNODES)_') {
        Assert-True $knownVars.ContainsKey($key) "profile var $key has a matching package list"
    }
}

# --- ComfyUI custom node specs ---------------------------------------------

$node = ConvertFrom-ComfyNodeSpec -Spec 'willmiao/ComfyUI-Lora-Manager'
Assert-Equal 'willmiao/ComfyUI-Lora-Manager' $node.Repo "node spec parses repo"
Assert-Equal 'ComfyUI-Lora-Manager' $node.Directory "node directory defaults to the repo name"
Assert-Equal 'https://github.com/willmiao/ComfyUI-Lora-Manager.git' $node.Url "node spec builds a clone URL"

$renamedNode = ConvertFrom-ComfyNodeSpec -Spec 'owner/repo | custom-dir'
Assert-Equal 'custom-dir' $renamedNode.Directory "node spec honours an explicit directory"

$nodeThrew = $false
try { ConvertFrom-ComfyNodeSpec -Spec 'no-slash' | Out-Null } catch { $nodeThrew = $true }
Assert-True $nodeThrew "node spec without owner/repo is rejected"

# --- GitHub release spec parsing -------------------------------------------

$full = ConvertFrom-GitHubPackageSpec -Spec 'Nonary/Vibepollo | VibepolloSetup-*.exe | Vibepollo | /quiet /norestart'
Assert-Equal 'Nonary/Vibepollo' $full.Repo "spec parses repo"
Assert-Equal 'VibepolloSetup-*.exe' $full.AssetPattern "spec parses asset pattern"
Assert-Equal 'Vibepollo' $full.DisplayName "spec parses display name"
Assert-Equal 2 $full.InstallArgs.Count "spec splits install args"

$bare = ConvertFrom-GitHubPackageSpec -Spec 'owner/some-repo'
Assert-Equal '*.exe' $bare.AssetPattern "bare spec defaults the asset pattern"
Assert-Equal 'some-repo' $bare.DisplayName "bare spec defaults display name to the repo name"
Assert-Equal '/quiet' ($bare.InstallArgs -join ' ') "bare spec defaults install args to /quiet"

$threw = $false
try { ConvertFrom-GitHubPackageSpec -Spec 'not-a-repo' | Out-Null } catch { $threw = $true }
Assert-True $threw "spec without owner/repo is rejected"

# Detection must not blow up on a name that is definitely not installed
Assert-True ($null -eq (Get-InstalledProgram -NamePattern 'NoSuchProgram-ZZZ')) "Get-InstalledProgram returns null when absent"

# --- Version comparison (drives the upgrade decision) ----------------------

Assert-Equal 1 (Compare-VersionString -Left '1.18.4' -Right '1.18.3') "1.18.4 is newer than 1.18.3"
Assert-Equal -1 (Compare-VersionString -Left '1.18.3' -Right '1.18.4') "1.18.3 is older than 1.18.4"
Assert-Equal 0 (Compare-VersionString -Left '1.18.4' -Right '1.18.4') "equal versions compare equal"
Assert-Equal 1 (Compare-VersionString -Left 'v1.18.4' -Right '1.18.3') "a leading v is ignored"
Assert-Equal 0 (Compare-VersionString -Left '1.18' -Right '1.18.0') "missing components count as zero"
Assert-Equal 1 (Compare-VersionString -Left '1.19.0' -Right '1.18.99') "minor version outranks patch"

# The case this repo actually hit: installed 1.18.3-beta.7, released v1.18.4
Assert-Equal 1 (Compare-VersionString -Left '1.18.4' -Right '1.18.3-beta.7') "release beats an older prerelease"
Assert-Equal 1 (Compare-VersionString -Left '1.18.4' -Right '1.18.4-rc.1') "release beats its own prerelease"
Assert-Equal -1 (Compare-VersionString -Left '1.18.4-rc.1' -Right '1.18.4') "prerelease loses to the release"
Assert-Equal 1 (Compare-VersionString -Left '1.18.4-rc.2' -Right '1.18.4-rc.1') "prereleases compare against each other"

# Unparseable input must read as "cannot tell", never as "upgrade" - otherwise
# the package reinstalls on every run.
Assert-True ($null -eq (Compare-VersionString -Left '1.18.4' -Right '')) "empty installed version cannot be compared"
Assert-True ($null -eq (Compare-VersionString -Left '1.18.4' -Right 'unknown')) "non-numeric installed version cannot be compared"

# The reinstall-loop guard: Vibepollo's v1.18.4 release registers a
# DisplayVersion of 1.18.4-beta.3, so tag-vs-DisplayVersion must ignore
# suffixes or the package upgrades forever.
Assert-Equal 0 (Compare-VersionString -Left '1.18.4' -Right '1.18.4-beta.3' -IgnorePreRelease) "IgnorePreRelease treats a matching core as equal"
Assert-Equal 1 (Compare-VersionString -Left '1.18.5' -Right '1.18.4-beta.3' -IgnorePreRelease) "IgnorePreRelease still sees a newer core"
Assert-Equal 1 (Compare-VersionString -Left '1.18.4' -Right '1.18.4-beta.3') "without the switch the suffix wins (the loop this guards)"

# ---------------------------------------------------------------------------
Write-Section "Dotfiles manifest"

$manifestPath = Join-Path $repoRoot "config\dotfiles\manifest.windows.txt"
Assert-True (Test-Path -LiteralPath $manifestPath) "manifest.windows.txt exists"

$manifestLines = @(Get-Content $manifestPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
Assert-True ($manifestLines.Count -gt 0) "manifest has entries"

foreach ($line in $manifestLines) {
    $parts = $line -split '\|'
    Assert-True ($parts.Count -ge 2) "manifest line has source and destination: $line"

    $source = Join-Path $repoRoot ($parts[0].Trim() -replace '/', [IO.Path]::DirectorySeparatorChar)
    Assert-True (Test-Path -LiteralPath $source) "manifest source exists: $($parts[0].Trim())"

    if ($parts.Count -ge 3 -and $parts[2].Trim()) {
        $condition = $parts[2].Trim()
        Assert-True ($windowsProfile.ContainsKey($condition)) "manifest condition $condition is declared in windows.conf"
    }
}

# The full manifest (conditions ignored) should still be readable
$allEntries = @(Read-WindowsManifest -ManifestPath $manifestPath -Profile $windowsProfile)
Assert-True ($allEntries.Count -gt 0) "Read-WindowsManifest returns enabled entries"

# ---------------------------------------------------------------------------
Write-Section "Defaults modules"

$defaultsDir = Join-Path $repoRoot "platforms\windows\defaults"
Assert-True (Test-Path -LiteralPath $defaultsDir) "defaults directory exists"

$defaultsVars = @{}
foreach ($file in Get-ChildItem -LiteralPath $defaultsDir -Filter "*.ps1") {
    $expected = Get-ApplyFunctionName -BaseName $file.BaseName
    $defaultsVars[(Get-CategoryVar -Prefix 'DEFAULTS' -Category $file.BaseName)] = $true

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $defs = @($ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true
    ))
    $functions = @($defs | ForEach-Object { $_.Name })

    Assert-True ($functions -contains $expected) "$($file.Name) defines $expected"

    # defaults.ps1 invokes every module with -ProfileConfig; a module missing
    # the parameter fails at runtime with a binding error, not at parse time.
    $applyDef = $defs | Where-Object { $_.Name -eq $expected } | Select-Object -First 1
    if ($null -ne $applyDef -and $null -ne $applyDef.Body.ParamBlock) {
        $paramNames = @($applyDef.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-True ($paramNames -contains 'ProfileConfig') "$expected accepts -ProfileConfig"
        Assert-True ($paramNames -contains 'DryRun') "$expected accepts -DryRun"
    } else {
        Assert-True $false "$expected has a param block"
    }
}

foreach ($key in $windowsProfile.Keys) {
    if ($key -match '^DEFAULTS_') {
        Assert-True $defaultsVars.ContainsKey($key) "profile var $key has a matching defaults module"
    }
}

# ---------------------------------------------------------------------------
Write-Section "ComfyUI model config"

$comfyModule = Join-Path $defaultsDir "comfyui.ps1"
if (Test-Path -LiteralPath $comfyModule) {
    . $comfyModule

    Assert-True ($windowsProfile.ContainsKey('COMFYUI_MODEL_PATH')) "COMFYUI_MODEL_PATH is set in windows.conf"

    $modelPath = $windowsProfile['COMFYUI_MODEL_PATH']

    # A share already using ComfyUI's own names needs no renaming
    $native = @(Resolve-ComfyModelFolders -FolderNames @('checkpoints', 'loras', 'vae'))
    Assert-Equal 3 $native.Count "native folder names all resolve"
    Assert-Equal 0 @($native | Where-Object { $_.Key -ne $_.Folder }).Count "native names are not renamed"

    # The A1111-style layout this repo actually points at
    $a1111 = @(Resolve-ComfyModelFolders -FolderNames @('Stable-diffusion', 'Lora', 'ESRGAN', 'ControlNet', 'VAE'))
    $byKey = @{}
    foreach ($entry in $a1111) { $byKey[$entry.Key] = $entry.Folder }
    Assert-Equal 'Stable-diffusion' $byKey['checkpoints'] "checkpoints maps to Stable-diffusion"
    Assert-Equal 'Lora' $byKey['loras'] "loras maps to Lora"
    Assert-Equal 'ESRGAN' $byKey['upscale_models'] "upscale_models maps to ESRGAN"
    Assert-Equal 'ControlNet' $byKey['controlnet'] "controlnet keeps the share's casing"
    Assert-Equal 'VAE' $byKey['vae'] "vae keeps the share's casing"

    # Folders that are not model types must not be invented into the config
    $sparse = @(Resolve-ComfyModelFolders -FolderNames @('checkpoints', 'random-junk'))
    Assert-Equal 1 $sparse.Count "unknown folders are ignored"
    Assert-Equal 0 @(Resolve-ComfyModelFolders -FolderNames @()).Count "an empty share resolves to nothing"

    # ComfyUI's own name wins when a share happens to have both spellings
    $both = @(Resolve-ComfyModelFolders -FolderNames @('checkpoints', 'Stable-diffusion'))
    Assert-Equal 'checkpoints' ($both | Where-Object { $_.Key -eq 'checkpoints' }).Folder "ComfyUI's own name is preferred"

    $config = New-ComfyModelsConfig -BasePath $modelPath -Folders $a1111
    Assert-True ($config -match [regex]::Escape("base_path: $modelPath")) "config carries the base_path verbatim"
    # Generated file is CRLF, so anchors must tolerate the trailing \r
    Assert-True ($config -match '(?m)^\s+checkpoints: Stable-diffusion\r?$') "config writes the mapped folder name"
    Assert-True ($config -match '(?m)^ops_workstation:\r?$') "config uses its own top-level key"
    # Desktop owns the download location; claiming it would fight the app
    Assert-True ($config -notmatch '(?m)^\s+is_default:') "config does not claim the default download target"

    foreach ($entry in $a1111) {
        $keyHits = ([regex]::Matches($config, "(?m)^\s+$([regex]::Escape($entry.Key)): ")).Count
        Assert-Equal 1 $keyHits "config declares $($entry.Key) once"
    }
} else {
    Write-Skipped "comfyui.ps1 not present"
}

# ---------------------------------------------------------------------------
Write-Section "ComfyUI launch arguments"

$comfyNetModule = Join-Path $defaultsDir "comfyui-network.ps1"
if (Test-Path -LiteralPath $comfyNetModule) {
    . $comfyNetModule

    Assert-Equal '--enable-manager --listen 0.0.0.0' `
        (Merge-ComfyLaunchArgs -Existing '--enable-manager' -Flag '--listen' -Value '0.0.0.0') `
        "merging appends without dropping existing args"

    # Re-running must not accumulate duplicates
    $once = Merge-ComfyLaunchArgs -Existing '--enable-manager' -Flag '--listen' -Value '0.0.0.0'
    $twice = Merge-ComfyLaunchArgs -Existing $once -Flag '--listen' -Value '0.0.0.0'
    Assert-Equal $once $twice "merging is idempotent"

    Assert-Equal '--listen 1.2.3.4' `
        (Merge-ComfyLaunchArgs -Existing '--listen 0.0.0.0' -Flag '--listen' -Value '1.2.3.4') `
        "merging replaces an existing value"

    Assert-Equal '--listen 0.0.0.0' `
        (Merge-ComfyLaunchArgs -Existing '' -Flag '--listen' -Value '0.0.0.0') `
        "merging into empty args works"

    # A valueless flag must not swallow the next flag
    Assert-Equal '--enable-manager --listen 0.0.0.0' `
        (Merge-ComfyLaunchArgs -Existing '--enable-manager --listen 0.0.0.0' -Flag '--enable-manager' -Value '') `
        "a valueless flag leaves the following flag alone"

    $chained = Merge-ComfyLaunchArgs -Existing '--enable-manager' -Flag '--listen' -Value '0.0.0.0'
    $chained = Merge-ComfyLaunchArgs -Existing $chained -Flag '--port' -Value '8188'
    Assert-Equal '--enable-manager --listen 0.0.0.0 --port 8188' $chained "listen and port compose"

    # The firewall must stay shut unless an auth node is present, and the node
    # that provides it has to actually be in the package list.
    # @() because a single-name list unwraps to a bare string under StrictMode
    Assert-True (@(Get-ComfyAuthNodeNames).Count -gt 0) "at least one auth node is recognised"
    Assert-True ($windowsProfile.ContainsKey('COMFYUI_REQUIRE_AUTH')) "COMFYUI_REQUIRE_AUTH is declared"

    $nodeList = Join-Path $repoRoot "config\packages\windows\comfynodes\core.txt"
    if (Test-Path -LiteralPath $nodeList) {
        $nodeSpecs = @(Read-PackageList -FilePath $nodeList)
        $nodeDirs = @($nodeSpecs | ForEach-Object { (ConvertFrom-ComfyNodeSpec -Spec $_).Directory })
        $authListed = @(Get-ComfyAuthNodeNames | Where-Object { $nodeDirs -contains $_ })
        Assert-True ($authListed.Count -gt 0) "an auth node is in the comfynodes list"
    }
} else {
    Write-Skipped "comfyui-network.ps1 not present"
}

# ---------------------------------------------------------------------------
Write-Section "Stage argument splatting"

# Regression guard. Array splatting passes elements POSITIONALLY, so
# @('-ProfileName', 'windows') binds the literal '-ProfileName' as the profile
# name and drops '-DryRun' into $args. Stages must be invoked with a hashtable.

$platformSetup = Join-Path $repoRoot "platforms\windows\setup.ps1"
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($platformSetup, [ref]$null, [ref]$null)

$invokeStageDef = @($setupAst.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Invoke-Stage'
}, $true)) | Select-Object -First 1

Assert-True ($null -ne $invokeStageDef) "platform setup defines Invoke-Stage"

if ($null -ne $invokeStageDef -and $null -ne $invokeStageDef.Body.ParamBlock) {
    $argParam = @($invokeStageDef.Body.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'Arguments' }) | Select-Object -First 1
    Assert-True ($null -ne $argParam) "Invoke-Stage has an Arguments parameter"
    if ($null -ne $argParam) {
        Assert-Equal 'Hashtable' $argParam.StaticType.Name "Invoke-Stage -Arguments is [hashtable], not [array]"
    }
}

# Prove the binding semantics rather than trusting them
$splatChild = Join-Path ([IO.Path]::GetTempPath()) "splat_child_test.ps1"
@'
param(
    [Alias('Profile')]
    [string]$ProfileName = "unset",
    [switch]$DryRun,
    [switch]$List
)
"$ProfileName|$DryRun|$List"
'@ | Set-Content -Path $splatChild

$hashArgs = @{ ProfileName = 'windows'; DryRun = $true }
Assert-Equal 'windows|True|False' (& $splatChild @hashArgs) "hashtable splat binds named parameters"

$arrayArgs = @('-ProfileName', 'windows', '-DryRun')
Assert-Equal '-ProfileName|False|False' (& $splatChild @arrayArgs) "array splat binds positionally (the bug this guards)"

Remove-Item -LiteralPath $splatChild -Force

# ---------------------------------------------------------------------------
Write-Section "Registry helpers"

Reset-RegistryResults
$results = Get-RegistryResults
Assert-Equal 0 $results.Changed.Count "Reset-RegistryResults clears changed"
Assert-Equal 0 (Get-RegistryFailureCount) "Reset-RegistryResults clears failures"

# ---------------------------------------------------------------------------
Write-Section "End-to-end dry runs"

if (-not $onWindows) {
    Write-Skipped "dry-run invocations require Windows (winget, registry, USERPROFILE)"
} else {
    $setupScript = Join-Path $repoRoot "setup.ps1"

    $global:LASTEXITCODE = 0
    & $setupScript -ProfileName windows -DryRun packages | Out-Null
    Assert-Equal 0 $LASTEXITCODE "packages dry-run succeeds"

    $global:LASTEXITCODE = 0
    & $setupScript -ProfileName windows -DryRun dotfiles | Out-Null
    Assert-Equal 0 $LASTEXITCODE "dotfiles dry-run succeeds"

    $global:LASTEXITCODE = 0
    & $setupScript -ProfileName windows -DryRun defaults | Out-Null
    Assert-Equal 0 $LASTEXITCODE "defaults dry-run succeeds"

    $global:LASTEXITCODE = 0
    & $setupScript -ProfileName windows defaults ls | Out-Null
    Assert-Equal 0 $LASTEXITCODE "defaults ls succeeds"

    # -Profile must still work as an alias
    $global:LASTEXITCODE = 0
    & $setupScript -Profile windows -DryRun dotfiles | Out-Null
    Assert-Equal 0 $LASTEXITCODE "-Profile alias still binds"

    $failedAsExpected = $false
    try {
        $global:LASTEXITCODE = 0
        & $setupScript -ProfileName work -DryRun | Out-Null
        if ($LASTEXITCODE -ne 0) { $failedAsExpected = $true }
    } catch {
        $failedAsExpected = $true
    }
    Assert-True $failedAsExpected "mismatched profile exits non-zero"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------"
Write-Host "Passed:  $script:Passed" -ForegroundColor Green
if ($script:Skipped -gt 0) {
    Write-Host "Skipped: $script:Skipped" -ForegroundColor DarkGray
}
if ($script:Failed -gt 0) {
    Write-Host "Failed:  $script:Failed" -ForegroundColor Red
    Write-Host ""
    exit 1
}
Write-Host ""
Write-Host "windows smoke tests passed"
exit 0
