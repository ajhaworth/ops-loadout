# bridge.ps1 - Loadout <-> lib/windows/packages.psm1
#
# Invoked as:
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 status  <repo>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 install <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 uninstall <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 update <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 open    <url>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 icon    <exe> <outpng>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 launch  <exe>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 tasks-status <repo> <section> [profile]
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 tasks-apply  <repo> <section> <id> [profile]
#
# `status`/`tasks-status` print one JSON array; the rest stream plain text.
#
# tasks-status/tasks-apply feed Loadout's Setup tab (see CLAUDE.md,
# "Setup Tasks (Loadout)"). Sections: prereq, dotfiles, defaults, debloat.

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'install', 'uninstall', 'update', 'icon', 'launch', 'open', 'tasks-status', 'tasks-apply')]
    [string]$Verb,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Args2
)

$ErrorActionPreference = 'Stop'

function Import-OpsModules {
    param([string]$RepoRoot)
    Import-Module (Join-Path $RepoRoot 'lib\windows\common.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\packages.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\comfyui.psm1') -Force
}

# tasks-status/tasks-apply need the registry and dotfiles helpers too, plus
# comfyui.psm1 for the comfyui*.ps1 defaults modules.
function Import-TaskModules {
    param([string]$RepoRoot)
    Import-Module (Join-Path $RepoRoot 'lib\windows\common.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\registry.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\comfyui.psm1') -Force
}

# No --profile means every flag defaults to enabled, same as everywhere else
# in this repo (Test-ProfileFlag on an empty hashtable). A profile name that
# does not resolve falls back to the same empty config.
#
# Read-Profile narrates a missing profile through Write-Err, which is Write-Host
# underneath and therefore lands on this process's stdout - ahead of the single
# JSON array a status verb prints. Hence the same 6>$null guard the status
# traversal itself runs behind; the note goes to stderr, which Loadout
# already treats as log output.
function Get-BridgeProfileConfig {
    param([string]$ProfileName)
    if ($ProfileName) {
        $config = & { Read-Profile -ProfileName $ProfileName } 6>$null
        if ($null -ne $config) { return $config }
        [Console]::Error.WriteLine("Profile '$ProfileName' not found - treating every category as enabled")
    }
    return @{}
}

# comfyui.ps1/comfyui-network.ps1 write files (yaml/json) and a firewall
# rule, not registry values - Invoke-DefaultsModules has no way to tell what
# they would do short of duplicating their own branchy checks externally,
# which is exactly the "one code path" rule this repo's defaults follow. So
# they get a single row each, always 'unknown', rather than a guess dressed
# up as a real status.
$script:FileBasedDefaultsModules = @('comfyui', 'comfyui-network')

function New-TaskRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$State,
        [string]$Detail = ''
    )
    [pscustomobject]@{
        id      = $Id
        section = $Section
        group   = $Group
        name    = $Name
        state   = $State
        detail  = $Detail
    }
}

# --- prereq -----------------------------------------------------------------

function Get-CommandVersionDetail {
    param([string]$Name)
    try {
        $line = & $Name --version 2>$null | Select-Object -First 1
        if ($line) { return "$line".Trim() }
    } catch {
        # Missing entirely, or --version isn't a thing it understands
    }
    return ''
}

