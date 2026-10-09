<#
  cc-remind installer (Windows). Safe to re-run.

  What it does by default:
    1. checks Node.js 18+
    2. creates the data folder and a config.json from config.example.json (if missing)
    3. downloads the WebView2 SDK from NuGet (pinned version + SHA-256) into lib\  (needed by the widget only)
    4. prints the SessionStart hook snippet and the optional CLAUDE.md line for you to paste yourself

  It never edits your Claude Code settings.json or CLAUDE.md.

  Opt-in switches:
    -AddToPath      add <repo>\bin to your user PATH so `cc-remind` works in any shell
    -InstallSkill   copy skill\SKILL.md to <claude config dir>\skills\cc-remind\SKILL.md
    -SkipWebView2   skip step 3 (CLI + hook only, no widget)
#>
param([switch]$AddToPath, [switch]$InstallSkill, [switch]$SkipWebView2)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$WV2Version = '1.0.4258.31'
$WV2Sha256 = '56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9'

function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

Step 'Node.js'
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js 18 or newer is required (https://nodejs.org).' }
$major = [int]((& node -p "process.versions.node.split('.')[0]").Trim())
if ($major -lt 18) { throw "Node.js 18 or newer is required (found $major)." }
"node $(& node --version) OK"

Step 'Data folder and config'
$paths = (& node "$Repo\cc.mjs" paths) | ConvertFrom-Json
"data folder: $($paths.data)"
if (-not (Test-Path $paths.configFile)) {
  Copy-Item (Join-Path $Repo 'config.example.json') $paths.configFile
  "created $($paths.configFile) (edit it to set time zone, language, project folders)"
} else { "config exists: $($paths.configFile)" }
"Claude Code config dir: $($paths.claudeConfigDir)  (set CLAUDE_CONFIG_DIR or claudeConfigDir in config.json to change)"
"time zone: $($paths.timeZone)"

if (-not $SkipWebView2) {
  Step "WebView2 SDK $WV2Version (from NuGet, for the widget)"
  $lib = Join-Path $Repo 'lib'
  $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'win-arm64' } 'x86' { 'win-x86' } default { 'win-x64' } }
  $want = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll')
  $have = @($want | Where-Object { Test-Path (Join-Path $lib $_) })
  $verOk = $false
  if ($have.Count -eq $want.Count) { $verOk = ((Get-Item (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')).VersionInfo.FileVersion -eq $WV2Version) }
  if ($verOk) { "already in lib\ ($WV2Version)" }
  else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cc-remind-wv2-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
      $pkg = Join-Path $tmp 'webview2.zip'
      $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$WV2Version/microsoft.web.webview2.$WV2Version.nupkg"
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      "downloading $url"
      Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing
      $hash = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
      if ($hash -ne $WV2Sha256) { throw "SHA-256 mismatch for the NuGet package (got $hash). Not installing." }
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
      try {
        New-Item -ItemType Directory -Force $lib | Out-Null
        $map = @{ 'lib/net462/Microsoft.Web.WebView2.Core.dll' = 'Microsoft.Web.WebView2.Core.dll'; 'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = 'Microsoft.Web.WebView2.WinForms.dll'; "runtimes/$arch/native/WebView2Loader.dll" = 'WebView2Loader.dll'; 'LICENSE.txt' = 'WebView2-LICENSE.txt' }
        foreach ($k in $map.Keys) {
          $e = $zip.Entries | Where-Object { $_.FullName -eq $k } | Select-Object -First 1
          if (-not $e) { throw "missing $k in the package" }
          [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $lib $map[$k]), $true)
        }
      } finally { $zip.Dispose() }
      foreach ($f in $want) {
        $sig = Get-AuthenticodeSignature (Join-Path $lib $f)
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw "$f is not validly signed by Microsoft ($($sig.Status))." }
      }
      "installed to $lib ($arch). License: lib\WebView2-LICENSE.txt"
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
  }
}

$bin = Join-Path $Repo 'bin'
if ($AddToPath) {
  Step 'PATH'
  $p = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($p -split ';') -contains $bin) { "already on user PATH: $bin" }
  else { [Environment]::SetEnvironmentVariable('Path', ($(if ($p) { $p.TrimEnd(';') + ';' } else { '' }) + $bin), 'User'); "added to user PATH: $bin (open a new terminal)" }
}

if ($InstallSkill) {
  Step 'Skill'
  $dst = Join-Path $paths.claudeConfigDir 'skills\cc-remind'
  New-Item -ItemType Directory -Force $dst | Out-Null
  $f = Join-Path $dst 'SKILL.md'
  if (Test-Path $f) { Copy-Item $f "$f.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"; "backed up the existing skill" }
  Copy-Item (Join-Path $Repo 'skill\SKILL.md') $f -Force
  "installed $f"
}

$onPath = @(Get-Command cc-remind -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
$cmd = if ($AddToPath -or $onPath) { 'cc-remind hook-start' } else { 'node \"' + ($Repo -replace '\\', '/') + '/cc.mjs\" hook-start' }
Step 'Next steps (do these yourself)'
@"
1. Add the SessionStart hook to your Claude Code settings.json (user or project):

{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$cmd", "timeout": 10 } ] }
    ]
  }
}

2. Optional: tell every session about the inbox by adding this line to your CLAUDE.md:

- Reminders and handoffs go in ``cc-remind`` (see skill ``cc-remind``): things only I can do, results to check later and notes for another project -> ``cc-remind add`` (one item = one task). When you finish work that matches an open item, close it with ``cc-remind done <id> "<what>"`` before saying it is done.

3. Skill: $(if ($InstallSkill) { 'installed.' } else { "copy skill\SKILL.md to $($paths.claudeConfigDir)\skills\cc-remind\SKILL.md (or re-run with -InstallSkill)." })

4. Widget: wscript "$Repo\launch.vbs"   (to start it at logon, add that command to Task Scheduler or your Startup folder)
"@
