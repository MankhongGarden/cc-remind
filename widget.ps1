param([switch]$Test, [string]$ShotFile, [string]$ShotDir)
$ErrorActionPreference = 'Stop'
$Dir = $PSScriptRoot
$Node = (Get-Command node.exe -ErrorAction Stop).Source

function Run-Node([string[]]$argList) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Node
  $psi.Arguments = '"' + "$Dir\cc.mjs" + '" ' + (($argList | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  if ($p.ExitCode -ne 0) { throw ($err.Trim()) }
  $out
}

$Paths = (Run-Node @('paths')) | ConvertFrom-Json
$Cfg = $Paths.config
$Data = $Paths.data
$LogFile = Join-Path $Data 'widget.log'
$ScanOut = Join-Path $Data 'scan.json'
$StateFile = Join-Path $Data 'widget-state.json'
$SessionsDir = Join-Path $Paths.claudeConfigDir 'sessions'
$LaunchCmd = if ($Cfg.launchCommand) { [string]$Cfg.launchCommand } else { 'claude' }
$ResumeArgs = if ($Cfg.resumeArgs) { (@($Cfg.resumeArgs) | ForEach-Object { [string]$_ }) -join ' ' } else { '' }
$Roots = @($Cfg.projectRoots | Where-Object { $_ -and $_.path })
$ScanEverySec = 20
$Lang = if ($Paths.language -eq 'th') { 'th' } else { 'en' }

function U($s) { [regex]::Unescape($s) }
$Txt = @{
  en = @{ show = 'Show'; quit = 'Quit'; noFolder = 'Folder not found: '; noWindow = 'This chat is open, but its window was not found'; badName = 'The name contains characters that are not allowed'; exists = 'A folder with this name already exists'; badRoot = 'Unknown project folder' }
  th = @{ show = (U 'แสดงกล่อง'); quit = (U 'ปิดโปรแกรม'); noFolder = (U 'ไม่พบโฟลเดอร์: '); noWindow = (U 'แชทนี้เปิดอยู่ แต่หาหน้าต่างไม่เจอ'); badName = (U 'ชื่อมีตัวอักษรที่ใช้ไม่ได้'); exists = (U 'มีโฟลเดอร์ชื่อนี้อยู่แล้ว'); badRoot = 'Unknown project folder' }
}[$Lang]

function Log($m) { try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CcRemindWidget', [ref]$created)
$showEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\CcRemindWidgetShow')
if (-not $created) { [void]$showEvt.Set(); exit 0 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
foreach ($f in 'WebView2Loader.dll', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll') {
  if (-not (Test-Path (Join-Path $Dir "lib\$f"))) {
    [void][Windows.Forms.MessageBox]::Show("lib\$f is missing. Run install\install.ps1 first - it downloads the WebView2 SDK from NuGet.", 'cc-remind')
    exit 1
  }
}

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class CcWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibrary(string p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static List<IntPtr> AllForPid(uint pid) {
    var r = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h) && Title(h).Length > 0) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
  public static IntPtr FindForPid(uint pid, string hint) {
    IntPtr best = IntPtr.Zero, any = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h) && Title(h).Length > 0) {
        if (any == IntPtr.Zero) any = h;
        if (!string.IsNullOrEmpty(hint) && Title(h).IndexOf(hint, StringComparison.OrdinalIgnoreCase) >= 0) { best = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return best != IntPtr.Zero ? best : any;
  }
}
'@
[void][CcWin]::SetProcessDpiAwarenessContext([IntPtr](-4))

[Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) Log ("thread exception: " + $e.Exception) })

[void][CcWin]::LoadLibrary("$Dir\lib\WebView2Loader.dll")
Add-Type -Path "$Dir\lib\Microsoft.Web.WebView2.Core.dll"
Add-Type -Path "$Dir\lib\Microsoft.Web.WebView2.WinForms.dll"