function Get-PrereqStatusRows {
    $rows = @()

    foreach ($tool in @('winget', 'git', 'pwsh')) {
        $cmd = Get-Command -Name $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            $rows += New-TaskRow -Id "prereq:$tool" -Section 'prereq' -Group 'Tools' -Name $tool `
                -State 'applied' -Detail (Get-CommandVersionDetail -Name $tool)
        } else {
            $rows += New-TaskRow -Id "prereq:$tool" -Section 'prereq' -Group 'Tools' -Name $tool `
                -State 'pending' -Detail 'not found on PATH'
        }
    }

    if (Test-SymlinkCapability) {
        $rows += New-TaskRow -Id 'prereq:developer-mode' -Section 'prereq' -Group 'Tools' -Name 'Developer Mode' `
            -State 'applied' -Detail 'symlinks already work'
    } elseif (-not (Test-Administrator)) {
        $rows += New-TaskRow -Id 'prereq:developer-mode' -Section 'prereq' -Group 'Tools' -Name 'Developer Mode' `
            -State 'needs_admin' -Detail 'enable Developer Mode, or run Loadout as Administrator'
    } else {
        $rows += New-TaskRow -Id 'prereq:developer-mode' -Section 'prereq' -Group 'Tools' -Name 'Developer Mode' `
            -State 'pending' -Detail 'AllowDevelopmentWithoutDevLicense not set'
    }

    return $rows
}

function Invoke-PrereqApply {
    param([string]$Id)

    $target = $Id -replace '^prereq:', ''
    switch ($target) {
        'winget' {
            Write-Host 'winget cannot be installed by this tool - install App Installer from the Microsoft Store'
            exit 1
        }
        'git' {
            winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { exit 1 }
        }
        'pwsh' {
            winget install --exact --id Microsoft.PowerShell --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { exit 1 }
        }
        'developer-mode' {
            Reset-RegistryResults
            Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
                -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -Label 'Enable Developer Mode' | Out-Null
            if ((Get-RegistryFailureCount) -gt 0) { exit 1 }
            # An access-denied write lands in NeedsAdmin, not Failed - the
            # setting did not get applied either way, so this is not a success.
            if ((Get-RegistryResults).NeedsAdmin.Count -gt 0) {
                Write-Host 'Enabling Developer Mode needs Administrator'
                exit 1
            }
        }
        default {
            Write-Host "Unknown prereq id: $Id"
            exit 1
        }
    }
    Write-Host "Applied $Id"
}

# --- dotfiles -----------------------------------------------------------------

function Get-DotfilesManifestEntries {
    param([hashtable]$ProfileConfig, [string]$RepoRoot)
    $manifestPath = Join-Path $RepoRoot 'config\dotfiles\manifest.windows.txt'
    return @(Read-WindowsManifest -ManifestPath $manifestPath -Profile $ProfileConfig)
}

function Get-DotfilesStatusRowsForBridge {
    param([hashtable]$ProfileConfig, [string]$RepoRoot)

    $entries = Get-DotfilesManifestEntries -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot
    $rows = @()

    foreach ($entry in $entries) {
        $statusRows = @(Get-DotfilesStatus -Entries @($entry) -RepoRoot $RepoRoot)
        $row = $statusRows[0]

        $state = 'pending'
        switch ($row.State) {
            'linked'         { $state = 'applied' }
            'source-missing' { $state = 'failed' }
            default          { $state = 'pending' }
        }

        $detail = $row.Detail
        if (-not $detail) { $detail = 'not linked' }

        $rows += New-TaskRow -Id "dotfiles:$($entry.Dest)" -Section 'dotfiles' -Group 'Dotfiles' `
            -Name (Split-Path -Leaf $row.Destination) -State $state -Detail $detail
    }

    return $rows
}

function Invoke-DotfilesApply {
    param([hashtable]$ProfileConfig, [string]$RepoRoot, [string]$Id)

    $destKey = $Id -replace '^dotfiles:', ''
    $entries = Get-DotfilesManifestEntries -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot
    $entry = $entries | Where-Object { $_.Dest -eq $destKey } | Select-Object -First 1

    if ($null -eq $entry) {
        Write-Host "Unknown dotfiles id: $Id"
        exit 1
    }

    Reset-DotfilesResults
    $sourceFull = Join-Path $RepoRoot $entry.Source
    # -Force: without it New-Symlink *skips* a destination that points
    # somewhere else, or whose parent tree is missing more than one level, and
    # returns $true - so Loadout reported "applied" for a link it never
    # made. An explicit per-row apply is the user asking for that row, and
    # Backup-ExistingPath still preserves whatever was there.
    New-Symlink -Source $sourceFull -Destination $entry.Dest -DryRun:$false -Force | Out-Null

    if ((Get-DotfilesFailureCount) -gt 0) {
        exit 1
    }

    # New-Symlink swallows a skip into a $true return, so confirm the state it
    # claimed rather than trusting the call.
    $after = @(Get-DotfilesStatus -Entries @($entry) -RepoRoot $RepoRoot)
    if ($after.Count -eq 0 -or $after[0].State -ne 'linked') {
        $detail = 'not linked'
        if ($after.Count -gt 0 -and $after[0].Detail) { $detail = $after[0].Detail }
        Write-Host "Failed: $($entry.Dest) is still $detail"
        exit 1
    }

    Write-Host "Applied $Id"
}

