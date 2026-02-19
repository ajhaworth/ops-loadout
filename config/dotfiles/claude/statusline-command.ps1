# Claude Code statusline command for Windows
$input = $input | ConvertFrom-Json
$model = $input.model.display_name
$cwd = $input.workspace.current_dir
$contextRemaining = $input.context_window.remaining_percentage

Push-Location $cwd -ErrorAction SilentlyContinue
$gitBranch = git branch --show-current 2>$null

Pop-Location -ErrorAction SilentlyContinue

$dirDisplay = $cwd -replace [regex]::Escape($env:USERPROFILE), '~'
$status = "$model | $dirDisplay"
if ($gitBranch) { $status += " | git:$gitBranch" }
if ($contextRemaining) {
    $barWidth = 10
    $filled = [math]::Floor($contextRemaining * $barWidth / 100)
    $empty = $barWidth - $filled

    $filledBar = "$([char]0x2588)" * $filled
    $emptyBar = "$([char]0x2591)" * $empty

    $status += " | ${filledBar}${emptyBar} ${contextRemaining}%"
}

Write-Output $status
