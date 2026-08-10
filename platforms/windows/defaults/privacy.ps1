# privacy.ps1 - Advertising, telemetry and activity history
#
# The HKLM settings require Administrator. Without it they are reported as
# failures and the rest still applies.

function Apply-Privacy {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $advertising = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    $privacy     = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"

    $userSettings = @(
        @{ Path = $advertising; Name = 'Enabled';                                     Value = 0; Label = 'Disable advertising ID' }
        @{ Path = $privacy;     Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0; Label = 'Disable tailored experiences' }
    )

    Set-RegistryValueSet -Settings $userSettings -DryRun:$DryRun

    if (-not (Test-Administrator)) {
        Write-Skip "Telemetry and activity history need Administrator"
        return
    }

    $dataCollection = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    $system         = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"

    # AllowTelemetry 0 (Security) is honoured on Enterprise/Education only;
    # 1 (Required/Basic) is the lowest setting that actually applies here.
    $machineSettings = @(
        @{ Path = $dataCollection; Name = 'AllowTelemetry';       Value = 1; Label = 'Telemetry to Required only' }
        @{ Path = $system;         Name = 'EnableActivityFeed';   Value = 0; Label = 'Disable activity feed' }
        @{ Path = $system;         Name = 'PublishUserActivities'; Value = 0; Label = 'Disable publishing activities' }
        @{ Path = $system;         Name = 'UploadUserActivities';  Value = 0; Label = 'Disable uploading activities' }
    )

    Set-RegistryValueSet -Settings $machineSettings -DryRun:$DryRun
}
