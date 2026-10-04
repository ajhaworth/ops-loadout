# wallpaper.ps1 - Desktop wallpaper from config\wallpapers\windows.jpg

function Apply-Wallpaper {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $image = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\config\wallpapers\windows.jpg'))

    Invoke-TrackedStep -Id 'wallpaper' -Label 'Desktop wallpaper from the repo' -DryRun:$DryRun `
        -Check { (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper -eq $image } `
        -Apply {
            if (-not ('OpsLoadout.Wallpaper' -as [type])) {
                Add-Type -Namespace OpsLoadout -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
            }
            # SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
            if (-not [OpsLoadout.Wallpaper]::SystemParametersInfo(0x14, 0, $image, 3)) {
                throw "SystemParametersInfo failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        } | Out-Null
}
