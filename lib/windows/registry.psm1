# registry.psm1 - Idempotent, dry-run aware registry helpers
#
# Shared by platforms/windows/defaults/*.ps1 and debloat.ps1 so that every
# registry write reports consistently and re-runs cleanly.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Every bucket holds @{ Id; Label; Detail } objects. Id is the stable
# "$Path\$Name" (or bare $Path for Remove-RegistryKey) that the launcher's
# Setup tab uses to target a single setting; Label/Detail are what the CLI
# prints.
function New-RegistryResultsBag {
    return @{
        Changed    = @()
        Skipped    = @()
        Pending    = @()
        Failed     = @()
        NeedsAdmin = @()
    }
}

$script:Results = New-RegistryResultsBag

# When set, Set-RegistryValue/Remove-RegistryKey act on nothing but this one
# id and return without recording anything else. Used by the launcher's
# tasks-apply to turn a whole defaults module's settings into a single-item
# write, by re-running the module and letting every other setting no-op.
$script:RegistryOnlyId = $null

function Reset-RegistryResults {
    $script:Results = New-RegistryResultsBag
}

function Get-RegistryResults {
    return $script:Results
}

function Get-RegistryFailureCount {
    return $script:Results.Failed.Count
}

# $Id = $null/'' clears the filter so every setting is acted on again.
function Set-RegistryOnlyId {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Id
    )
    $script:RegistryOnlyId = $Id
}

function Get-RegistryOnlyId {
    return $script:RegistryOnlyId
}

# True when an error is the registry provider refusing access.
#
# Policy branches such as HKCU:\SOFTWARE\Policies are writable only with an
# administrator token even though they live under HKCU, so a non-elevated run
# hits this on settings that are otherwise per-user. That is a precondition the
# run cannot satisfy, not a broken setting - report it like the other
# admin-gated settings instead of as a failure.
function Test-AccessDeniedError {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $ErrorRecord
    )

    if ($null -eq $ErrorRecord) { return $false }

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.UnauthorizedAccessException] -or
            $exception -is [System.Security.SecurityException]) {
            return $true
        }
        $exception = $exception.InnerException
    }

    return $false
}

# Read a value, returning $null when the key or value is absent.
function Get-RegistryValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    # Get-ItemProperty returns a PSCustomObject; pull the single property off it
    $prop = $item.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

# Set a registry value if it differs from the desired state.
#
# Returns $true when the value is (or ends up) correct, $false on failure.
function Set-RegistryValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        $Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Type = 'DWord',
        [string]$Label = '',
        [switch]$DryRun
    )

    $display = $Label
    if (-not $display) {
        $display = $Name
    }

    $id = "$Path\$Name"
    if ($script:RegistryOnlyId -and $id -ne $script:RegistryOnlyId) {
        return $true
    }

    try {
        $current = Get-RegistryValue -Path $Path -Name $Name

        # Labels state the outcome ("Show file extensions"), so the raw value is
        # left out here - "Show file extensions = 0" reads as the opposite of
        # what HideFileExt=0 actually does. Dry-run still prints it, along with
        # the key, because that output exists for verification.
        if ($null -ne $current -and "$current" -eq "$Value") {
            Write-Skip "$display already set"
            $script:Results.Skipped += @{ Id = $id; Label = $display; Detail = "already set to $current" }
            return $true
        }

        if ($DryRun) {
            Write-DryRun "Would set $display ($Path\$Name = $Value)"
            $detail = "would set to $Value"
            if ($null -ne $current) { $detail = "currently $current, want $Value" }
            $script:Results.Pending += @{ Id = $id; Label = $display; Detail = $detail }
            return $true
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Success $display
        $detail = "set to $Value"
        if ($null -ne $current) { $detail = "changed from $current to $Value" }
        $script:Results.Changed += @{ Id = $id; Label = $display; Detail = $detail }
        return $true
    } catch {
        if (Test-AccessDeniedError -ErrorRecord $_) {
            Write-Skip "$display needs Administrator"
            $script:Results.NeedsAdmin += @{ Id = $id; Label = $display; Detail = 'needs Administrator' }
            return $true
        }

        Write-Warn "Failed to set ${display}: $_"
        $script:Results.Failed += @{ Id = $id; Label = $display; Detail = "$_" }
        return $false
    }
}

