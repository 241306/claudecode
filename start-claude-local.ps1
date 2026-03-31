param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $scriptDir

$historyPath = Join-Path $env:USERPROFILE ".claude\history.jsonl"
$currentProject = (Get-Location).Path
$resumeSessionId = $null

if (Test-Path -LiteralPath $historyPath) {
  $entries = @()
  Get-Content -Path $historyPath | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { return }
    try {
      $entries += ($_ | ConvertFrom-Json)
    } catch {
      # Ignore malformed lines.
    }
  }

  $projectEntry = $entries |
    Where-Object {
      $_.sessionId -and $_.timestamp -and $_.project -and
      $_.project.ToLowerInvariant() -eq $currentProject.ToLowerInvariant()
    } |
    Sort-Object timestamp -Descending |
    Select-Object -First 1

  if ($projectEntry) {
    $lastDisplay = [string]$projectEntry.display
    $lastDisplayLower = $lastDisplay.ToLowerInvariant()
    $clearIntent =
      $lastDisplayLower -eq "/clear" -or
      $lastDisplayLower -eq "clear" -or
      $lastDisplay.Contains("清空聊天记录")

    if (-not $clearIntent) {
      $resumeSessionId = [string]$projectEntry.sessionId
    } else {
      Write-Host "Last action was clear. Starting a new session instead of resuming."
    }
  }
}

$langPrompt = "Always reply in Simplified Chinese unless I explicitly ask for another language."
$args = @("--thinking", "disabled", "--append-system-prompt", $langPrompt)

Write-Host "Project: $currentProject"
if ($resumeSessionId) {
  Write-Host "Resuming session: $resumeSessionId"
  $args += @("--resume", $resumeSessionId)
} else {
  Write-Host "No previous session found for this project. Starting a new session."
}

& (Join-Path $scriptDir "claude-local.ps1") -CliArgs $args
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0 -and $resumeSessionId) {
  Write-Host ""
  Write-Host "Resume failed. Starting a new session..."
  & (Join-Path $scriptDir "claude-local.ps1") -CliArgs @("--thinking", "disabled", "--append-system-prompt", $langPrompt)
  $exitCode = $LASTEXITCODE
}

if ($exitCode -ne 0) {
  Write-Host ""
  Write-Host "Claude Local failed to start. Exit code: $exitCode"
}

exit $exitCode