# --- defaults -----------------------------------------------------------------

function New-DefaultsRegistryRow {
    param([string]$Module, [hashtable]$Entry, [string]$State)
    New-TaskRow -Id "defaults:${Module}:$($Entry.Id)" -Section 'defaults' -Group $Module `
        -Name $Entry.Label -State $State -Detail $Entry.Detail
}

function Get-DefaultsStatusRowsForBridge {
    param([hashtable]$ProfileConfig, [string]$RepoRoot)

    $rows = @()
    Reset-RegistryResults
    $modules = @(Invoke-DefaultsModules -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot -DryRun)

    foreach ($m in $modules) {
        if (-not $m.Enabled) { continue }

        if ($script:FileBasedDefaultsModules -contains $m.Module) {
            $rows += New-TaskRow -Id "defaults:$($m.Module):module" -Section 'defaults' -Group $m.Module `
                -Name $m.Module -State 'unknown' -Detail 'run to apply'
            continue
        }

        if ($m.MissingFunc) { continue }

        if ($m.Error) {
            $rows += New-TaskRow -Id "defaults:$($m.Module):module" -Section 'defaults' -Group $m.Module `
                -Name $m.Module -State 'failed' -Detail "$($m.Error)"
            continue
        }

        $reg = $m.RegistryResults
        if ($null -eq $reg) { continue }

        foreach ($entry in $reg.Pending)    { $rows += New-DefaultsRegistryRow -Module $m.Module -Entry $entry -State 'pending' }
        foreach ($entry in $reg.Skipped)    { $rows += New-DefaultsRegistryRow -Module $m.Module -Entry $entry -State 'applied' }
        foreach ($entry in $reg.NeedsAdmin) { $rows += New-DefaultsRegistryRow -Module $m.Module -Entry $entry -State 'needs_admin' }
        foreach ($entry in $reg.Failed)     { $rows += New-DefaultsRegistryRow -Module $m.Module -Entry $entry -State 'failed' }
    }

    return $rows
}

function Invoke-DefaultsApply {
    param([hashtable]$ProfileConfig, [string]$RepoRoot, [string]$Id)

    # "defaults:<module>:<Path>\<Name>" or "defaults:<module>:module". The
    # registry part may itself contain ':' (HKCU:\...), so split with a limit.
    $parts = $Id -split ':', 3
    if ($parts.Count -lt 2 -or $parts[0] -ne 'defaults') {
        Write-Host "Unknown task id: $Id"
        exit 1
    }
    $module = $parts[1]
    # An empty module segment ("defaults::HKCU\...") would otherwise run every
    # module with no filter at all.
    if (-not $module) {
        Write-Host "Unknown task id: $Id"
        exit 1
    }
    $target = ''
    if ($parts.Count -ge 3) { $target = $parts[2] }

    if ($target -and $target -ne 'module') {
        Set-RegistryOnlyId -Id $target
    } else {
        Set-RegistryOnlyId -Id $null
    }

    Reset-RegistryResults
    $records = @(Invoke-DefaultsModules -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot -OnlyModule $module)
    Set-RegistryOnlyId -Id $null

    if ($records.Count -eq 0) {
        Write-Host "Unknown defaults module: $module"
        exit 1
    }

    $record = $records[0]
    if (-not $record.Enabled) {
        Write-Host "$module is disabled by the active profile"
        exit 1
    }
    if ($record.MissingFunc) {
        Write-Host "$module does not define an apply function"
        exit 1
    }
    if ($record.Error) {
        Write-Host "Failed: $($record.Error)"
        exit 1
    }
    # Set-RegistryValue/Remove-RegistryKey swallow their own errors into the
    # Failed bucket rather than throwing, so a real write failure would not
    # show up as $record.Error above.
    if ((Get-RegistryFailureCount) -gt 0) {
        Write-Host "Failed: $module reported a registry write failure"
        exit 1
    }
    # Same for an access-denied write: it lands in NeedsAdmin rather than
    # Failed, but the setting was not applied.
    if ((Get-RegistryResults).NeedsAdmin.Count -gt 0) {
        Write-Host "$module needs Administrator - restart Loadout elevated"
        exit 1
    }

    Write-Host "Applied $Id"
}

# --- debloat -----------------------------------------------------------------

# id -> @{ Name (row label); Group (Apply function's category) }
$script:DebloatGroups = [ordered]@{
    bloat     = 'AppX bloatware'
    xbox      = 'Xbox services'
    gamedvr   = 'Game DVR'
    gamebar   = 'Game Bar protocols'
    wol       = 'Wake-on-LAN'
    suggested = 'Suggested apps'
}

function Invoke-DebloatGroupById {
    param([string]$GroupId, [switch]$DryRun)

    switch ($GroupId) {
        'bloat'     { return Invoke-DebloatBloatGroup -DryRun:$DryRun }
        'xbox'      { return Invoke-DebloatXboxGroup -DryRun:$DryRun }
        'gamedvr'   { return Invoke-DebloatGameDvrGroup -DryRun:$DryRun }
        'gamebar'   { return Invoke-DebloatGameBarGroup -DryRun:$DryRun }
        'wol'       { return Invoke-DebloatWolGroup -DryRun:$DryRun }
        'suggested' { return Invoke-DebloatSuggestedGroup -DryRun:$DryRun }
        default     { return $null }
    }
}

function Get-DebloatStatusRows {
    param([hashtable]$ProfileConfig, [string]$RepoRoot)

    if (-not (Test-ProfileFlag -Profile $ProfileConfig -Flag 'PROFILE_DEBLOAT')) {
        return @()
    }

    Reset-RegistryResults

    $rows = @()
    foreach ($groupId in $script:DebloatGroups.Keys) {
        $status = Invoke-DebloatGroupById -GroupId $groupId -DryRun
        $needsAdmin = [bool]$status.NeedsAdmin
        $state = 'applied'
        if ($needsAdmin -and -not (Test-Administrator)) {
            $state = 'needs_admin'
        } elseif ($status.Failed -gt 0) {
            $state = 'failed'
        } elseif ($status.Pending -gt 0) {
            $state = 'pending'
        }

        $detail = "$($status.Pending) pending"
        if ($status.Failed -gt 0) { $detail = "$($status.Failed) failed" }

        $rows += New-TaskRow -Id "debloat:$groupId" -Section 'debloat' -Group 'Debloat' `
            -Name $script:DebloatGroups[$groupId] -State $state -Detail $detail
    }

    return $rows
}