# Remove a registry key and everything under it, if present.
function Remove-RegistryKey {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Label = '',
        [switch]$DryRun
    )

    $display = $Label
    if (-not $display) {
        $display = $Path
    }

    $id = $Path
    if ($script:RegistryOnlyId -and $id -ne $script:RegistryOnlyId) {
        return $true
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Skip "$display not present"
        $script:Results.Skipped += @{ Id = $id; Label = $display; Detail = 'not present' }
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would remove: $display"
        $script:Results.Pending += @{ Id = $id; Label = $display; Detail = 'would remove' }
        return $true
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Success "Removed $display"
        $script:Results.Changed += @{ Id = $id; Label = $display; Detail = 'removed' }
        return $true
    } catch {
        if (Test-AccessDeniedError -ErrorRecord $_) {
            Write-Skip "Removing $display needs Administrator"
            $script:Results.NeedsAdmin += @{ Id = $id; Label = $display; Detail = 'needs Administrator' }
            return $true
        }

        Write-Warn "Failed to remove ${display}: $_"
        $script:Results.Failed += @{ Id = $id; Label = $display; Detail = "$_" }
        return $false
    }
}

# A tracked step that is not a registry write: the caller supplies a -Check
# that reports whether the desired state already holds and an -Apply that
# establishes it. Windows counterpart of lib/tasks.sh `defaults_hook` - it
# records into the same buckets and honours the same OnlyId filter, so
# non-registry settings show up as ordinary rows in the launcher's Setup tab
# instead of vanishing from it.
#
# -Check runs first, so an already-correct step reports Skipped even without an
# administrator token; -RequiresAdmin only decides what a step that *would*
# change something reports when the run is not elevated.
function Invoke-TrackedStep {
    param(
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [scriptblock]$Check,
        [Parameter(Mandatory)]
        [scriptblock]$Apply,
        [switch]$RequiresAdmin,
        [switch]$DryRun
    )

    if ($script:RegistryOnlyId -and $Id -ne $script:RegistryOnlyId) {
        return $true
    }

    try {
        if (& $Check) {
            Write-Skip "$Label already set"
            $script:Results.Skipped += @{ Id = $Id; Label = $Label; Detail = 'already set' }
            return $true
        }

        if ($RequiresAdmin -and -not (Test-Administrator)) {
            Write-Skip "$Label needs Administrator"
            $script:Results.NeedsAdmin += @{ Id = $Id; Label = $Label; Detail = 'needs Administrator' }
            return $true
        }

        if ($DryRun) {
            Write-DryRun "Would apply: $Label"
            $script:Results.Pending += @{ Id = $Id; Label = $Label; Detail = 'would apply' }
            return $true
        }

        & $Apply | Out-Null
        Write-Success $Label
        $script:Results.Changed += @{ Id = $Id; Label = $Label; Detail = 'applied' }
        return $true
    } catch {
        if (Test-AccessDeniedError -ErrorRecord $_) {
            Write-Skip "$Label needs Administrator"
            $script:Results.NeedsAdmin += @{ Id = $Id; Label = $Label; Detail = 'needs Administrator' }
            return $true
        }

        Write-Warn "Failed to apply ${Label}: $_"
        $script:Results.Failed += @{ Id = $Id; Label = $Label; Detail = "$_" }
        return $false
    }
}

