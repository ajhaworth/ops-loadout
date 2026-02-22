# Claude Code statusline command for Windows
$input = $input | ConvertFrom-Json
$model = $input.model.display_name
$cwd = $input.workspace.current_dir
$contextRemaining = $input.context_window.remaining_percentage

Push-Location $cwd -ErrorAction SilentlyContinue
$gitBranch = git branch --show-current 2>$null

$gitDiff = ""
if ($gitBranch) {
    $diffStats = git diff --numstat HEAD 2>$null
    if ($diffStats) {
        $additions = 0
        $deletions = 0
        $diffStats | ForEach-Object {
            $parts = $_ -split '\s+'
            if ($parts[0] -match '^\d+$') { $additions += [int]$parts[0] }
            if ($parts[1] -match '^\d+$') { $deletions += [int]$parts[1] }
        }
        if ($additions -gt 0 -or $deletions -gt 0) {
            $gitDiff = " +$additions -$deletions"
        }
    }
}

Pop-Location -ErrorAction SilentlyContinue

$dirDisplay = $cwd -replace [regex]::Escape($env:USERPROFILE), '~'
$status = "$model | $dirDisplay"
if ($gitBranch) { $status += " | git:$gitBranch$gitDiff" }
if ($contextRemaining) {
    $barWidth = 10
    $filled = [math]::Floor($contextRemaining * $barWidth / 100)
    $empty = $barWidth - $filled

    $filledBar = "$([char]0x2588)" * $filled
    $emptyBar = "$([char]0x2591)" * $empty

    $status += " | ${filledBar}${emptyBar} ${contextRemaining}%"
}

Write-Output $status