function Invoke-DebloatApply {
    param([hashtable]$ProfileConfig, [string]$RepoRoot, [string]$Id)

    $groupId = $Id -replace '^debloat:', ''
    if (-not $script:DebloatGroups.Contains($groupId)) {
        Write-Host "Unknown debloat group: $Id"
        exit 1
    }

    Reset-RegistryResults

    $status = Invoke-DebloatGroupById -GroupId $groupId -DryRun:$false
    if ($status.Failed -gt 0) {
        Write-Host "Failed: $($status.Failed) item(s) in $groupId did not apply"
        exit 1
    }
    if ($status.NeedsAdmin) {
        Write-Host "$groupId needs Administrator - restart Loadout elevated"
        exit 1
    }

    Write-Host "Applied $Id"
}

# --- tasks-status / tasks-apply dispatch -------------------------------------

function Get-TaskStatusRows {
    param([string]$Section, [hashtable]$ProfileConfig, [string]$RepoRoot)

    switch ($Section) {
        'prereq'   { return Get-PrereqStatusRows }
        'dotfiles' { return Get-DotfilesStatusRowsForBridge -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot }
        'defaults' { return Get-DefaultsStatusRowsForBridge -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot }
        'debloat'  { return Get-DebloatStatusRows -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot }
        default    { throw "Unknown section: $Section" }
    }
}

