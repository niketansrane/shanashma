# Install ado-flow plugin into ~/.claude/
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$PluginSrc = Join-Path $ScriptDir "plugins\ado-flow"

Write-Host "Installing ado-flow plugin..."

# Copy skills
$SkillsDest = Join-Path $ClaudeDir "skills\ado-flow"
New-Item -ItemType Directory -Path (Join-Path $ClaudeDir "skills") -Force | Out-Null
if (Test-Path $SkillsDest) { Remove-Item -Recurse -Force $SkillsDest }
Copy-Item -Recurse (Join-Path $PluginSrc "skills\ado-flow") $SkillsDest
Write-Host "  Installed skill: ado-flow"

# Copy commands
$CommandsDest = Join-Path $ClaudeDir "commands\adoflow"
New-Item -ItemType Directory -Path (Join-Path $ClaudeDir "commands") -Force | Out-Null
if (Test-Path $CommandsDest) { Remove-Item -Recurse -Force $CommandsDest }
Copy-Item -Recurse (Join-Path $PluginSrc "commands\adoflow") $CommandsDest
Write-Host "  Installed command: adoflow-workitems"
Write-Host "  Installed command: adoflow-prs"
Write-Host "  Installed command: adoflow-pipelines"

Write-Host ""
Write-Host "Done! Restart Claude Code, then use:"
Write-Host "  /adoflow-workitems"
Write-Host "  /adoflow-prs"
Write-Host "  /adoflow-pipelines"