function Safe([scriptblock]$b) { try { & $b } catch { Log ("error: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage) } }

$state = @{}
if (Test-Path $StateFile) { try { $j = Get-Content $StateFile -Raw | ConvertFrom-Json; $j.PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } } catch {} }

$form = New-Object Windows.Forms.Form
$form.Text = 'cc-remind'
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.BackColor = [Drawing.Color]::FromArgb(31, 31, 35)
$g = $form.CreateGraphics(); $scale = $g.DpiX / 96.0; $g.Dispose()
$form.Size = New-Object Drawing.Size([int](380 * $scale), [int](660 * $scale))
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = $wa.Right - $form.Width - [int](16 * $scale); $y = $wa.Bottom - $form.Height - [int](16 * $scale)
if ($null -ne $state.x) {
  $pt = New-Object Drawing.Point([int]$state.x, [int]$state.y)
  if (([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt) })) { $x = $pt.X; $y = $pt.Y }
}
$form.Location = New-Object Drawing.Point($x, $y)

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$cp = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$cp.UserDataFolder = Join-Path $Data 'wv2'
$wv.CreationProperties = $cp
$wv.DefaultBackgroundColor = [Drawing.Color]::FromArgb(31, 31, 35)
$wv.Dock = 'Fill'
$form.Controls.Add($wv)

$bmp = New-Object Drawing.Bitmap 32, 32
$gr = [Drawing.Graphics]::FromImage($bmp); $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'AntiAliasGridFit'
$gr.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(217, 119, 87))), 2, 2, 28, 28)
$sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
$gr.DrawString('C', (New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)), [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 1, 32, 32)), $sf)
$gr.Dispose()
$appIcon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
$form.Icon = $appIcon

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $appIcon
$tray.Text = 'cc-remind'
$tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add($Txt.show, $null, { Safe { Show-Widget } })
[void]$menu.Items.Add($Txt.quit, $null, { Safe { $script:Quitting = $true; $form.Close() } })
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Safe { Show-Widget } } })

$script:Ready = $false
$script:ScanProc = $null
$script:LastScan = [datetime]::MinValue
$script:Balloon = $null
$script:BalloonQueue = New-Object System.Collections.Queue
$script:Launched = @{}
$script:Pinned = $false
$script:Quitting = $false

function Post($obj) { if ($script:Ready) { $wv.CoreWebView2.PostWebMessageAsJson(($obj | ConvertTo-Json -Compress -Depth 6)) } }
function PostRaw($json) { if ($script:Ready) { $wv.CoreWebView2.PostWebMessageAsJson($json) } }
function Msg($text) { Post @{ type = 'msg'; text = $text } }

function Show-Widget {
  $form.Show()
  if ([CcWin]::IsIconic($form.Handle)) { [void][CcWin]::ShowWindow($form.Handle, 9) }
  $form.Activate()
}

function Start-Scan {
  if ($script:ScanProc -and -not $script:ScanProc.HasExited) { return }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Node
  $psi.Arguments = '"' + "$Dir\cc.mjs" + '" scan --out "' + $ScanOut + '"'
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $script:ScanProc = [Diagnostics.Process]::Start($psi)
  $script:LastScan = Get-Date
}

function Finish-Scan {
  if (-not $script:ScanProc -or -not $script:ScanProc.HasExited) { return }
  $code = $script:ScanProc.ExitCode; $script:ScanProc = $null
  if ($code -ne 0) { Log "scan exit $code"; return }
  $json = [IO.File]::ReadAllText($ScanOut, [Text.Encoding]::UTF8)
  PostRaw ('{"type":"data","payload":' + $json + '}')
  if ($Test) { return }
  $d = $json | ConvertFrom-Json
  $keys = @()
  foreach ($n in @($d.notify)) { if ($n) { $script:BalloonQueue.Enqueue($n); $keys += $n.key } }
  if ($keys.Count) { Safe { [void](Run-Node (@('notified') + $keys)) } }
}

function Next-Balloon {
  if ($script:BalloonQueue.Count -eq 0) { return }
  if ($script:Balloon -and ((Get-Date) - $script:Balloon.at).TotalSeconds -lt 8) { return }
  $n = $script:BalloonQueue.Dequeue()
  $script:Balloon = @{ n = $n; at = Get-Date }
  $tray.ShowBalloonTip(10000, [string]$n.head, [string]$n.body, 'Info')
  Log ("notify " + $n.key)
}
$tray.add_BalloonTipClicked({ Safe {
  $n = $script:Balloon.n
  if ($n -and $n.sessionId) { Open-Session $n.sessionId $n.cwd $false 0 '' }
  else { Show-Widget }
} })

function Get-LivePid($id) {
  foreach ($f in Get-ChildItem $SessionsDir -Filter *.json -ErrorAction SilentlyContinue) {
    try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json; if ($j.sessionId -eq $id -and (Get-Process -Id $j.pid -ErrorAction SilentlyContinue)) { return [int]$j.pid } } catch {}
  }
  0
}

function Select-Tab([IntPtr]$h, [string]$hint) {
  if (-not $hint) { return $false }
  $root = [Windows.Automation.AutomationElement]::FromHandle($h)
  $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
  foreach ($tab in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $cond)) {
    if ($tab.Current.Name.IndexOf($hint, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
      return $true
    }
  }
  $false
}