function Invoke-TaskApply {
    param([string]$Section, [hashtable]$ProfileConfig, [string]$RepoRoot, [string]$Id)

    switch ($Section) {
        'prereq'   { Invoke-PrereqApply -Id $Id }
        'dotfiles' { Invoke-DotfilesApply -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot -Id $Id }
        'defaults' { Invoke-DefaultsApply -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot -Id $Id }
        'debloat'  { Invoke-DebloatApply -ProfileConfig $ProfileConfig -RepoRoot $RepoRoot -Id $Id }
        default {
            Write-Host "Unknown section: $Section"
            exit 1
        }
    }
}

# owner/repo from a pipe-delimited spec line
function Get-SpecRepo {
    param([string]$Spec)
    return ($Spec -split '\|')[0].Trim()
}

function Get-SpecsIn {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $specs = @()
    Get-ChildItem -LiteralPath $Dir -Filter '*.txt' | Sort-Object Name | ForEach-Object {
        $specs += @(Read-PackageList -FilePath $_.FullName)
    }
    return $specs
}

switch ($Verb) {
    'tasks-status' {
        $repoRoot = $Args2[0]
        $section = $Args2[1]
        $profileArg = $Args2[2]

        Import-TaskModules -RepoRoot $repoRoot
        # Dot-sourced (not `&`) at this top-level scope, not inside a helper
        # function - dot-sourcing inside a function only adds its definitions
        # to that function's own scope, which disappears on return. Doing it
        # here means Get-DebloatStatusRows (defined earlier, same script
        # scope) can see Invoke-Debloat*Group. The InvocationName guard at
        # the bottom of debloat.ps1 means this only defines functions; it
        # does not run a real removal pass.
        . (Join-Path $repoRoot 'platforms\windows\debloat.ps1')
        $config = Get-BridgeProfileConfig -ProfileName $profileArg

        # Every imported helper logs through Write-Host (the Information
        # stream, 6). Nothing on stdout but the one JSON array below.
        $rows = & { Get-TaskStatusRows -Section $section -ProfileConfig $config -RepoRoot $repoRoot } 6>$null

        ConvertTo-Json -InputObject @($rows) -Depth 4 -Compress
    }

    'tasks-apply' {
        $repoRoot = $Args2[0]
        $section = $Args2[1]
        $id = $Args2[2]
        $profileArg = $Args2[3]

        Import-TaskModules -RepoRoot $repoRoot
        # See the tasks-status case above for why this is dot-sourced here
        # rather than inside a helper function.
        . (Join-Path $repoRoot 'platforms\windows\debloat.ps1')
        $config = Get-BridgeProfileConfig -ProfileName $profileArg

        Invoke-TaskApply -Section $section -ProfileConfig $config -RepoRoot $repoRoot -Id $id
    }

    'status' {
        $repoRoot = $Args2[0]
        Import-OpsModules -RepoRoot $repoRoot
        $result = @()

        foreach ($spec in Get-SpecsIn (Join-Path $repoRoot 'config\packages\windows\github')) {
            $parsed = $null
            try { $parsed = ConvertFrom-GitHubPackageSpec -Spec $spec } catch { continue }
            $existing = Get-InstalledProgram -NamePattern $parsed.DisplayName
            $exe = ''
            $outdated = $false
            if ($null -ne $existing) {
                $exe = Get-ProgramExe -DisplayName $existing.Name
                $outdated = Test-GitHubOutdated -Spec $parsed -InstalledVersion $existing.Version
            }
            $result += [pscustomobject]@{
                id        = "github:$(Get-SpecRepo $spec)"
                installed = ($null -ne $existing)
                outdated  = $outdated
                exe       = $exe
            }
        }

        $nodeSpecs = @(Get-SpecsIn (Join-Path $repoRoot 'config\packages\windows\comfynodes'))
        if ($nodeSpecs.Count -gt 0) {
            $backends = @(Get-ComfyBackends)
            $customNodes = ''
            if ($backends.Count -gt 0) {
                $customNodes = Join-ComfyPath -Base $backends[0].BaseDir -Child 'custom_nodes'
            }
            foreach ($spec in $nodeSpecs) {
                $installed = $false
                if ($customNodes) {
                    $installed = Test-ComfyNodeInstalled -PackageSpec $spec -CustomNodesDir $customNodes
                }
                # No cheap way to know a node checkout is behind without fetching.
                $result += [pscustomobject]@{
                    id        = "comfynode:$(Get-SpecRepo $spec)"
                    installed = $installed
                    outdated  = $false
                    exe       = ''
                }
            }
        }

        # @() keeps a single entry from serialising as a bare object
        ConvertTo-Json -InputObject @($result) -Depth 4 -Compress
    }

    { $_ -in 'install', 'update' } {
        # -Force is the repo's upgrade path: it reinstalls a GitHub release at
        # the latest tag and fast-forwards a node checkout.
        $force = ($Verb -eq 'update')
        $repoRoot = $Args2[0]
        $kind = $Args2[1]
        $spec = $Args2[2]
        Import-OpsModules -RepoRoot $repoRoot

        if ($kind -eq 'github') {
            Install-GitHubRelease -PackageSpec $spec -Force:$force | Out-Null
        } else {
            $backends = @(Get-ComfyBackends)
            if ($backends.Count -eq 0) {
                Write-Host 'No ComfyUI install found - launch Comfy Desktop once, then retry'
                exit 1
            }
            foreach ($backend in $backends) {
                Install-ComfyNode -PackageSpec $spec -BaseDir $backend.BaseDir -Force:$force | Out-Null
            }
        }

        if ((Get-FailureCount) -gt 0) { exit 1 }
    }

    'uninstall' {
        $repoRoot = $Args2[0]
        $kind = $Args2[1]
        $spec = $Args2[2]
        Import-OpsModules -RepoRoot $repoRoot

        if ($kind -eq 'github') {
            $parsed = ConvertFrom-GitHubPackageSpec -Spec $spec
            $existing = Get-InstalledProgram -NamePattern $parsed.DisplayName
            if ($null -eq $existing) {
                Write-Host "$($parsed.DisplayName) is not in Add/Remove Programs"
                exit 0
            }

            $props = Get-ProgramProps -DisplayName $existing.Name
            $command = ''
            if ($null -ne $props) {
                $command = [string]$props.QuietUninstallString
                if (-not $command) { $command = [string]$props.UninstallString }
            }
            if (-not $command) {
                Write-Host "No uninstall string recorded for $($existing.Name)"
                exit 1
            }

            $code = Invoke-UninstallString -Command $command -QuietArgs $parsed.InstallArgs
            if ($code -ne 0) {
                Write-Host "Uninstaller exited $(Format-ExitCode -Code $code)"
                exit 1
            }
            Write-Host "Removed $($existing.Name)"
        } else {
            $parsed = ConvertFrom-ComfyNodeSpec -Spec $spec
            $backends = @(Get-ComfyBackends)
            if ($backends.Count -eq 0) {
                Write-Host 'No ComfyUI install found'
                exit 1
            }
            foreach ($backend in $backends) {
                $customNodes = Join-ComfyPath -Base $backend.BaseDir -Child 'custom_nodes'
                $target = Join-ComfyPath -Base $customNodes -Child $parsed.Directory
                if (Test-ComfyPathReachable -Path $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                    Write-Host "Removed $target"
                } else {
                    Write-Host "Not present: $target"
                }
            }
            Write-Host 'Restart Comfy Desktop to unload the node'
        }
    }

    'launch' {
        # -FilePath with a literal path: nothing here is re-parsed as script,
        # so spaces and metacharacters in the path are inert.
        Start-Process -FilePath $Args2[0]
    }

    'open' {
        $url = $Args2[0]
        # The shell handler will run anything; only web URLs get through.
        if ($url -notmatch '^https?://') {
            Write-Host "Refusing to open $url"
            exit 1
        }
        Start-Process -FilePath $url
    }

    'icon' {
        try {
            Add-Type -AssemblyName System.Drawing
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Args2[0])
            if ($null -eq $icon) { exit 1 }
            $icon.ToBitmap().Save($Args2[1], [System.Drawing.Imaging.ImageFormat]::Png)
        } catch {
            Write-Host "Failed to extract icon: $_"
            exit 1
        }
    }
}