# Apply a list of @{ Path=; Name=; Value=; Type=; Label= } hashtables.
function Set-RegistryValueSet {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Settings,
        [switch]$DryRun
    )

    foreach ($setting in $Settings) {
        $type = 'DWord'
        if ($setting.ContainsKey('Type')) {
            $type = $setting['Type']
        }
        $label = ''
        if ($setting.ContainsKey('Label')) {
            $label = $setting['Label']
        }

        Set-RegistryValue -Path $setting['Path'] -Name $setting['Name'] `
            -Value $setting['Value'] -Type $type -Label $label -DryRun:$DryRun | Out-Null
    }
}

# Discover platforms\windows\defaults\*.ps1, gate each by its DEFAULTS_<NAME>
# profile flag, dot-source it and invoke Apply-<Name>. Shared by defaults.ps1
# (the CLI) and bridge.ps1 (the launcher's Setup tab) so there is exactly one
# place that decides which modules run and how they are gated.
#
# Returns one record per discovered file:
#   @{ Module; VarName; Enabled; FuncName; MissingFunc; Ran; Error; RegistryResults }
# RegistryResults is $null unless the module actually ran; when it ran, it
# holds only the entries *this* module added (a diff against the results
# already accumulated), so callers can tell which module wrote what while a
# single Reset-RegistryResults/Get-RegistryResults pair still reports the
# aggregate across every module that ran.
function Invoke-DefaultsModules {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ProfileConfig,
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [switch]$DryRun,
        # When set, only this module (by file base name) is considered.
        [string]$OnlyModule = '',
        # Print the per-module header/skip/failure narration inline. The CLI
        # wants it; the launcher does not (bridge.ps1 reads the records and
        # renders its own rows). It has to happen here rather than in a second
        # loop afterwards, or every module's own output lands before the
        # headers it belongs under.
        [switch]$Narrate
    )

    $defaultsDir = Join-Path $RepoRoot "platforms\windows\defaults"
    if (-not (Test-Path -LiteralPath $defaultsDir)) {
        return @()
    }

    $records = @()
    $files = @(Get-ChildItem -LiteralPath $defaultsDir -Filter "*.ps1" | Sort-Object Name)

    foreach ($file in $files) {
        $category = $file.BaseName
        if ($OnlyModule -and $category -ne $OnlyModule) { continue }

        $varName = Get-CategoryVar -Prefix 'DEFAULTS' -Category $category
        $enabled = Test-ProfileFlag -Profile $ProfileConfig -Flag $varName

        $record = @{
            Module          = $category
            VarName         = $varName
            Enabled         = $enabled
            FuncName        = $null
            MissingFunc     = $false
            Ran             = $false
            Error           = $null
            RegistryResults = $null
        }

        if (-not $enabled) {
            if ($Narrate) { Write-Skip "$category (disabled by $varName)" }
            $records += $record
            continue
        }

        if ($Narrate) { Write-Step $category }

        . $file.FullName

        $funcName = Get-ApplyFunctionName -BaseName $category
        $record.FuncName = $funcName
        $func = Get-Command -Name $funcName -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $func) {
            $record.MissingFunc = $true
            if ($Narrate) { Write-Warn "$category.ps1 does not define $funcName - skipping" }
            $records += $record
            continue
        }

        $before = Get-RegistryResults
        $counts = @{
            Changed    = $before.Changed.Count
            Skipped    = $before.Skipped.Count
            Pending    = $before.Pending.Count
            Failed     = $before.Failed.Count
            NeedsAdmin = $before.NeedsAdmin.Count
        }

        try {
            # Out-Null: a module's stray pipeline output is not this function's
            # return value.
            & $funcName -ProfileConfig $ProfileConfig -DryRun:$DryRun | Out-Null
        } catch {
            $record.Error = $_
            if ($Narrate) { Write-Err "$category failed: $_" }
        }
        $record.Ran = $true

        $after = Get-RegistryResults
        $record.RegistryResults = @{
            Changed    = @($after.Changed    | Select-Object -Skip $counts.Changed)
            Skipped    = @($after.Skipped    | Select-Object -Skip $counts.Skipped)
            Pending    = @($after.Pending    | Select-Object -Skip $counts.Pending)
            Failed     = @($after.Failed     | Select-Object -Skip $counts.Failed)
            NeedsAdmin = @($after.NeedsAdmin  | Select-Object -Skip $counts.NeedsAdmin)
        }

        $records += $record
    }

    return $records
}

Export-ModuleMember -Function @(
    'Reset-RegistryResults',
    'Get-RegistryResults',
    'Get-RegistryFailureCount',
    'Set-RegistryOnlyId',
    'Get-RegistryOnlyId',
    'Get-RegistryValue',
    'Test-AccessDeniedError',
    'Set-RegistryValue',
    'Remove-RegistryKey',
    'Set-RegistryValueSet',
    'Invoke-TrackedStep',
    'Invoke-DefaultsModules'
)
