<#
  Backlog triage by forking each project's own conversation (PowerShell 7+).

  For every project that has open cc-remind items, this forks that project's latest Claude Code
  conversation headless (`claude -p --resume <id> --fork-session`) and asks it, read-only, which of its
  own open items are already done, no longer needed, or still open. The original conversation is untouched.

  Usage:
    pwsh -File review\run-review.ps1                 # every project with open items addressed to it
    pwsh -File review\run-review.ps1 my-app api      # only projects whose folder name matches
    pwsh -File review\run-review.ps1 -DryRun         # show what would run

  Optional config: review.config.json in the cc-remind data folder (see review.config.example.json).
  Reports are written to <data folder>\review\<project>.md. Each run is a full agent session and uses quota.
  `cc-remind` must be on PATH for the child sessions (install\install.ps1 -AddToPath).
#>
param([switch]$DryRun, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Only)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'run-review.ps1 needs PowerShell 7+ (pwsh).' }
$Repo = Split-Path $PSScriptRoot -Parent
$paths = (& node "$Repo\cc.mjs" paths) | ConvertFrom-Json
$cfgFile = Join-Path $paths.data 'review.config.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$model = if ($cfg.model) { [string]$cfg.model } else { 'sonnet' }
$maxTurns = if ($cfg.maxTurns) { [string]$cfg.maxTurns } else { '60' }
$parallel = if ($cfg.parallel) { [int]$cfg.parallel } else { 4 }
$timeoutMin = if ($cfg.timeoutMinutes) { [int]$cfg.timeoutMinutes } else { 25 }
$claude = if ($cfg.claudePath) { [string]$cfg.claudePath } else { (Get-Command claude -ErrorAction Stop).Source }
$out = Join-Path $paths.data 'review'
New-Item -ItemType Directory -Force $out | Out-Null

$scan = (& node "$Repo\cc.mjs" scan) | ConvertFrom-Json
$norm = { param($p) ([string]$p).TrimEnd('\', '/').ToLowerInvariant() }
$leaf = { param($p) Split-Path ([string]$p).TrimEnd('\', '/') -Leaf }

$projects = if ($cfg.projects) { @($cfg.projects | ForEach-Object { [pscustomobject]@{ name = $(if ($_.name) { $_.name } else { & $leaf $_.cwd }); cwd = $_.cwd } }) }
else {
  @($scan.items | Where-Object { -not $_.doneAt -and $_.to } | ForEach-Object { $_.to } | Sort-Object -Unique { & $norm $_ } |
    ForEach-Object { [pscustomobject]@{ name = (& $leaf $_); cwd = $_ } })
}
if ($Only) { $projects = @($projects | Where-Object { $p = $_; $Only | Where-Object { $p.name -like "*$_*" } }) }

$runs = foreach ($p in $projects) {
  if (-not (Test-Path -LiteralPath $p.cwd)) { Write-Warning "skip $($p.name): folder not found"; continue }
  $latest = $scan.sessions | Where-Object { (& $norm $_.cwd) -eq (& $norm $p.cwd) } | Select-Object -First 1
  [pscustomobject]@{ name = $p.name; cwd = $p.cwd; resume = $(if ($latest) { $latest.id } else { $null }) }
}
if (-not $runs) { 'nothing to review'; return }
$runs | Format-Table name, resume, cwd -AutoSize | Out-String | Write-Host
if ($DryRun) { return }

$prompt = Get-Content (Join-Path $PSScriptRoot 'prompt.txt') -Raw -Encoding utf8
$cfgDir = $paths.claudeConfigDir
"starting $(@($runs).Count) reviews ($parallel at a time)..."

$runs | ForEach-Object -ThrottleLimit $parallel -Parallel {
  $r = $_
  $psi = [Diagnostics.ProcessStartInfo]::new($using:claude)
  foreach ($a in @('-p', $using:prompt, '--model', $using:model, '--permission-mode', 'dontAsk', '--max-turns', $using:maxTurns, '--output-format', 'text',
                   '--allowedTools', 'Read', 'Grep', 'Glob', 'Bash(cc-remind:*)', 'Bash(git status:*)', 'Bash(git log:*)', 'Bash(git remote:*)', 'Bash(ls:*)',
                   'PowerShell(cc-remind:*)', 'PowerShell(git status:*)', 'PowerShell(git log:*)', 'PowerShell(git remote:*)',
                   '--disallowedTools', 'Edit', 'Write', 'NotebookEdit', 'WebFetch')) { $psi.ArgumentList.Add($a) }
  if ($r.resume) { $psi.ArgumentList.Add('--resume'); $psi.ArgumentList.Add($r.resume); $psi.ArgumentList.Add('--fork-session') }
  $psi.WorkingDirectory = $r.cwd
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  foreach ($k in @($psi.Environment.Keys)) { if ($k -eq 'CLAUDECODE' -or $k -like 'CLAUDE_CODE_*' -or $k -eq 'CLAUDE_PID') { [void]$psi.Environment.Remove($k) } }
  $psi.Environment['CLAUDE_CONFIG_DIR'] = $using:cfgDir
  $t0 = Get-Date
  $p = [Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($using:timeoutMin * 60 * 1000)) { $p.Kill($true); $status = 'TIMEOUT' } else { $status = "exit $($p.ExitCode)" }
  $safe = ($r.name -replace '[\\/:*?"<>|]', '_')
  $txt = "# $($r.name) - $status - $([int]((Get-Date) - $t0).TotalMinutes) min`n`n" + $so.Result + "`n`n--- stderr ---`n" + $se.Result
  [IO.File]::WriteAllText((Join-Path $using:out ($safe + '.md')), $txt, [Text.UTF8Encoding]::new($false))
  "$($r.name): $status"
}
"done - reports in $out"
