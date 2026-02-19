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
if ($contextRemaining) { $status += " | context:$contextRemaining%" }

Write-Output $status