function Focus-Window([IntPtr]$h) {
  if ([CcWin]::IsIconic($h)) { [void][CcWin]::ShowWindow($h, 9) }
  [void][CcWin]::SetForegroundWindow($h)
}

function Focus-Session([int]$procId, [string]$title) {
  $hint = ($title -replace '^\W+', '').Trim()
  $cur = $procId
  for ($i = 0; $i -lt 8 -and $cur; $i++) {
    $wins = [CcWin]::AllForPid([uint32]$cur)
    if ($wins.Count) {
      foreach ($h in $wins) { if ([CcWin]::Cls($h) -eq 'CASCADIA_HOSTING_WINDOW_CLASS' -and (Select-Tab $h $hint)) { Focus-Window $h; return $true } }
      Focus-Window ([CcWin]::FindForPid([uint32]$cur, $hint))
      return $true
    }
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
    if (-not $c) { break }
    $cur = [int]$c.ParentProcessId
  }
  $false
}

function Launch-Claude([string]$cwd, [string]$resumeId) {
  if (-not (Test-Path -LiteralPath $cwd)) { Msg ($Txt.noFolder + $cwd); return }
  if ($resumeId -and $resumeId -notmatch '^[0-9a-fA-F-]{8,64}$') { Log "refusing odd session id"; return }
  $key = if ($resumeId) { $resumeId } else { 'new:' + $cwd }
  if ($script:Launched[$key] -and ((Get-Date) - $script:Launched[$key]).TotalSeconds -lt 15) { return }
  $script:Launched[$key] = Get-Date
  $cmd = $LaunchCmd
  if ($resumeId) { $cmd += ' --resume ' + $resumeId; if ($ResumeArgs) { $cmd += ' ' + $ResumeArgs } }
  if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    $a = '-w new -d "' + $cwd + '" cmd /k ' + $cmd
    Start-Process wt.exe -ArgumentList $a
  } else {
    Start-Process cmd.exe -ArgumentList ('/k ' + $cmd) -WorkingDirectory $cwd
  }
  Log ("launch " + $cmd + " in " + $cwd)
}

function Open-Session([string]$id, [string]$cwd, [bool]$live, [int]$procId, [string]$title) {
  $lp = Get-LivePid $id
  if ($lp) {
    if (-not (Focus-Session $lp $title)) { Msg $Txt.noWindow }
    return
  }
  Launch-Claude $cwd $id
}

function Handle($m) {
  switch ($m.cmd) {
    'ready' { $script:Ready = $true; if (Test-Path $ScanOut) { PostRaw ('{"type":"data","payload":' + [IO.File]::ReadAllText($ScanOut, [Text.Encoding]::UTF8) + '}') }; Start-Scan }
    'refresh' { Start-Scan }
    'hide' { $form.Hide() }
    'open' { Open-Session $m.id $m.cwd ([bool]$m.live) ([int]$m.pid) $m.title }
    'new' { Launch-Claude $m.cwd $null }
    'create' {
      $name = ([string]$m.name).Trim()
      $ri = [int]$m.root
      $root = if ($ri -ge 0 -and $ri -lt $Roots.Count) { $Roots[$ri] } else { $null }
      if (-not $root) { Post @{ type = 'createError'; text = $Txt.badRoot }; return }
      if (-not $name -or $name -match '[\\/:*?"<>|]' -or $name -match '^\.+$') { Post @{ type = 'createError'; text = $Txt.badName }; return }
      $path = Join-Path ([string]$root.path) $name
      if (Test-Path -LiteralPath $path) { Post @{ type = 'createError'; text = $Txt.exists }; return }
      [void](New-Item -ItemType Directory -Path $path)
      Log ("created project " + $path)
      Launch-Claude $path $null
      Post @{ type = 'created'; path = $path }
    }
    'todo' {
      if ($m.id -notmatch '^[0-9a-f]{1,8}$') { return }
      $a = @($m.op, $m.id)
      if ($m.op -eq 'drop') { $a = @('done', $m.id, '--by-user', '--dropped') }
      elseif ($m.op -eq 'done') { $a += '--by-user' }
      elseif ($m.op -eq 'snooze') { $a += [string]$m.v }
      elseif ($m.op -notin @('reopen', 'confirm')) { return }
      try { [void](Run-Node $a) } catch { Msg $_.Exception.Message }
      Start-Scan
    }
  }
}

$form.add_Shown({ Safe {
  $h = $form.Handle
  $ex = [CcWin]::GetWindowLong($h, -20)
  [void][CcWin]::SetWindowLong($h, -20, ($ex -bor 0x80) -band (-bnot 0x40000))
  $pref = 2; [void][CcWin]::DwmSetWindowAttribute($h, 33, [ref]$pref, 4)
  [void]$wv.EnsureCoreWebView2Async($null)
} })

