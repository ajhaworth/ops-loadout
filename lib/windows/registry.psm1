# registry.psm1 - Idempotent, dry-run aware registry helpers
#
# Shared by platforms/windows/defaults/*.ps1 and debloat.ps1 so that every
# registry write reports consistently and re-runs cleanly.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

$script:Results = @{
    Changed = @()
    Skipped = @()
    Failed  = @()
}

function Reset-RegistryResults {
    $script:Results = @{
        Changed = @()
        Skipped = @()
        Failed  = @()
    }
}

function Get-RegistryResults {
    return $script:Results
}

function Get-RegistryFailureCount {
    return $script:Results.Failed.Count
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

    try {
        $current = Get-RegistryValue -Path $Path -Name $Name

        # Labels state the outcome ("Show file extensions"), so the raw value is
        # left out here - "Show file extensions = 0" reads as the opposite of
        # what HideFileExt=0 actually does. Dry-run still prints it, along with
        # the key, because that output exists for verification.
        if ($null -ne $current -and "$current" -eq "$Value") {
            Write-Skip "$display already set"
            $script:Results.Skipped += $display
            return $true
        }

        if ($DryRun) {
            Write-DryRun "Would set $display ($Path\$Name = $Value)"
            return $true
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Success $display
        $script:Results.Changed += $display
        return $true
    } catch {
        if (Test-AccessDeniedError -ErrorRecord $_) {
            Write-Skip "$display needs Administrator"
            $script:Results.Skipped += $display
            return $true
        }

        Write-Warn "Failed to set ${display}: $_"
        $script:Results.Failed += $display
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

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Skip "$display not present"
        $script:Results.Skipped += $display
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would remove: $display"
        return $true
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Success "Removed $display"
        $script:Results.Changed += $display
        return $true
    } catch {
        if (Test-AccessDeniedError -ErrorRecord $_) {
            Write-Skip "Removing $display needs Administrator"
            $script:Results.Skipped += $display
            return $true
        }

        Write-Warn "Failed to remove ${display}: $_"
        $script:Results.Failed += $display
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

Export-ModuleMember -Function @(
    'Reset-RegistryResults',
    'Get-RegistryResults',
    'Get-RegistryFailureCount',
    'Get-RegistryValue',
    'Test-AccessDeniedError',
    'Set-RegistryValue',
    'Remove-RegistryKey',
    'Set-RegistryValueSet'
)
