param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuntimeDir = if ($env:CLAUDE_LOCAL_RUNTIME_DIR) { $env:CLAUDE_LOCAL_RUNTIME_DIR } else { Join-Path $RootDir ".claude-local-runtime" }
$RootEnvFile = if ($env:CLAUDE_LOCAL_ENV_FILE) { $env:CLAUDE_LOCAL_ENV_FILE } else { Join-Path $RootDir "claude-local.env" }
$RuntimeEnvFile = Join-Path $RuntimeDir "env"
$LegacyEnvFile = Join-Path $RootDir ".ccsmap-runtime\\env"
$SelectedEnvFile = $null

function Write-DefaultEnv {
  @"
# Claude Local API configuration
#
# File to edit:
#   claude-local.env
#
# Kimi example:
CLAUDE_LOCAL_PROVIDER=kimi
ANTHROPIC_AUTH_TOKEN=paste_your_api_key_here
#
# Optional advanced overrides:
ANTHROPIC_BASE_URL=
ANTHROPIC_MODEL=
ANTHROPIC_SMALL_FAST_MODEL=
"@ | Set-Content -Path $RootEnvFile -NoNewline -Encoding UTF8
}

function Import-EnvFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  Get-Content -Path $Path | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line.StartsWith("#")) { return }

    if ($line -match "^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$") {
      $name = $matches[1]
      $value = $matches[2].Trim()
      if (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
      ) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

if ($CliArgs.Count -gt 0 -and $CliArgs[0] -eq "--init-env") {
  if (Test-Path -LiteralPath $RootEnvFile) {
    Write-Output "Already exists: $RootEnvFile"
  } else {
    Write-DefaultEnv
    Write-Output "Created: $RootEnvFile"
    Write-Output "Open this file and replace ANTHROPIC_AUTH_TOKEN with your real API key."
  }
  exit 0
}

@("home", "xdg-config", "xdg-data", "xdg-state", "tmp") | ForEach-Object {
  New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeDir $_) | Out-Null
}

[Environment]::SetEnvironmentVariable("HOME", (Join-Path $RuntimeDir "home"), "Process")
[Environment]::SetEnvironmentVariable("XDG_CONFIG_HOME", (Join-Path $RuntimeDir "xdg-config"), "Process")
[Environment]::SetEnvironmentVariable("XDG_DATA_HOME", (Join-Path $RuntimeDir "xdg-data"), "Process")
[Environment]::SetEnvironmentVariable("XDG_STATE_HOME", (Join-Path $RuntimeDir "xdg-state"), "Process")
[Environment]::SetEnvironmentVariable("TMPDIR", (Join-Path $RuntimeDir "tmp"), "Process")

if (Test-Path -LiteralPath $RootEnvFile) {
  $SelectedEnvFile = $RootEnvFile
  Import-EnvFile -Path $RootEnvFile
} elseif (Test-Path -LiteralPath $RuntimeEnvFile) {
  $SelectedEnvFile = $RuntimeEnvFile
  Import-EnvFile -Path $RuntimeEnvFile
} elseif (Test-Path -LiteralPath $LegacyEnvFile) {
  $SelectedEnvFile = $LegacyEnvFile
  Import-EnvFile -Path $LegacyEnvFile
}

if (-not $SelectedEnvFile) {
  Write-DefaultEnv
  Write-Error @"
Created API config file:
  $RootEnvFile

Open this file and replace:
  ANTHROPIC_AUTH_TOKEN=paste_your_api_key_here

Then run:
  .\claude-local.ps1 --bare
"@
  exit 1
}

if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
  [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", $env:ANTHROPIC_API_KEY, "Process")
}

switch -Regex ($env:CLAUDE_LOCAL_PROVIDER) {
  "^(kimi|moonshot)$" {
    if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_BASE_URL)) {
      [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "https://api.moonshot.cn/anthropic", "Process")
    }
    if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_MODEL)) {
      [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", "kimi-k2-0905-preview", "Process")
    }
    if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_SMALL_FAST_MODEL)) {
      [Environment]::SetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", "kimi-k2-turbo-preview", "Process")
    }
  }
}

if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
  Write-Error @"
Missing ANTHROPIC_AUTH_TOKEN in $SelectedEnvFile

Example:
  CLAUDE_LOCAL_PROVIDER=kimi
  ANTHROPIC_AUTH_TOKEN=your_token_here
"@
  exit 1
}

if ($env:ANTHROPIC_AUTH_TOKEN -eq "paste_your_api_key_here") {
  Write-Error @"
Edit this file first:
  $SelectedEnvFile

Replace:
  ANTHROPIC_AUTH_TOKEN=paste_your_api_key_here

With your real API key, then run .\claude-local.ps1 --bare again.
"@
  exit 1
}

$NodePath = $null
try {
  $NodePath = (Get-Command node -ErrorAction Stop).Source
} catch {
  $KnownNodePath = "C:\Program Files\nodejs\node.exe"
  if (Test-Path -LiteralPath $KnownNodePath) {
    $NodePath = $KnownNodePath
  }
}

if (-not $NodePath) {
  Write-Error "Node.js is required (v18+). Install Node.js and run again."
  exit 1
}

$EffectiveCliArgs = @($CliArgs)
$hasThinkingFlag = $false
foreach ($arg in $EffectiveCliArgs) {
  if ($arg -eq "--thinking" -or $arg.StartsWith("--thinking=")) {
    $hasThinkingFlag = $true
    break
  }
}

$provider = if ($env:CLAUDE_LOCAL_PROVIDER) { $env:CLAUDE_LOCAL_PROVIDER.ToLowerInvariant() } else { "" }
$baseUrl = if ($env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL.ToLowerInvariant() } else { "" }
$useSiliconFlow = ($provider -eq "siliconflow") -or $baseUrl.Contains("siliconflow.cn")

if ($useSiliconFlow -and -not $hasThinkingFlag) {
  $EffectiveCliArgs += @("--thinking", "disabled")
}

& $NodePath (Join-Path $RootDir "package\\cli.js") @EffectiveCliArgs
exit $LASTEXITCODE