$wv.add_CoreWebView2InitializationCompleted({ param($s, $e) Safe {
  if (-not $e.IsSuccess) { Log ("webview init failed: " + $e.InitializationException); return }
  $st = $wv.CoreWebView2.Settings
  $st.IsNonClientRegionSupportEnabled = $true
  $st.AreDefaultContextMenusEnabled = $false
  $st.IsStatusBarEnabled = $false
  $st.IsZoomControlEnabled = $false
  $wv.CoreWebView2.add_WebMessageReceived({ param($s2, $e2) Safe { Handle ($e2.WebMessageAsJson | ConvertFrom-Json) } })
  $wv.CoreWebView2.Navigate('file:///' + ("$Dir\ui.html" -replace '\\', '/'))
} })

$saveTimer = New-Object Windows.Forms.Timer; $saveTimer.Interval = 800
$saveTimer.add_Tick({ Safe {
  $saveTimer.Stop()
  if (-not $Test) { @{ x = $form.Left; y = $form.Top } | ConvertTo-Json | Set-Content $StateFile -Encoding ASCII }
} })
$form.add_Move({ $saveTimer.Stop(); $saveTimer.Start() })

$form.add_FormClosing({ param($s, $e)
  if (-not $script:Quitting -and $e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide(); return }
  $tray.Visible = $false; $tray.Dispose()
})

$tick = New-Object Windows.Forms.Timer; $tick.Interval = 1000
$tick.add_Tick({ Safe {
  if ($showEvt.WaitOne(0)) { Show-Widget }
  Finish-Scan
  if (((Get-Date) - $script:LastScan).TotalSeconds -ge $ScanEverySec) { Start-Scan }
  Next-Balloon
} })
$tick.Start()

$HWND_TOPMOST = [IntPtr](-1); $HWND_NOTOPMOST = [IntPtr](-2)
$SWP = 0x0001 -bor 0x0002 -bor 0x0010
$desk = New-Object Windows.Forms.Timer; $desk.Interval = 250
$desk.add_Tick({ Safe {
  if (-not $form.Visible) { return }
  $h = $form.Handle
  if ([CcWin]::IsIconic($h)) { [void][CcWin]::ShowWindow($h, 4) }
  $fg = [CcWin]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return }
  $cls = [CcWin]::Cls($fg)
  $isDesk = ($cls -eq 'WorkerW' -or $cls -eq 'Progman')
  if ($isDesk -and -not $script:Pinned) {
    [void][CcWin]::SetWindowPos($h, $HWND_TOPMOST, 0, 0, 0, 0, $SWP -bor 0x0040); $script:Pinned = $true
  } elseif (-not $isDesk -and $script:Pinned -and $fg -ne $h -and [CcWin]::GetAncestor($fg, 2) -ne $h) {
    [void][CcWin]::SetWindowPos($h, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP)
    [void][CcWin]::SetWindowPos($h, $fg, 0, 0, 0, 0, $SWP)
    $script:Pinned = $false
  }
} })
$desk.Start()

Log "start pid=$PID scale=$scale"
if ($Test) {
  $OutDir = if ($ShotDir) { $ShotDir } else { Join-Path $env:TEMP 'cc-remind-test' }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  $Shots = @(if ($ShotFile) { Get-Content $ShotFile } else { '0' })
  $script:ShotN = 0; $script:Cap = $null; $script:Captured = $false
  $quit = New-Object Windows.Forms.Timer; $quit.Interval = 2500
  $quit.add_Tick({ Safe {
    if (-not $script:Ready) { return }
    if ($script:Cap) { if (-not $script:Cap.t.IsCompleted) { return }; $script:Cap.s.Close(); $script:Cap = $null }
    if ($script:ShotN -gt 0 -and $script:ShotN -le $Shots.Count -and -not $script:Captured) {
      $fs = [IO.File]::Create((Join-Path $OutDir "widget-$($script:ShotN).png"))
      $script:Cap = @{ s = $fs; t = $wv.CoreWebView2.CapturePreviewAsync('Png', $fs) }; $script:Captured = $true; return
    }
    if ($script:ShotN -ge $Shots.Count) { $script:Quitting = $true; $form.Close(); return }
    [void]$wv.CoreWebView2.ExecuteScriptAsync($Shots[$script:ShotN]); $script:ShotN++; $script:Captured = $false
  } }); $quit.Start()
}
[Windows.Forms.Application]::Run($form)
Log "exit"
$mutex.ReleaseMutex()
