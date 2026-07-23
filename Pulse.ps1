<#
  Pulse — a dependency-free Windows tray overview of your Claude Code sessions.

  Tray icon (activity pulse) with a coloured dot = there is NEW (unseen) activity.
  Left-click opens a flyout. States, colour-coded:
    working (blue) · needs you (amber) · done (green) · ready (grey)
  New events are highlighted; clicking a row — or focusing that terminal yourself —
  clears the highlight. Click a row to bring its window forward. Right-click: Open / Start at login / Quit.

  Reads only local files:
    ~/.claude/sessions/*.json                    live registry (status, cwd, name, pid, ...)
    ~/.claude/projects/<slug>/<sessionId>.jsonl  transcript (ai-title, last tool_use, stop_reason)

  No installs, no external dependencies. Windows PowerShell 5.1 or PowerShell 7+.
  Launch hidden via Pulse.vbs, or: pwsh -NoProfile -File Pulse.ps1
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $env:TEMP 'Pulse.log'
$AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$uiScript = {
  Set-StrictMode -Off
  $ErrorActionPreference = 'Stop'
  $LogPath = Join-Path $env:TEMP 'Pulse.log'
  $script:AppDir = if ($AppDir) { $AppDir } else { $PWD.Path }
  "[{0}] UI start (apartment={1})" -f (Get-Date -Format o), ([System.Threading.Thread]::CurrentThread.GetApartmentState()) | Out-File $LogPath -Append

  # DPI: pin the process to Per-Monitor-V2 BEFORE any window is realised, so GDI screen
  # capture, WinForms Screen.Bounds and WPF PointToScreen/TransformToDevice all share one
  # physical-pixel space. Without it pwsh starts DPI-unaware and the self-rendered frost
  # (Set-FrostCapture) maps the wrong screen region on a monitor whose scaling differs from
  # the primary. .NET (pwsh) only — Windows PowerShell 5.1's WPF ignores the PMv2 context.
  if ($PSVersionTable.PSEdition -eq 'Core') {
    try {
      Add-Type -Namespace Pulse -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
'@
      # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
      [void][Pulse.Dpi]::SetProcessDpiAwarenessContext([System.IntPtr]::new(-4))
    } catch {
      "[{0}] dpi: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append
    }
  }

  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes

  if (-not ([System.Management.Automation.PSTypeName]'Pulse.Native').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace Pulse {
  public static class Native {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool fAltTab);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
    [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int cxL, cxR, cyT, cyB; }
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

    public static List<string> ListWindows() {
      var r = new List<string>();
      EnumWindows((h, l) => {
        if (!IsWindowVisible(h)) return true;
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, 512);
        if (sb.Length == 0) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        r.Add(h.ToInt64() + "" + pid + "" + sb.ToString());
        return true;
      }, IntPtr.Zero);
      return r;
    }
    // WT windows all share one process, so we key off the window class instead
    // of the pid. Returns "hwndactiveTabTitle" per visible terminal window
    // (across every virtual desktop).
    public static List<string> ListTerminalWindows() {
      var r = new List<string>();
      EnumWindows((h, l) => {
        if (!IsWindowVisible(h)) return true;
        var cn = new StringBuilder(64); GetClassName(h, cn, 64);
        if (cn.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;
        var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
        r.Add(h.ToInt64() + "" + sb.ToString());
        return true;
      }, IntPtr.Zero);
      return r;
    }
    public static string ForegroundTitle() {
      IntPtr h = GetForegroundWindow();
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString();
    }
    // Title of the foreground window ONLY if it is a Windows Terminal window,
    // else "". Prevents a non-terminal window (browser/editor) whose title
    // happens to match a session from clearing that session's highlight.
    public static string ForegroundTerminalTitle() {
      IntPtr h = GetForegroundWindow();
      var cn = new StringBuilder(64); GetClassName(h, cn, 64);
      if (cn.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return "";
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString();
    }
    public static bool FocusWindow(long hwnd) {
      IntPtr h = new IntPtr(hwnd);
      if (h == IntPtr.Zero) return false;
      if (IsIconic(h)) ShowWindow(h, 9);
      IntPtr fg = GetForegroundWindow();
      uint tmp; uint fgThread = GetWindowThreadProcessId(fg, out tmp);
      uint myThread = GetCurrentThreadId();
      bool attached = false;
      if (fgThread != myThread) attached = AttachThreadInput(myThread, fgThread, true);
      BringWindowToTop(h);
      bool ok = SetForegroundWindow(h);
      // SetForegroundWindow returns false when the target is on another virtual
      // desktop (or the foreground lock bites). SwitchToThisWindow behaves like
      // an Alt-Tab pick and reliably switches to the window's desktop.
      if (!ok || GetForegroundWindow() != h) { SwitchToThisWindow(h, true); ok = GetForegroundWindow() == h; }
      if (attached) AttachThreadInput(myThread, fgThread, false);
      return ok;
    }
    public static void SetBackdrop(IntPtr hwnd, int type) { DwmSetWindowAttribute(hwnd, 38, ref type, 4); }
    public static void SheetOfGlass(IntPtr hwnd) { var m = new MARGINS { cxL = -1, cxR = -1, cyT = -1, cyB = -1 }; DwmExtendFrameIntoClientArea(hwnd, ref m); }
    public static void RoundCorners(IntPtr hwnd) { int v = 2; DwmSetWindowAttribute(hwnd, 33, ref v, 4); }
    public static void DarkMode(IntPtr hwnd) { int v = 1; DwmSetWindowAttribute(hwnd, 20, ref v, 4); }
  }
}
'@
  }

  # ── paths ────────────────────────────────────────────────────────────────────
  $ClaudeDir   = Join-Path $HOME '.claude'
  $SessionsDir = Join-Path $ClaudeDir 'sessions'
  $ProjectsDir = Join-Path $ClaudeDir 'projects'
  $script:SettingsPath = Join-Path $ClaudeDir 'settings.json'      # for the statusline bridge
  $script:StatsCache   = Join-Path $ClaudeDir 'stats-cache.json'   # Claude Code's own daily aggregates
  $script:UsagePath    = Join-Path $ClaudeDir 'Pulse.usage.json'   # written by Pulse.Statusline.ps1
  $script:BridgePath   = Join-Path $script:AppDir 'Pulse.Statusline.ps1'
  $script:IconPath     = Join-Path $script:AppDir 'Pulse.ico'                      # shortcut / search icon
  $script:AutoLnk      = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pulse.lnk'

  # Writes a Pulse launcher shortcut (wscript -> Pulse.vbs, custom icon) at $lnk.
  function Write-PulseShortcut([string]$lnk) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = '"' + (Join-Path $script:AppDir 'Pulse.vbs') + '"'
    $sc.WorkingDirectory = $script:AppDir
    $sc.Description = 'Pulse — Claude Code session overview'
    if (Test-Path $script:IconPath) { $sc.IconLocation = $script:IconPath + ',0' }
    $sc.Save()
  }
  # Self-heal: if an autostart shortcut exists but points elsewhere (e.g. the folder
  # was moved/renamed), rewrite it to the current location so login-start keeps working.
  function Repair-Autostart {
    try {
      if (-not (Test-Path $script:AutoLnk)) { return }
      $cur  = (New-Object -ComObject WScript.Shell).CreateShortcut($script:AutoLnk).Arguments
      $want = '"' + (Join-Path $script:AppDir 'Pulse.vbs') + '"'
      if ($cur -ne $want) {
        Write-PulseShortcut $script:AutoLnk
        "[{0}] autostart: repaired stale shortcut ({1} -> {2})" -f (Get-Date -Format o), $cur, $want | Out-File $LogPath -Append
      }
    } catch { "[{0}] autostart repair: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
  }
  Repair-Autostart

  $script:SANS = [System.Windows.Media.FontFamily]::new('Segoe UI')
  $script:MONO = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas, monospace')
  function Brush([string]$hex) { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
  # smooth colour transitions (needs a mutable SolidColorBrush on the target)
  function Fade-Brush($brush, [string]$toHex, [int]$ms = 200) {
    if (-not $brush) { return }
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($toHex)
    $a = [System.Windows.Media.Animation.ColorAnimation]::new($c, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
    $a.EasingFunction = [System.Windows.Media.Animation.QuadraticEase]::new()
    $brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $a)
  }
  function New-Text {
    param([string]$Text, [string]$Fg, [double]$Size = 12, [switch]$Mono, [switch]$Bold, [switch]$Semi)
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text; $t.Foreground = (Brush $Fg)
    $t.FontFamily = if ($Mono) { $script:MONO } else { $script:SANS }
    $t.FontSize = $Size
    $t.FontWeight = if ($Bold) { [System.Windows.FontWeights]::Bold } elseif ($Semi) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
    $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $t
  }
  function Format-Since([double]$ms) {
    if (-not $ms) { return '' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sec = [math]::Max(0, [math]::Floor(($now - $ms) / 1000))
    if ($sec -lt 60) { return "$([int]$sec)s" }
    $min = [math]::Floor($sec / 60)
    if ($min -lt 60) { return "$([int]$min)m" }
    "{0}h {1}m" -f [int][math]::Floor($min / 60), [int]($min % 60)
  }
  function Format-Location([string]$cwd) {
    if (-not $cwd) { return '' }
    if ($cwd -match '[\\/]workspaces[\\/]\d{4}[\\/](\d+)') { return "Ticket $($Matches[1])" }
    Split-Path $cwd -Leaf
  }
  function Short([string]$s, [int]$n = 40) { if ($s -and $s.Length -gt $n) { $s.Substring(0, $n - 1) + '…' } else { $s } }
  function Format-Tok([double]$n) { if ($n -ge 1000000) { '{0:0.0}M' -f ($n / 1000000) } elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000) } else { "$([int]$n)" } }
  function Add-Run($tb, [string]$text, [string]$hex) { $r = [System.Windows.Documents.Run]::new($text); $r.Foreground = (Brush $hex); [void]$tb.Inlines.Add($r) }

  # Pulse glyph: a white "activity pulse" line (outline only, matches tray icons)
  function Draw-Glyph($ctx, [double]$s) {
    $pen = [System.Windows.Media.Pen]::new((Brush '#ECFFFFFF'), [math]::Max(1.2, $s * 0.09))
    $pen.StartLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.EndLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.LineJoin = [System.Windows.Media.PenLineJoin]::Round
    $pts = @(0.10, 0.52, 0.33, 0.52, 0.43, 0.28, 0.55, 0.76, 0.65, 0.52, 0.90, 0.52)
    $fig = [System.Windows.Media.PathFigure]::new()
    $fig.StartPoint = [System.Windows.Point]::new($s * $pts[0], $s * $pts[1])
    for ($i = 2; $i -lt $pts.Count; $i += 2) { $fig.Segments.Add([System.Windows.Media.LineSegment]::new([System.Windows.Point]::new($s * $pts[$i], $s * $pts[$i + 1]), $true)) }
    $geo = [System.Windows.Media.PathGeometry]::new(); $geo.Figures.Add($fig)
    $ctx.DrawGeometry($null, $pen, $geo)
  }
  function New-GlyphImage([int]$px) {
    $dv = [System.Windows.Media.DrawingVisual]::new(); $ctx = $dv.RenderOpen(); Draw-Glyph $ctx $px; $ctx.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($px, $px, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv); $rtb.Freeze(); $rtb
  }

  # small line-icons (16px design, stroked, scaled down)
  $script:IcoFile = 'M4,1.5 L10,1.5 L13,4.5 L13,14 L4,14 Z M10,1.5 L10,4.5 L13,4.5'
  $script:IcoTool = 'M2,3.5 L14,3.5 L14,12.5 L2,12.5 Z M4.5,6.5 L6.5,8.5 L4.5,10.5 M8,10.5 L11,10.5'
  $script:IcoTag  = 'M7.8,2.3 L13.7,2.3 L13.7,8.2 L8,13.9 L2.1,8 Z'
  $script:IcoRepo = 'M2,4.5 L6,4.5 L7.5,6 L14,6 L14,12.5 L2,12.5 Z'
  function New-Icon([string]$data, [string]$hex, [double]$sz = 12) {
    $p = [System.Windows.Shapes.Path]::new()
    $p.Data = [System.Windows.Media.Geometry]::Parse($data)
    $p.Stroke = (Brush $hex); $p.StrokeThickness = 1.3
    $p.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round; $p.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $p.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
    $p.Stretch = [System.Windows.Media.Stretch]::Uniform; $p.Width = $sz; $p.Height = $sz
    $p.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $p
  }
  # a metric as plain icon + value (no box)
  function New-Metric([string]$icon, [string]$text, [string]$hex) {
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $sp.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $sp.Margin = [System.Windows.Thickness]::new(0, 0, 16, 4)
    if ($icon) { $sp.Children.Add((New-Icon $icon $hex 12)) | Out-Null }
    $t = New-Text -Text $text -Fg $hex -Size 11 -Mono; $t.Margin = [System.Windows.Thickness]::new($(if ($icon) { 5 } else { 0 }), 0, 0, 0); $t.MaxWidth = 160
    $sp.Children.Add($t) | Out-Null
    $sp
  }

  # ── data layer ───────────────────────────────────────────────────────────────
  # Read a file's lines with shared read/write access, so a live transcript that
  # Claude is still appending to can be read without a sharing violation. Far
  # faster than Get-Content -Tail on large files (which is pathologically slow:
  # ~3 s on a 12 MB transcript vs. ~40 ms here).
  function Read-LinesShared([string]$path) {
    $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $sr = [System.IO.StreamReader]::new($fs)
      try {
        $list = [System.Collections.Generic.List[string]]::new()
        while ($null -ne ($ln = $sr.ReadLine())) { $list.Add($ln) }
        , $list
      } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
  }

  function Get-Sessions {
    $out = @()
    if (-not (Test-Path $SessionsDir)) { return , $out }
    $living = [System.Collections.Generic.HashSet[int]]::new()
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { [void]$living.Add([int]$_.Id) }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($f in (Get-ChildItem -Path (Join-Path $SessionsDir '*.json') -ErrorAction SilentlyContinue)) {
      $s = $null; try { $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
      if (-not $s.sessionId) { continue }
      if (-not $living.Contains([int]$s.pid)) { continue }
      if ($s.statusUpdatedAt -and ($now - $s.statusUpdatedAt) -gt (12 * 3600 * 1000)) { continue }
      $out += [pscustomobject]@{
        Name = if ($s.name) { $s.name } else { $s.sessionId.Substring(0, 8) }
        SessionId = $s.sessionId; Cwd = $s.cwd
        Status = if ($s.status) { $s.status } else { 'unknown' }
        StatusUpdatedAt = $s.statusUpdatedAt; Pid = $s.pid; Meta = $null; State = $null; Unseen = $false
      }
    }
    , $out
  }

  $script:MetaCache = @{}
  function Read-Meta($sess) {
    $empty = @{ AiTitle = $null; Action = $null; WaitKind = 'idle' }
    if (-not $sess.Cwd) { return $empty }
    $slug = $sess.Cwd -replace '[^A-Za-z0-9]', '-'
    $tf = Join-Path $ProjectsDir "$slug\$($sess.SessionId).jsonl"
    if (-not (Test-Path $tf)) { return $empty }
    try {
      $mtime = (Get-Item $tf).LastWriteTimeUtc.Ticks
      $c = $script:MetaCache[$sess.SessionId]
      if ($c -and $c.Mtime -eq $mtime) { return $c.Meta }
      $lines = Read-LinesShared $tf
      if ($lines.Count -gt 40) { $lines = $lines.GetRange($lines.Count - 40, 40) }
      $meta = @{ AiTitle = $null; Action = $null; WaitKind = 'idle' }
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '"type":"ai-title"') { try { $meta.AiTitle = ($lines[$i] | ConvertFrom-Json).aiTitle } catch {} ; break }
      }
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '"type":"assistant"') {
            $o = $null; try { $o = $lines[$i] | ConvertFrom-Json } catch {}
            if ($o) {
              $stop = $o.message.stop_reason; $tool = $null; $detail = ''
              foreach ($ct in $o.message.content) {
                if ($ct.type -eq 'tool_use') {
                  $tool = $ct.name
                  if ($ct.input.file_path)   { $detail = Split-Path $ct.input.file_path -Leaf }
                  elseif ($ct.input.command) { $detail = ($ct.input.command -split "`n")[0] }
                  elseif ($ct.input.pattern) { $detail = $ct.input.pattern }
                  break
                }
              }
              if ($tool) {
                $verb = switch ($tool) { 'Edit' { 'Editing' } 'Write' { 'Writing' } 'Read' { 'Reading' } 'Bash' { 'Running' } 'PowerShell' { 'Running' } 'Grep' { 'Searching' } 'Glob' { 'Searching' } 'Task' { 'Running agent' } 'WebFetch' { 'Fetching' } 'WebSearch' { 'Searching web' } 'Skill' { 'Skill' } default { $tool } }
                $meta.Action = Short (("{0} {1}" -f $verb, $detail).Trim()) 34
              }
              if ($stop -eq 'tool_use' -and $tool) { $meta.WaitKind = 'attention' } else { $meta.WaitKind = 'done' }
            }
          break
        }
      }
      $script:MetaCache[$sess.SessionId] = @{ Mtime = $mtime; Meta = $meta }
      return $meta
    } catch { return $empty }
  }

  # ── cumulative token totals (incremental; only computed when a row is drawn) ──
  $script:TokCache = @{}
  function Read-Tokens($sess) {
    $z = @{ Up = 0; Down = 0; Tools = 0 }
    if (-not $sess.Cwd) { return $z }
    $slug = $sess.Cwd -replace '[^A-Za-z0-9]', '-'
    $tf = Join-Path $ProjectsDir "$slug\$($sess.SessionId).jsonl"
    if (-not (Test-Path $tf)) { return $z }
    try {
      $len = (Get-Item $tf).Length
      $c = $script:TokCache[$sess.SessionId]
      if ($c -and $c.Len -eq $len) { return @{ Up = $c.Up; Down = $c.Down; Tools = $c.Tools } }
      $lines = Read-LinesShared $tf
      $prev = if ($c) { $c.Count } else { 0 }
      $up = if ($c) { $c.Up } else { 0 }; $down = if ($c) { $c.Down } else { 0 }; $tools = if ($c) { $c.Tools } else { 0 }
      if ($lines.Count -lt $prev) { $prev = 0; $up = 0; $down = 0; $tools = 0 }
      for ($i = $prev; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '"output_tokens"') {
          $o = $null; try { $o = $lines[$i] | ConvertFrom-Json } catch {}
          $u = $o.message.usage
          if ($u) { $up += ([int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens); $down += [int64]$u.output_tokens }
          foreach ($ct in $o.message.content) { if ($ct.type -eq 'tool_use') { $tools++ } }
        }
      }
      $script:TokCache[$sess.SessionId] = @{ Len = $len; Count = $lines.Count; Up = $up; Down = $down; Tools = $tools }
      @{ Up = $up; Down = $down; Tools = $tools }
    } catch { $z }
  }

  $script:DiffCache = @{}
  function Get-GitDiff([string]$cwd) {
    if (-not $cwd -or -not (Test-Path (Join-Path $cwd '.git'))) { return $null }
    $now = [Environment]::TickCount
    $c = $script:DiffCache[$cwd]
    if ($c -and ([math]::Abs($now - $c.T) -lt 5000)) { return $c.V }
    $res = $null
    try {
      $psi = [System.Diagnostics.ProcessStartInfo]::new('git', '-C "' + $cwd + '" --no-optional-locks diff --shortstat')
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $out = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(1200)
      $add = if ($out -match '(\d+) insertion') { [int]$Matches[1] } else { 0 }
      $del = if ($out -match '(\d+) deletion') { [int]$Matches[1] } else { 0 }
      $fls = if ($out -match '(\d+) files? changed') { [int]$Matches[1] } else { 0 }
      if ($add -or $del -or $fls) { $res = @{ Add = $add; Del = $del; Files = $fls } }
    } catch {}
    $script:DiffCache[$cwd] = @{ T = $now; V = $res }
    $res
  }

  # ── official usage: statusline bridge (install / detect / read) ──────────────
  # Claude Code exposes its server-computed 5h / weekly usage ONLY to a statusLine
  # command — it pipes the session JSON (incl. rate_limits) to it on stdin after each
  # assistant message. Pulse.Statusline.ps1 captures that into Pulse.usage.json. These
  # helpers install/remove that single settings.json entry (atomic, with a backup) and
  # read the capture. We never estimate the limits: no capture → no number is shown.
  function Get-BridgeCommand { 'pwsh -NoProfile -File "{0}"' -f ($script:BridgePath -replace '\\', '/') }
  # 'ours' | 'foreign' (a different statusLine is configured — we won't touch it) | 'none'.
  # mtime-cached (called every ~2 s while visible); a transient read error keeps the last
  # known state rather than flashing 'none' (which would swap the meters for the enable CTA).
  $script:BridgeCache = $null; $script:LastBridgeState = 'none'
  function Get-BridgeState {
    try {
      if (-not (Test-Path $script:SettingsPath)) { $script:LastBridgeState = 'none'; return 'none' }
      $mt = (Get-Item $script:SettingsPath).LastWriteTimeUtc.Ticks
      if ($script:BridgeCache -and $script:BridgeCache.Mt -eq $mt) { return $script:BridgeCache.V }
      $cmd = (Get-Content $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json).statusLine.command
      $v = if (-not $cmd) { 'none' } elseif ($cmd -like '*Pulse.Statusline.ps1*') { 'ours' } else { 'foreign' }
      $script:BridgeCache = @{ Mt = $mt; V = $v }; $script:LastBridgeState = $v; $v
    } catch { $script:LastBridgeState }
  }
  # BOM-less UTF-8 write: Set-Content -Encoding UTF8 adds a BOM under Windows PowerShell 5.1,
  # and Claude Code (Node) refuses to JSON.parse a BOM-prefixed settings.json.
  function Set-Settings($obj) {
    $tmp = "$($script:SettingsPath).tmp"
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 25), [System.Text.UTF8Encoding]::new($false))
    Move-Item $tmp $script:SettingsPath -Force
  }
  function Install-Bridge {
    try {
      if ((Get-BridgeState) -eq 'foreign') { return $false }   # never clobber a user's own statusLine
      $s = if (Test-Path $script:SettingsPath) { Get-Content $script:SettingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
      if (Test-Path $script:SettingsPath) { Copy-Item $script:SettingsPath "$($script:SettingsPath).pulsebak" -Force -ErrorAction SilentlyContinue }
      $sl = [pscustomobject]@{ type = 'command'; command = (Get-BridgeCommand); padding = 0 }
      if ($s.PSObject.Properties['statusLine']) { $s.statusLine = $sl } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl }
      Set-Settings $s; $true
    } catch { "[{0}] bridge install: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append; $false }
  }
  function Uninstall-Bridge {
    try {
      if (-not (Test-Path $script:SettingsPath)) { return $true }
      $s = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
      if ($s.PSObject.Properties['statusLine'] -and ($s.statusLine.command -like '*Pulse.Statusline.ps1*')) {
        $s.PSObject.Properties.Remove('statusLine'); Set-Settings $s
      }
      $true
    } catch { "[{0}] bridge uninstall: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append; $false }
  }

  $script:UsageCache = $null
  # Parsed Pulse.usage.json or $null. Fields: fiveHour/sevenDay = @{pct;resetsAt}, capturedAt, model, costUsd
  function Read-UsageOfficial {
    if (-not (Test-Path $script:UsagePath)) { return $null }
    try {
      $mt = (Get-Item $script:UsagePath).LastWriteTimeUtc.Ticks
      if ($script:UsageCache -and $script:UsageCache.Mt -eq $mt) { return $script:UsageCache.V }
      $u = Get-Content $script:UsagePath -Raw -ErrorAction Stop | ConvertFrom-Json
      $script:UsageCache = @{ Mt = $mt; V = $u }; $u
    } catch { $null }
  }

  # ── statistics aggregation (heavy transcript scan on a background runspace) ──
  # A full regex scan of all transcripts is ~5 s, so it must never run on the UI thread.
  # We compute on a worker runspace and marshal the result back; the flyout keeps showing
  # the previous result while a refresh runs. Every number here is ACTUAL, never estimated.
  $script:StatsWorker = @'
param($ProjectsDir, $StatsCache)
$rxTs  = [regex]'"timestamp":"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})'
$rxOut = [regex]'"output_tokens":(\d+)'
$rxIn  = [regex]'"input_tokens":(\d+)'
$rxCc  = [regex]'"cache_creation_input_tokens":(\d+)'
$rxMod = [regex]'"model":"([^"]+)"'
$rxCwd = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
$rxId  = [regex]'"id":"(msg_[^"]+)"'
# Claude Code writes ONE JSONL line per content block (thinking / text / each tool_use), and
# every one repeats the SAME message.usage. Dedup by message.id so a response is counted once.
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
$days = @{}; $hours = @{}; $models = @{}; $projects = @{}; $fileCount = 0
foreach ($f in (Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
  $fileCount++; $cwd = $null; $fMsgs = 0; $fTok = 0L
  try {
    $fs = [System.IO.FileStream]::new($f.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
      $sr = [System.IO.StreamReader]::new($fs)
      try {
        while ($null -ne ($ln = $sr.ReadLine())) {
          if (-not $cwd) { $mc = $rxCwd.Match($ln); if ($mc.Success) { $cwd = $mc.Groups[1].Value -replace '\\\\', '\' } }
          if ($ln.IndexOf('"output_tokens"') -lt 0) { continue }
          $mi = $rxId.Match($ln); if ($mi.Success -and -not $seenIds.Add($mi.Groups[1].Value)) { continue }  # same API response already counted
          $mt = $rxTs.Match($ln); if (-not $mt.Success) { continue }
          # transcript timestamps are UTC; bucket by LOCAL day/hour so they match the UI's local queries
          $loc = ([datetime]::new([int]$mt.Groups[1].Value, [int]$mt.Groups[2].Value, [int]$mt.Groups[3].Value, [int]$mt.Groups[4].Value, [int]$mt.Groups[5].Value, 0, [System.DateTimeKind]::Utc)).ToLocalTime()
          $day = $loc.ToString('yyyy-MM-dd'); $hr = $loc.Hour
          $o = $rxOut.Match($ln); $i = $rxIn.Match($ln); $c = $rxCc.Match($ln); $tok = 0L
          if ($o.Success) { $tok += [int64]$o.Groups[1].Value }
          if ($i.Success) { $tok += [int64]$i.Groups[1].Value }
          if ($c.Success) { $tok += [int64]$c.Groups[1].Value }
          if (-not $days.ContainsKey($day)) { $days[$day] = @{ Msgs = 0; Tok = 0L } }
          $days[$day].Msgs++; $days[$day].Tok += $tok
          $hours[$hr] = 1 + $(if ($hours.ContainsKey($hr)) { $hours[$hr] } else { 0 })
          $mm = $rxMod.Match($ln)
          if ($mm.Success) { $k = $mm.Groups[1].Value; $models[$k] = $tok + $(if ($models.ContainsKey($k)) { $models[$k] } else { 0L }) }
          $fMsgs++; $fTok += $tok
        }
      } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
  } catch {}
  if ($cwd -and $fMsgs) {
    if (-not $projects.ContainsKey($cwd)) { $projects[$cwd] = @{ Msgs = 0; Tok = 0L; LastMs = 0 } }
    $projects[$cwd].Msgs += $fMsgs; $projects[$cwd].Tok += $fTok
    $lm = [DateTimeOffset]::new($f.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
    if ($lm -gt $projects[$cwd].LastMs) { $projects[$cwd].LastMs = $lm }
  }
}
# lifetime totals + older calendar days come from Claude Code's own stats-cache.json
$totals = @{ Sessions = 0; Messages = 0; FirstDate = $null }
try {
  if (Test-Path $StatsCache) {
    $sc = Get-Content $StatsCache -Raw | ConvertFrom-Json
    foreach ($d in $sc.dailyActivity) { if (-not $days.ContainsKey($d.date)) { $days[$d.date] = @{ Msgs = [int]$d.messageCount; Tok = 0L } } }
    if ($sc.totalSessions)    { $totals.Sessions  = [int]$sc.totalSessions }
    if ($sc.totalMessages)    { $totals.Messages   = [int]$sc.totalMessages }
    if ($sc.firstSessionDate) { try { $totals.FirstDate = ([datetime]$sc.firstSessionDate).ToString('yyyy-MM-dd') } catch {} }
  }
} catch {}
@{ Days = $days; Hours = $hours; Models = $models; Projects = $projects; Totals = $totals; FileCount = $fileCount; BuiltAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
'@

  $script:Stats = $null; $script:StatsPS = $null; $script:StatsRS = $null; $script:StatsHandle = $null; $script:StatsBuilding = $false; $script:StatsFP = ''
  # cheap change signal on the UI thread: stream file names + newest mtime (no FileInfo
  # allocation, no transcript read). On any enumeration error keep the last value.
  function Get-StatsFingerprint {
    try {
      $n = 0; $max = 0L
      foreach ($p in [System.IO.Directory]::EnumerateFiles($ProjectsDir, '*.jsonl', [System.IO.SearchOption]::AllDirectories)) {
        $n++; $t = [System.IO.File]::GetLastWriteTimeUtc($p).Ticks; if ($t -gt $max) { $max = $t }
      }
      "$n|$max"
    } catch { $script:StatsFP }
  }
  function Start-StatsBuild {
    if ($script:StatsBuilding) { return }
    $script:StatsBuilding = $true
    try {
      $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
      $ps = [powershell]::Create(); $ps.Runspace = $rs
      [void]$ps.AddScript($script:StatsWorker).AddArgument($ProjectsDir).AddArgument($script:StatsCache)
      $script:StatsPS = $ps; $script:StatsRS = $rs; $script:StatsHandle = $ps.BeginInvoke()
    } catch { $script:StatsBuilding = $false; "[{0}] stats start: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
  }
  # harvest a finished background build; returns $true if fresh stats just arrived
  function Collect-Stats {
    if (-not $script:StatsHandle -or -not $script:StatsHandle.IsCompleted) { return $false }
    $fresh = $false
    try {
      $res = $script:StatsPS.EndInvoke($script:StatsHandle)
      if ($res -and $res.Count) { $script:Stats = $res[$res.Count - 1]; $fresh = $true }
    } catch { "[{0}] stats collect: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
    finally {
      try { $script:StatsPS.Dispose() } catch {}; try { $script:StatsRS.Dispose() } catch {}
      $script:StatsPS = $null; $script:StatsRS = $null; $script:StatsHandle = $null; $script:StatsBuilding = $false
    }
    $fresh
  }

  # ── 3-state model ────────────────────────────────────────────────────────────
  function Get-StateInfo($sess) {
    $loc = Format-Location $sess.Cwd
    if ($sess.Status -eq 'busy') { return @{ Kind = 'work'; Hex = '5AA7E6'; Label = 'working'; Inline = $sess.Meta.Action; Sub = $loc; Sort = 2 } }
    if ($sess.Meta.WaitKind -eq 'attention') { return @{ Kind = 'attn'; Hex = 'E9A94A'; Label = 'needs you'; Inline = $sess.Meta.Action; Sub = $loc; Sort = 0 } }
    if ($sess.Meta.WaitKind -eq 'done') { return @{ Kind = 'done'; Hex = '4FC98A'; Label = 'done'; Inline = $null; Sub = $loc; Sort = 1 } }
    @{ Kind = 'idle'; Hex = '8A909B'; Label = 'ready'; Inline = $null; Sub = $loc; Sort = 3 }
  }

  # ── seen / unseen tracking ───────────────────────────────────────────────────
  $script:Seen = @{}
  function Update-Seen($sessions) {
    $ids = @{}
    foreach ($s in $sessions) {
      $ids[$s.SessionId] = $true
      $eid = "$($s.Status)|$($s.StatusUpdatedAt)"
      $prev = $script:Seen[$s.SessionId]
      if (-not $prev -or $prev.Eid -ne $eid) {
        $notify = ($s.State.Kind -eq 'attn' -or $s.State.Kind -eq 'done')
        $script:Seen[$s.SessionId] = @{ Eid = $eid; Seen = (-not $notify) }
      }
    }
    # external focus clears highlight (user brought the terminal forward
    # themselves). ForegroundTerminalTitle returns "" unless a *Windows Terminal*
    # window is focused, so a browser/editor with a colliding title can't clear a
    # highlight; the WT window's title is its active tab's title.
    $fg = ''; try { $fg = [Pulse.Native]::ForegroundTerminalTitle() } catch {}
    if ($fg) {
      foreach ($s in $sessions) {
        if ($s.Status -ne 'busy' -and -not $script:Seen[$s.SessionId].Seen -and (Tab-Matches $fg $s.Meta.AiTitle)) {
          $script:Seen[$s.SessionId].Seen = $true
        }
      }
    }
    foreach ($s in $sessions) { $s.Unseen = ($s.State.Kind -eq 'attn' -or $s.State.Kind -eq 'done') -and (-not $script:Seen[$s.SessionId].Seen) }
    # prune vanished
    foreach ($k in @($script:Seen.Keys)) { if (-not $ids[$k]) { $script:Seen.Remove($k) } }
  }
  function Mark-Seen([string]$sid) { if ($script:Seen[$sid]) { $script:Seen[$sid].Seen = $true } }

  # ── title matching (exact, tolerant of the leading spinner / ✳ marker) ───────
  # A tab/window title is "<spinner|✳> <aiTitle>". We strip the leading marker
  # (braille spinner U+2800–U+28FF or ✳ U+2733) plus whitespace and compare the
  # remainder for EQUALITY. Exact match (not substring) so two live sessions
  # whose titles overlap — e.g. "Add login" vs "Add login form" — never focus or
  # clear each other. Ordinal comparison, so [ ] ? * in a title are literal.
  function Tab-Matches([string]$title, [string]$aiTitle) {
    if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($aiTitle)) { return $false }
    $core = ($title -replace '^[\s⠀-⣿✳]+', '').Trim()
    $core.Equals($aiTitle.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
  }
  $script:TabCond = $null
  function Get-TabCond {
    if (-not $script:TabCond) {
      $script:TabCond = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    }
    $script:TabCond
  }

  # ── focus a session's Windows Terminal tab (UI Automation) ───────────────────
  # All WT windows share one process, so pid/cwd can't identify a tab — the
  # aiTitle is the only handle. WT exposes its tabs via UIA (TabItem +
  # SelectionItemPattern), so we can activate a tab even when it isn't the active
  # one. Returns $true on success. The only case we can't reach is an inactive
  # tab in a window on another virtual desktop (UIA doesn't populate that tree
  # until the window is on the current desktop, and there is no non-disruptive,
  # stable public API to change that).
  function Focus-TerminalTab([string]$aiTitle) {
    if ([string]::IsNullOrWhiteSpace($aiTitle)) { return $false }
    $wts = @(); try { $wts = [Pulse.Native]::ListTerminalWindows() } catch { return $false }
    if (-not $wts -or $wts.Count -eq 0) { return $false }

    # Pass 1 (cheap, no UIA): the session is the ACTIVE tab of some window. The
    # active tab's title is the window title, readable on any virtual desktop.
    # This is the common case, so we avoid touching UI Automation entirely here.
    foreach ($line in $wts) {
      $p = $line.Split([char]1); if ($p.Count -lt 2) { continue }
      if (Tab-Matches $p[1] $aiTitle) { [void][Pulse.Native]::FocusWindow([long]$p[0]); return $true }
    }

    # Pass 2 (UIA): the session is an INACTIVE tab — find and Select() it. Only
    # windows on the current virtual desktop expose their tab tree; a window on
    # another desktop returns an empty tree and is skipped (the one case we can't
    # reach without a disruptive desktop switch).
    $tabCond = Get-TabCond
    foreach ($line in $wts) {
      $p = $line.Split([char]1); if ($p.Count -lt 2) { continue }
      $hwnd = [long]$p[0]
      $el = $null
      try { $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd) } catch { continue }
      $tabs = $null
      try { $tabs = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond) } catch { $tabs = $null }
      if (-not $tabs -or $tabs.Count -eq 0) { continue }
      foreach ($t in $tabs) {
        $tn = $null; try { $tn = $t.Current.Name } catch { continue }
        if (-not (Tab-Matches $tn $aiTitle)) { continue }
        $si = $null
        if ($t.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$si)) {
          try { if (-not $si.Current.IsSelected) { $si.Select() } } catch {}
        }
        [void][Pulse.Native]::FocusWindow($hwnd)
        return $true
      }
    }
    $false
  }

  function Focus-Session($tag) {
    Mark-Seen $tag.Session.SessionId
    $ok = $false
    try { $ok = Focus-TerminalTab $tag.AiTitle }
    catch { "[{0}] focus error: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
    Refresh $true
    # On failure the flyout keeps focus (no window was raised), so the hint is
    # visible. Show it AFTER Refresh so its bottom-pin is the final layout step.
    if (-not $ok) {
      "[{0}] focus: no reachable tab for '{1}' (title='{2}')" -f (Get-Date -Format o), $tag.Session.Name, $tag.AiTitle | Out-File $LogPath -Append
      if ([string]::IsNullOrWhiteSpace($tag.AiTitle)) { Show-Hint 'Session hat noch keinen Titel – Tab nicht identifizierbar' }
      else { Show-Hint 'Tab nicht erreichbar – evtl. inaktiver Tab auf einem anderen virtuellen Desktop' }
    }
  }

  # ── flyout window ────────────────────────────────────────────────────────────
  [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" ShowInTaskbar="False"
        SizeToContent="Height" Width="500" Topmost="True" Title="Pulse"
        Background="Transparent" TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>
    <!-- Schlanker, abgerundeter Overlay-Scrollbar (ersetzt den breiten WPF-Standard) -->
    <Style x:Key="PulseScrollThumb" TargetType="Thumb">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="MinHeight" Value="28"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Th" CornerRadius="3" Background="#30FFFFFF" Margin="2,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Th" Property="Background" Value="#55FFFFFF"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="Th" Property="Background" Value="#7AFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource PulseScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="PART_Root" Margin="12" CornerRadius="13" Background="#E60D121A" BorderThickness="0">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="6" Direction="270" Opacity="0.55" Color="#000000"/></Border.Effect>
    <Border x:Name="PART_Tint" CornerRadius="13">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#4A18212C" Offset="0"/>
          <GradientStop Color="#660E141C" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    <StackPanel>
      <Grid Margin="18,15,14,11">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" Grid.Column="0">
          <Viewbox Width="22" Height="22" VerticalAlignment="Center">
            <Image x:Name="PART_Logo" Stretch="Uniform"/>
          </Viewbox>
          <TextBlock Text="Pulse" Foreground="#F4F6F8" FontFamily="Segoe UI" FontSize="15.5" FontWeight="SemiBold" Margin="11,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Border x:Name="PART_Toggle" Grid.Column="1" VerticalAlignment="Center"/>
      </Grid>
      <Border x:Name="PART_Usage" Margin="18,6,18,10"/>
      <Grid>
        <ScrollViewer x:Name="PART_ListScroll" MaxHeight="470" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PART_List" Margin="0,4,0,10"/>
        </ScrollViewer>
        <ScrollViewer x:Name="PART_StatsScroll" MaxHeight="500" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel x:Name="PART_Stats" Margin="0,4,0,12"/>
        </ScrollViewer>
        <ScrollViewer x:Name="PART_ZeitenScroll" MaxHeight="500" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel x:Name="PART_Zeiten" Margin="0,4,0,12"/>
        </ScrollViewer>
      </Grid>
      <TextBlock x:Name="PART_Hint" Visibility="Collapsed" Foreground="#8A909B" FontFamily="Segoe UI"
                 FontSize="11.5" TextWrapping="Wrap" Margin="19,0,16,12"/>
    </StackPanel>
    </Border>
  </Border>
</Window>
"@
  $reader = [System.Xml.XmlNodeReader]::new($xaml)
  $script:Win = [System.Windows.Markup.XamlReader]::Load($reader)
  $script:PartList        = $script:Win.FindName('PART_List')
  $script:PartStats       = $script:Win.FindName('PART_Stats')
  $script:PartListScroll  = $script:Win.FindName('PART_ListScroll')
  $script:PartStatsScroll = $script:Win.FindName('PART_StatsScroll')
  $script:PartZeiten       = $script:Win.FindName('PART_Zeiten')
  $script:PartZeitenScroll = $script:Win.FindName('PART_ZeitenScroll')
  $script:PartUsage       = $script:Win.FindName('PART_Usage')
  $script:PartToggle      = $script:Win.FindName('PART_Toggle')
  $script:PartHint        = $script:Win.FindName('PART_Hint')
  $script:PartRoot        = $script:Win.FindName('PART_Root')
  $script:PartRoot.Add_SizeChanged({ Update-FrostViewbox })
  $script:View            = 'agents'   # 'agents' | 'stats' | 'zeiten'
  $logoEl = $script:Win.FindName('PART_Logo')
  $logoEl.Source = (New-GlyphImage 64)

  # ── dezenter, nicht-modaler Hinweis im Flyout (ersetzt die störende Toast) ───
  # The flyout is bottom-anchored (SizeToContent=Height). Toggling the hint would
  # grow/shrink the window downward past the taskbar, so we pin the bottom edge:
  # remember it, change visibility, then move Top so the bottom stays put.
  $script:HintTimer = $null
  function Keep-Bottom([scriptblock]$change) {
    $vis = $script:Win -and $script:Win.IsVisible
    $bottom = if ($vis) { $script:Win.Top + $script:Win.ActualHeight } else { 0 }
    & $change
    if ($vis) {
      $script:Win.UpdateLayout(); $script:Win.Top = $bottom - $script:Win.ActualHeight
      $script:Win.Dispatcher.BeginInvoke([System.Action] { Update-FrostViewbox }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
    }
  }
  function Hide-Hint {
    if ($script:HintTimer) { $script:HintTimer.Stop() }
    if ($script:PartHint) { Keep-Bottom { $script:PartHint.Visibility = [System.Windows.Visibility]::Collapsed } }
  }
  function Show-Hint([string]$msg) {
    if (-not $script:PartHint) { return }
    Keep-Bottom {
      $script:PartHint.Text = $msg
      $script:PartHint.Visibility = [System.Windows.Visibility]::Visible
    }
    if (-not $script:HintTimer) {
      $script:HintTimer = [System.Windows.Threading.DispatcherTimer]::new()
      $script:HintTimer.Interval = [TimeSpan]::FromSeconds(4)
      $script:HintTimer.Add_Tick({ Hide-Hint })
    }
    $script:HintTimer.Stop(); $script:HintTimer.Start()
  }

  # ── usage + statistics UI ────────────────────────────────────────────────────
  $script:AC     = '#E8ECF2'   # near-white accent (monochrome, openai b/w style)
  $script:CalPal = @('#12FFFFFF', '#2EFFFFFF', '#55FFFFFF', '#8AFFFFFF', '#D2FFFFFF')  # activity ramp (none → max), white-opacity
  function Model-Hex([string]$m) {
    switch -Wildcard ($m) {
      '*opus*'   { '#E8ECF2' } '*sonnet*' { '#B4BAC4' } '*haiku*' { '#8A919B' }
      '*fable*'  { '#666D77' } '*gpt*'    { '#4C535B' } default { '#5E636D' }
    }
  }
  function Model-Short([string]$m) {
    if ($m -match 'opus') { 'Opus' } elseif ($m -match 'sonnet') { 'Sonnet' } elseif ($m -match 'haiku') { 'Haiku' }
    elseif ($m -match 'fable') { 'Fable' } elseif ($m -eq '<synthetic>') { $m } else { ($m -replace '^claude-', '') }
  }
  function Get-Level([double]$v, [double]$max) {
    if ($v -le 0 -or $max -le 0) { return 0 }
    [int][math]::Min(4, [math]::Ceiling($v / $max * 4))
  }
  function Fmt-Reset([int64]$resetsAtSec) {
    $ms = $resetsAtSec * 1000L
    $rem = $ms - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($rem -le 0) { return $null }
    $min = [int][math]::Floor($rem / 60000)
    if ($min -lt 60) { "{0}m" -f $min } else { "{0}h {1}m" -f [int][math]::Floor($min / 60), ($min % 60) }
  }
  # a proportional bar that scales with its container (star columns, no pixel math)
  function New-Bar([double]$pct, [string]$hex, [double]$h = 6, [string]$track = '#1EFFFFFF') {
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    $b = [System.Windows.Controls.Border]::new(); $b.Height = $h; $b.CornerRadius = [System.Windows.CornerRadius]::new($h / 2)
    $b.Background = (Brush $track); $b.ClipToBounds = $true
    $g = [System.Windows.Controls.Grid]::new()
    $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new($pct, [System.Windows.GridUnitType]::Star)
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(100 - $pct, [System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    $fill = [System.Windows.Controls.Border]::new(); $fill.CornerRadius = [System.Windows.CornerRadius]::new($h / 2); $fill.Background = (Brush $hex)
    [System.Windows.Controls.Grid]::SetColumn($fill, 0); $g.Children.Add($fill) | Out-Null
    $b.Child = $g; $b
  }
  function New-SectionTitle([string]$t) {
    $tracked = ($t.ToUpper().ToCharArray() -join [char]0x200A)   # hair-space tracking for refined caps
    $x = New-Text -Text $tracked -Fg '#89909C' -Size 10 -Semi
    $x.Margin = [System.Windows.Thickness]::new(18, 17, 16, 8)
    try { $x.SetValue([System.Windows.Controls.TextBlock]::TextAlignmentProperty, [System.Windows.TextAlignment]::Left) } catch {}
    $x
  }
  function Level-Hex([double]$v, [double]$max) { $script:CalPal[(Get-Level $v $max)] }

  # one usage gauge (5h / weekly); $u = @{pct;resetsAt} or $null
  function New-UsageMeter([string]$label, $u) {
    $sp = [System.Windows.Controls.StackPanel]::new()
    $top = [System.Windows.Controls.Grid]::new()
    foreach ($w in '*', 'Auto') {
      $cd = [System.Windows.Controls.ColumnDefinition]::new()
      $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
      $top.ColumnDefinitions.Add($cd)
    }
    $lab = New-Text -Text $label -Fg '#8B929D' -Size 10.5
    $lab.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom; $lab.Margin = [System.Windows.Thickness]::new(0, 0, 0, 1)
    [System.Windows.Controls.Grid]::SetColumn($lab, 0)
    $hasData = ($null -ne $u -and $null -ne $u.pct)
    $pct = if ($hasData) { [double]$u.pct } else { 0 }
    $reset = if ($hasData -and $u.resetsAt) { Fmt-Reset ([int64]$u.resetsAt) } else { $null }
    $stale = ($hasData -and $u.resetsAt -and -not $reset)   # window elapsed since capture
    $hex = if (-not $hasData -or $stale) { '#5E636D' } elseif ($pct -ge 85) { '#E06B6B' } elseif ($pct -ge 60) { '#E9A94A' } else { '#4FC98A' }
    $valTxt = if ($hasData) { '{0:0}%' -f $pct } else { '—' }
    $val = New-Text -Text $valTxt -Fg $(if ($hasData -and -not $stale) { $hex } else { '#7C828D' }) -Size 15 -Semi -Mono
    $val.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    [System.Windows.Controls.Grid]::SetColumn($val, 1)
    $top.Children.Add($lab) | Out-Null; $top.Children.Add($val) | Out-Null
    $bar = New-Bar $pct $hex 5
    $bar.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $subTxt = if (-not $hasData) { 'kein Wert' } elseif ($stale) { '↺ Reset fällig' } elseif ($reset) { "↺ in $reset" } else { '' }
    $sub = New-Text -Text $subTxt -Fg '#6E7580' -Size 9.5 -Mono; $sub.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $sp.Children.Add($top) | Out-Null; $sp.Children.Add($bar) | Out-Null; $sp.Children.Add($sub) | Out-Null
    $sp
  }

  # the always-visible usage strip: exact meters, an enable CTA, or a wait/notice line
  $script:UsageSig = '<init>'
  function Update-Usage([bool]$force) {
    $state = Get-BridgeState
    $u = if ($state -eq 'ours') { Read-UsageOfficial } else { $null }
    $five  = if ($u) { $u.fiveHour } else { $null }
    $seven = if ($u) { $u.sevenDay } else { $null }
    $sig = '{0}|{1}|{2}|{3}|{4}' -f $state,
      $(if ($five) { '{0:0}/{1}' -f [double]$five.pct, (Fmt-Reset ([int64]$five.resetsAt)) } else { '-' }),
      $(if ($seven) { '{0:0}/{1}' -f [double]$seven.pct, (Fmt-Reset ([int64]$seven.resetsAt)) } else { '-' }),
      $(if ($u) { 'd' } else { 'n' }), ''
    if (-not $force -and $sig -eq $script:UsageSig) { return }
    $script:UsageSig = $sig

    if ($state -eq 'ours' -and ($five -or $seven)) {
      $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(5, 4, 5, 2)
      foreach ($w in '*', 'Auto', '*') {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
      }
      $m5 = New-UsageMeter '5-Stunden-Fenster' $five; [System.Windows.Controls.Grid]::SetColumn($m5, 0)
      $m7 = New-UsageMeter 'Woche' $seven;        [System.Windows.Controls.Grid]::SetColumn($m7, 2)
      $gap = [System.Windows.Controls.Border]::new(); $gap.Width = 26; [System.Windows.Controls.Grid]::SetColumn($gap, 1)
      $g.Children.Add($m5) | Out-Null; $g.Children.Add($gap) | Out-Null; $g.Children.Add($m7) | Out-Null
      $script:PartUsage.Child = $g
    }
    elseif ($state -eq 'ours') {
      $t = New-Text -Text '⏳  Warte auf erste Claude-Code-Antwort … (Auslastung erscheint nach dem ersten Turn)' -Fg '#7C828D' -Size 11
      $t.Margin = [System.Windows.Thickness]::new(9, 6, 9, 6); $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $script:PartUsage.Child = $t
    }
    elseif ($state -eq 'foreign') {
      $t = New-Text -Text 'Eigene statusLine aktiv – exakte Auslastung nicht abgreifbar (Pulse fasst deine Konfiguration nicht an).' -Fg '#7C828D' -Size 11
      $t.Margin = [System.Windows.Thickness]::new(9, 6, 9, 6); $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $script:PartUsage.Child = $t
    }
    else {
      $cta = [System.Windows.Controls.Border]::new()
      $cta.CornerRadius = [System.Windows.CornerRadius]::new(9); $cta.Cursor = [System.Windows.Input.Cursors]::Hand
      $cta.Background = (Brush '#16FFFFFF'); $cta.BorderBrush = (Brush '#26FFFFFF'); $cta.BorderThickness = [System.Windows.Thickness]::new(1)
      $cta.Padding = [System.Windows.Thickness]::new(12, 9, 12, 9)
      $cta.Margin = [System.Windows.Thickness]::new(3, 3, 3, 2)
      $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
      $t1 = New-Text -Text '◷  Exakte 5h- & Wochen-Auslastung aktivieren' -Fg $script:AC -Size 12 -Semi
      $t2 = New-Text -Text '›' -Fg $script:AC -Size 14 -Semi; $t2.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
      $row.Children.Add($t1) | Out-Null; $row.Children.Add($t2) | Out-Null
      $cta.Child = $row
      $cta.Add_MouseLeftButtonUp({ param($s, $e) Enable-Bridge })
      $cta.Add_MouseEnter({ param($s, $e) $s.Background = (Brush '#24FFFFFF') })
      $cta.Add_MouseLeave({ param($s, $e) $s.Background = (Brush '#16FFFFFF') })
      $script:PartUsage.Child = $cta
    }
  }
  function Enable-Bridge {
    if (Install-Bridge) {
      $script:UsageSig = '<init>'; Update-Usage $true
      Show-Hint 'Aktiviert. Die exakten Werte erscheinen nach dem nächsten Turn in einer laufenden Claude-Code-Session.'
    } else { Show-Hint 'Konnte settings.json nicht schreiben – siehe %TEMP%\Pulse.log' }
  }

  # ── Agents | Statistik | Zeiten — minimal underline tabs ─────────────────────
  function Set-Toggle {
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $segs = @(@('agents', 'Agents'), @('stats', 'Statistik'), @('zeiten', 'Zeiten'))
    for ($i = 0; $i -lt $segs.Count; $i++) {
      $seg = $segs[$i]; $active = ($script:View -eq $seg[0])
      $tab = [System.Windows.Controls.Border]::new()
      $tab.Background = (Brush '#00000000'); $tab.Cursor = [System.Windows.Input.Cursors]::Hand
      $tab.Padding = [System.Windows.Thickness]::new(2, 2, 2, 2)
      $tab.Margin = [System.Windows.Thickness]::new(0, 0, $(if ($i -lt $segs.Count - 1) { 16 } else { 0 }), 0)
      $t = New-Text -Text $seg[1] -Fg $(if ($active) { '#F4F6F8' } else { '#787F8A' }) -Size 12.5 -Semi
      $tab.Child = $t
      $tab.Tag = [pscustomobject]@{ View = $seg[0]; Rest = $(if ($active) { '#F4F6F8' } else { '#787F8A' }) }
      $tab.Add_MouseLeftButtonUp({ param($s, $e) Switch-View $s.Tag.View })
      if (-not $active) {
        $tab.Add_MouseEnter({ param($s, $e) Fade-Brush $s.Child.Foreground '#C6CCD5' 140 })
        $tab.Add_MouseLeave({ param($s, $e) Fade-Brush $s.Child.Foreground $s.Tag.Rest 170 })
      }
      $sp.Children.Add($tab) | Out-Null
    }
    $script:PartToggle.Child = $sp
  }
  function Switch-View([string]$v) {
    if ($v -eq $script:View) { return }
    $script:View = $v
    Keep-Bottom {
      $script:PartListScroll.Visibility = [System.Windows.Visibility]::Collapsed
      $script:PartStatsScroll.Visibility = [System.Windows.Visibility]::Collapsed
      $script:PartZeitenScroll.Visibility = [System.Windows.Visibility]::Collapsed
      if ($v -eq 'stats') {
        $script:PartStatsScroll.Visibility = [System.Windows.Visibility]::Visible
        Ensure-Stats; Rebuild-Stats
      } elseif ($v -eq 'zeiten') {
        $script:PartZeitenScroll.Visibility = [System.Windows.Visibility]::Visible
        Ensure-Zeiten; Rebuild-Zeiten
      } else {
        $script:PartListScroll.Visibility = [System.Windows.Visibility]::Visible
      }
      Set-Toggle
    }
  }
  function Ensure-Stats {
    if (-not $script:Stats -and -not $script:StatsBuilding) { $script:StatsFP = Get-StatsFingerprint; Start-StatsBuild }
  }

  # ── statistics panels ─────────────────────────────────────────────────────────
  function New-Cell([double]$sz, [string]$hex, [string]$tip) {
    $c = [System.Windows.Controls.Border]::new(); $c.Width = $sz; $c.Height = $sz
    $c.CornerRadius = [System.Windows.CornerRadius]::new(2.5); $c.Background = (Brush $hex)
    $c.Margin = [System.Windows.Thickness]::new(1.5)
    if ($tip) { $c.ToolTip = $tip }
    $c
  }
  function New-Tile([string]$big, [string]$label, [string]$hex) {
    $sp = [System.Windows.Controls.StackPanel]::new()
    $n = New-Text -Text $big -Fg $hex -Size 21 -Semi -Mono
    $l = New-Text -Text $label -Fg '#787F8A' -Size 10.5; $l.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $sp.Children.Add($n) | Out-Null; $sp.Children.Add($l) | Out-Null; $sp
  }
  # contribution calendar (weeks × weekdays) with month + weekday labels
  function New-CalendarPanel($days) {
    $weeks = 26; $sz = 12.0; $pitch = $sz + 3.0; $wdColW = 22.0
    $today = [datetime]::Today
    $monThisWeek = $today.AddDays(-((([int]$today.DayOfWeek) + 6) % 7))
    $start = $monThisWeek.AddDays(-7 * ($weeks - 1))
    $max = 1.0
    for ($i = 0; $i -lt ($weeks * 7); $i++) {
      $d = $start.AddDays($i); if ($d -gt $today) { break }
      $k = $d.ToString('yyyy-MM-dd'); if ($days.ContainsKey($k)) { $m = [double]$days[$k].Msgs; if ($m -gt $max) { $max = $m } }
    }
    $wrap = [System.Windows.Controls.StackPanel]::new(); $wrap.Margin = [System.Windows.Thickness]::new(18, 2, 16, 0)

    # month labels, positioned above the column where each month begins
    $mHead = [System.Windows.Controls.StackPanel]::new(); $mHead.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $mSpacer = [System.Windows.Controls.Border]::new(); $mSpacer.Width = $wdColW; $mHead.Children.Add($mSpacer) | Out-Null
    $mCanvas = [System.Windows.Controls.Canvas]::new(); $mCanvas.Width = $weeks * $pitch; $mCanvas.Height = 14
    $prevMo = $start.Month; $lastX = -100.0   # skip the leading partial month
    for ($w = 0; $w -lt $weeks; $w++) {
      $cd = $start.AddDays($w * 7)
      if ($cd.Month -ne $prevMo -and (($w * $pitch) - $lastX) -ge 22) {
        $ml = New-Text -Text ($cd.ToString('MMM', $script:DE)) -Fg '#787F8A' -Size 9
        [System.Windows.Controls.Canvas]::SetLeft($ml, $w * $pitch); [System.Windows.Controls.Canvas]::SetTop($ml, 0)
        $mCanvas.Children.Add($ml) | Out-Null; $lastX = $w * $pitch
      }
      $prevMo = $cd.Month
    }
    $mHead.Children.Add($mCanvas) | Out-Null; $wrap.Children.Add($mHead) | Out-Null

    # weekday labels (left) + week columns
    $main = [System.Windows.Controls.StackPanel]::new(); $main.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $wdCol = [System.Windows.Controls.StackPanel]::new(); $wdCol.Width = $wdColW; $wdCol.Margin = [System.Windows.Thickness]::new(0, 1.5, 0, 0)
    $wdNames = @('Mo', '', 'Mi', '', 'Fr', '', '')
    for ($d = 0; $d -lt 7; $d++) {
      $cellBox = [System.Windows.Controls.Border]::new(); $cellBox.Height = $pitch
      if ($wdNames[$d]) { $tl = New-Text -Text $wdNames[$d] -Fg '#5E636D' -Size 9; $tl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $cellBox.Child = $tl }
      $wdCol.Children.Add($cellBox) | Out-Null
    }
    $main.Children.Add($wdCol) | Out-Null
    for ($w = 0; $w -lt $weeks; $w++) {
      $col = [System.Windows.Controls.StackPanel]::new()
      for ($d = 0; $d -lt 7; $d++) {
        $date = $start.AddDays($w * 7 + $d)
        if ($date -gt $today) { $col.Children.Add((New-Cell $sz '#00000000' $null)) | Out-Null; continue }
        $k = $date.ToString('yyyy-MM-dd')
        $m = if ($days.ContainsKey($k)) { [double]$days[$k].Msgs } else { 0 }
        $tip = if ($m -gt 0) { "{0}: {1} Nachrichten" -f $date.ToString('dd.MM.yyyy'), [int]$m } else { $date.ToString('dd.MM.yyyy') }
        $col.Children.Add((New-Cell $sz (Level-Hex $m $max) $tip)) | Out-Null
      }
      $main.Children.Add($col) | Out-Null
    }
    $wrap.Children.Add($main) | Out-Null

    # legend
    $leg = [System.Windows.Controls.StackPanel]::new(); $leg.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $leg.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right; $leg.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $leg.Children.Add((New-Text -Text 'weniger ' -Fg '#6C727C' -Size 9.5)) | Out-Null
    foreach ($h in $script:CalPal) { $leg.Children.Add((New-Cell 10 $h $null)) | Out-Null }
    $leg.Children.Add((New-Text -Text ' mehr' -Fg '#6C727C' -Size 9.5)) | Out-Null
    $wrap.Children.Add($leg) | Out-Null; $wrap
  }
  # last-30-days message bars, with an average reference line and date context
  function New-ActivityPanel($days) {
    $n = 30; $today = [datetime]::Today; $max = 1.0; $sum = 0.0; $chartH = 60.0
    for ($i = 0; $i -lt $n; $i++) { $k = $today.AddDays(-$i).ToString('yyyy-MM-dd'); $m = if ($days.ContainsKey($k)) { [double]$days[$k].Msgs } else { 0 }; $sum += $m; if ($m -gt $max) { $max = $m } }
    $avg = $sum / $n
    $overlay = [System.Windows.Controls.Grid]::new(); $overlay.Height = $chartH; $overlay.Margin = [System.Windows.Thickness]::new(18, 4, 16, 0)
    $g = [System.Windows.Controls.Grid]::new()
    for ($i = 0; $i -lt $n; $i++) { $g.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) }
    for ($i = 0; $i -lt $n; $i++) {
      $date = $today.AddDays(-($n - 1 - $i)); $k = $date.ToString('yyyy-MM-dd')
      $m = if ($days.ContainsKey($k)) { [double]$days[$k].Msgs } else { 0 }
      $bar = [System.Windows.Controls.Border]::new()
      $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
      $bar.Height = [math]::Max(2, ($m / $max) * $chartH)
      $bar.CornerRadius = [System.Windows.CornerRadius]::new(2, 2, 0, 0)
      $bar.Background = (Brush $(if ($m -gt 0) { $script:AC } else { '#14FFFFFF' }))
      $bar.Margin = [System.Windows.Thickness]::new(1.5, 0, 1.5, 0)
      if ($m -gt 0) { $bar.ToolTip = "{0}: {1} Nachrichten" -f $date.ToString('dd.MM.'), [int]$m }
      [System.Windows.Controls.Grid]::SetColumn($bar, $i); $g.Children.Add($bar) | Out-Null
    }
    $overlay.Children.Add($g) | Out-Null
    if ($avg -gt 0) {
      $line = [System.Windows.Controls.Border]::new(); $line.Height = 1; $line.Background = (Brush '#3EFFFFFF')
      $line.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom; $line.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
      $line.Margin = [System.Windows.Thickness]::new(0, 0, 0, ($avg / $max) * $chartH)
      $overlay.Children.Add($line) | Out-Null
    }
    $lab = [System.Windows.Controls.Grid]::new(); $lab.Margin = [System.Windows.Thickness]::new(18, 5, 16, 0)
    foreach ($w in '*', 'Auto', '*') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }; $lab.ColumnDefinitions.Add($cd) }
    $l0 = New-Text -Text ($today.AddDays(-($n - 1)).ToString('dd.MM.', $script:DE)) -Fg '#6C727C' -Size 9; [System.Windows.Controls.Grid]::SetColumn($l0, 0)
    $lm = New-Text -Text ("Ø {0:0}/Tag" -f $avg) -Fg '#787F8A' -Size 9; $lm.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; [System.Windows.Controls.Grid]::SetColumn($lm, 1)
    $l1 = New-Text -Text 'heute' -Fg '#6C727C' -Size 9; $l1.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right; [System.Windows.Controls.Grid]::SetColumn($l1, 2)
    $lab.Children.Add($l0) | Out-Null; $lab.Children.Add($lm) | Out-Null; $lab.Children.Add($l1) | Out-Null
    $wrap = [System.Windows.Controls.StackPanel]::new(); $wrap.Children.Add($overlay) | Out-Null; $wrap.Children.Add($lab) | Out-Null; $wrap
  }
  function New-ModelPanel($models) {
    $items = @($models.GetEnumerator() | Where-Object { $_.Key -ne '<synthetic>' -and [double]$_.Value -gt 0 } | Sort-Object { [double]$_.Value } -Descending)
    if (-not $items.Count) { return (New-Text -Text 'keine Modelldaten' -Fg '#6C727C' -Size 11) }
    $total = 0.0; foreach ($it in $items) { $total += [double]$it.Value }
    $stack = [System.Windows.Controls.Border]::new(); $stack.Height = 12; $stack.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $stack.ClipToBounds = $true; $stack.Margin = [System.Windows.Thickness]::new(19, 2, 16, 0)
    $sg = [System.Windows.Controls.Grid]::new()
    $col = 0
    foreach ($it in $items) {
      $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = [System.Windows.GridLength]::new([double]$it.Value, [System.Windows.GridUnitType]::Star)
      $sg.ColumnDefinitions.Add($cd)
      $seg = [System.Windows.Controls.Border]::new(); $seg.Background = (Brush (Model-Hex $it.Key))
      [System.Windows.Controls.Grid]::SetColumn($seg, $col); $sg.Children.Add($seg) | Out-Null; $col++
    }
    $stack.Child = $sg
    $leg = [System.Windows.Controls.WrapPanel]::new(); $leg.Margin = [System.Windows.Thickness]::new(19, 8, 16, 0)
    foreach ($it in $items) {
      $pct = [double]$it.Value / $total * 100
      $item = [System.Windows.Controls.StackPanel]::new(); $item.Orientation = [System.Windows.Controls.Orientation]::Horizontal; $item.Margin = [System.Windows.Thickness]::new(0, 0, 14, 4)
      $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 8; $dot.Height = 8; $dot.Fill = (Brush (Model-Hex $it.Key)); $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
      $lbl = New-Text -Text ("{0} {1:0}%" -f (Model-Short $it.Key), $pct) -Fg '#9AA0AA' -Size 10.5; $lbl.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
      $item.Children.Add($dot) | Out-Null; $item.Children.Add($lbl) | Out-Null; $leg.Children.Add($item) | Out-Null
    }
    $wrap = [System.Windows.Controls.StackPanel]::new(); $wrap.Children.Add($stack) | Out-Null; $wrap.Children.Add($leg) | Out-Null; $wrap
  }
  function New-HoursPanel($hours) {
    $max = 1.0; for ($h = 0; $h -lt 24; $h++) { if ($hours.ContainsKey($h)) { $v = [double]$hours[$h]; if ($v -gt $max) { $max = $v } } }
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal; $row.Margin = [System.Windows.Thickness]::new(19, 2, 14, 0)
    for ($h = 0; $h -lt 24; $h++) {
      $v = if ($hours.ContainsKey($h)) { [double]$hours[$h] } else { 0 }
      $row.Children.Add((New-Cell 13 (Level-Hex $v $max) ("{0:00}:00 – {1} Aktionen" -f $h, [int]$v))) | Out-Null
    }
    $labels = [System.Windows.Controls.Grid]::new(); $labels.Margin = [System.Windows.Thickness]::new(19, 3, 14, 0)
    for ($i = 0; $i -lt 24; $i++) { $labels.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) }
    foreach ($h in 0, 6, 12, 18) {
      $t = New-Text -Text ("{0:00}" -f $h) -Fg '#6C727C' -Size 9; [System.Windows.Controls.Grid]::SetColumn($t, $h); $labels.Children.Add($t) | Out-Null
    }
    $wrap = [System.Windows.Controls.StackPanel]::new(); $wrap.Children.Add($row) | Out-Null; $wrap.Children.Add($labels) | Out-Null; $wrap
  }
  function New-ProjectsPanel($projects) {
    $items = @($projects.GetEnumerator() | Sort-Object { [double]$_.Value.Tok } -Descending | Select-Object -First 6)
    if (-not $items.Count) { return (New-Text -Text 'keine Projektdaten' -Fg '#6C727C' -Size 11) }
    $max = [double]($items[0].Value.Tok); if ($max -le 0) { $max = 1 }
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Margin = [System.Windows.Thickness]::new(19, 2, 16, 0)
    foreach ($it in $items) {
      $name = Format-Location $it.Key; if (-not $name) { $name = Split-Path $it.Key -Leaf }
      $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)
      foreach ($w in '*', 'Auto') {
        $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
      }
      $nm = New-Text -Text (Short $name 30) -Fg '#AEB4BD' -Size 11.5; [System.Windows.Controls.Grid]::SetColumn($nm, 0)
      $tk = New-Text -Text (Format-Tok ([double]$it.Value.Tok)) -Fg '#7C828D' -Size 10.5 -Mono; [System.Windows.Controls.Grid]::SetColumn($tk, 1)
      $g.Children.Add($nm) | Out-Null; $g.Children.Add($tk) | Out-Null
      $bar = New-Bar (([double]$it.Value.Tok / $max) * 100) $script:AC 5; $bar.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
      $blk = [System.Windows.Controls.StackPanel]::new(); $blk.Children.Add($g) | Out-Null; $blk.Children.Add($bar) | Out-Null
      $sp.Children.Add($blk) | Out-Null
    }
    $sp
  }
  function New-LiveTiles($stats) {
    $active = @($script:LastSessions | Where-Object { $_.State.Kind -eq 'work' -or $_.State.Kind -eq 'attn' }).Count
    $today = [datetime]::Today.ToString('yyyy-MM-dd')
    $todayMsgs = if ($stats.Days.ContainsKey($today)) { [int]$stats.Days[$today].Msgs } else { 0 }
    $weekTok = 0.0; for ($i = 0; $i -lt 7; $i++) { $k = [datetime]::Today.AddDays(-$i).ToString('yyyy-MM-dd'); if ($stats.Days.ContainsKey($k)) { $weekTok += [double]$stats.Days[$k].Tok } }
    $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(18, 2, 16, 0)
    for ($i = 0; $i -lt 4; $i++) { $g.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) }
    $tiles = @(
      (New-Tile ([string]$active) 'aktiv jetzt' '#F4F6F8'),
      (New-Tile ([string]$todayMsgs) 'Nachr. heute' '#F4F6F8'),
      (New-Tile (Format-Tok $weekTok) 'Tokens · 7 Tage' '#F4F6F8'),
      (New-Tile ([string]$stats.Totals.Messages) 'Nachr. gesamt' '#F4F6F8')
    )
    for ($i = 0; $i -lt 4; $i++) { [System.Windows.Controls.Grid]::SetColumn($tiles[$i], $i); $g.Children.Add($tiles[$i]) | Out-Null }
    $g
  }
  function Rebuild-Stats {
    $script:PartStats.Children.Clear()
    if (-not $script:Stats) {
      $e = New-Text -Text 'Berechne Statistik …' -Fg '#8A909B' -Size 12.5
      $e.Margin = [System.Windows.Thickness]::new(19, 16, 0, 20); $script:PartStats.Children.Add($e) | Out-Null
      return
    }
    $s = $script:Stats
    $add = { param($el) $script:PartStats.Children.Add($el) | Out-Null }
    & $add (New-LiveTiles $s)
    & $add (New-SectionTitle 'Aktivität (Nachrichten / Tag)')
    & $add (New-CalendarPanel $s.Days)
    & $add (New-SectionTitle 'Letzte 30 Tage')
    & $add (New-ActivityPanel $s.Days)
    & $add (New-SectionTitle 'Modelle (Tokens)')
    & $add (New-ModelPanel $s.Models)
    & $add (New-SectionTitle 'Aktivität nach Tageszeit')
    & $add (New-HoursPanel $s.Hours)
    & $add (New-SectionTitle 'Top-Projekte (Tokens)')
    & $add (New-ProjectsPanel $s.Projects)
  }

  # ── Zeiten (Projektzeiten) ─────────────────────────────────────────────────────
  # Facts-first time sheet: scan ONE week's transcripts on a background runspace and
  # split each work item's activity into blocks (a gap > 30 min starts a new block).
  # Per day we show two honest figures — Präsenz (union wall-clock) and Aufwand Σ
  # (sum of blocks; may exceed Präsenz when tickets ran in parallel). Nothing is
  # estimated or auto-apportioned; the reader interprets the gaps and books.
  $script:DE = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
  $script:ZTrackW = 300.0
  function QH([double]$min) { [math]::Round($min / 15.0) * 0.25 }              # minutes → hours on the quarter-hour grid
  function Fmt-Q([double]$hours) { ('{0:0.00}' -f $hours) -replace '\.', ',' } # German decimal comma
  function Fmt-HM($d) { $d.ToString('HH:mm') }
  function Week-Monday($d) { $d.Date.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) }

  $script:ZeitenWorker = @'
param($ProjectsDir, $WeekStartTicks, $WeekEndTicks)
$ws = [datetime]::new([int64]$WeekStartTicks); $we = [datetime]::new([int64]$WeekEndTicks)
$rxTs  = [regex]'"timestamp":"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
$rxCwd = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
# cwd (fallback: the project folder slug) → work item, or $null to drop it entirely.
function Classify($cwd, $slug) {
  if ($slug -eq 'subagents' -or $slug -like 'wf_*') { return $null }           # sub-agent / workflow transcripts: already inside a ticket
  $probe = if ($cwd) { $cwd } else { $slug }
  if ($probe -match '(?i)benchwork') { return $null }                          # automated benchmark runs
  if ($probe -match '(?i)[\\/]playground([\\/]|$)') { return $null }           # private
  if ($cwd -and $cwd -match '[\\/]workspaces[\\/](?:\d{4}[\\/])?(\d{6})') { return @{ Kind='ticket'; Ticket=$Matches[1]; Label=$Matches[1]; Key=('T:' + $Matches[1]) } }
  $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { $slug }
  @{ Kind='intern'; Ticket=$null; Label=$leaf; Key=('I:' + $(if ($cwd) { $cwd } else { $slug })) }
}
$acc = @{}
foreach ($f in (Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
  if ($f.LastWriteTime -lt $ws) { continue }                                   # last write before the week → no in-week lines possible
  $slug = $f.Directory.Name; $cwd = $null
  $ftimes = [System.Collections.Generic.List[datetime]]::new()
  try {
    $fs = [System.IO.FileStream]::new($f.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
      $sr = [System.IO.StreamReader]::new($fs)
      try {
        while ($null -ne ($ln = $sr.ReadLine())) {
          if (-not $cwd) { $mc = $rxCwd.Match($ln); if ($mc.Success) { $cwd = $mc.Groups[1].Value -replace '\\\\','\' } }
          $mt = $rxTs.Match($ln); if (-not $mt.Success) { continue }
          $loc = ([datetime]::new([int]$mt.Groups[1].Value,[int]$mt.Groups[2].Value,[int]$mt.Groups[3].Value,[int]$mt.Groups[4].Value,[int]$mt.Groups[5].Value,[int]$mt.Groups[6].Value,[System.DateTimeKind]::Utc)).ToLocalTime()
          if ($loc -ge $ws -and $loc -lt $we) { $ftimes.Add($loc) }
        }
      } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
  } catch { continue }
  if ($ftimes.Count -eq 0) { continue }
  $info = Classify $cwd $slug; if (-not $info) { continue }
  if (-not $acc.ContainsKey($info.Key)) { $acc[$info.Key] = @{ Info=$info; Times=[System.Collections.Generic.List[datetime]]::new() } }
  $acc[$info.Key].Times.AddRange($ftimes)
}
$GapMin = 30.0; $days = @{}
foreach ($e in $acc.Values) {
  $info = $e.Info; $arr = $e.Times.ToArray(); [Array]::Sort($arr)
  $byDay = @{}
  foreach ($t in $arr) { $dk = $t.ToString('yyyy-MM-dd'); if (-not $byDay.ContainsKey($dk)) { $byDay[$dk] = [System.Collections.Generic.List[datetime]]::new() }; $byDay[$dk].Add($t) }
  foreach ($dk in $byDay.Keys) {
    $ts = $byDay[$dk]; $blocks = [System.Collections.Generic.List[object]]::new()
    $start = $ts[0]; $prev = $ts[0]
    for ($i = 1; $i -lt $ts.Count; $i++) { if (($ts[$i] - $prev).TotalMinutes -gt $GapMin) { $blocks.Add(@{ Von=$start; Bis=$prev; Min=($prev-$start).TotalMinutes }); $start=$ts[$i] }; $prev=$ts[$i] }
    $blocks.Add(@{ Von=$start; Bis=$prev; Min=($prev-$start).TotalMinutes })
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $blocks) { if (($b.Bis - $b.Von).TotalMinutes -ge 1) { $kept.Add($b) } }  # drop sub-minute touches (single commands, not bookable)
    if ($kept.Count -eq 0) { continue }
    $tot = 0.0; foreach ($b in $kept) { $tot += $b.Min }
    if (-not $days.ContainsKey($dk)) { $days[$dk] = @{ Items=[System.Collections.Generic.List[object]]::new(); Intervals=[System.Collections.Generic.List[object]]::new() } }
    $days[$dk].Items.Add(@{ Kind=$info.Kind; Ticket=$info.Ticket; Label=$info.Label; Blocks=$kept; TotalMin=$tot })
    foreach ($b in $kept) { $days[$dk].Intervals.Add($b) }
  }
}
foreach ($dk in @($days.Keys)) {                                               # union of all blocks → Präsenz (no double counting)
  $iv = @($days[$dk].Intervals | Sort-Object { $_.Von }); $u = 0.0; $cs=$null; $ce=$null; $von=$null; $bis=$null
  foreach ($b in $iv) {
    if ($null -eq $cs) { $cs=$b.Von; $ce=$b.Bis; $von=$b.Von }
    elseif ($b.Von -le $ce) { if ($b.Bis -gt $ce) { $ce=$b.Bis } }
    else { $u += ($ce-$cs).TotalMinutes; $cs=$b.Von; $ce=$b.Bis }
    if ($null -eq $bis -or $b.Bis -gt $bis) { $bis=$b.Bis }
  }
  if ($null -ne $cs) { $u += ($ce-$cs).TotalMinutes }
  $days[$dk].PresenceMin=$u; $days[$dk].Von=$von; $days[$dk].Bis=$bis
}
@{ Days=$days; WeekStartTicks=[int64]$WeekStartTicks; BuiltAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
'@

  $script:Zeiten=$null; $script:ZeitenPS=$null; $script:ZeitenRS=$null; $script:ZeitenHandle=$null; $script:ZeitenBuilding=$false
  $script:ZeitWeekStart=$null; $script:ZeitenWeekBuilt=$null; $script:ZeitenReqWeek=$null
  function Start-ZeitenBuild {
    if ($script:ZeitenBuilding) { return }
    if (-not $script:ZeitWeekStart) { $script:ZeitWeekStart = Week-Monday ([datetime]::Now) }
    $script:ZeitenBuilding = $true; $script:ZeitenReqWeek = $script:ZeitWeekStart
    try {
      $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
      $ps = [powershell]::Create(); $ps.Runspace = $rs
      [void]$ps.AddScript($script:ZeitenWorker).AddArgument($ProjectsDir).AddArgument($script:ZeitWeekStart.Ticks).AddArgument($script:ZeitWeekStart.AddDays(7).Ticks)
      $script:ZeitenPS = $ps; $script:ZeitenRS = $rs; $script:ZeitenHandle = $ps.BeginInvoke()
    } catch { $script:ZeitenBuilding = $false; "[{0}] zeiten start: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
  }
  function Collect-Zeiten {
    if (-not $script:ZeitenHandle -or -not $script:ZeitenHandle.IsCompleted) { return $false }
    $fresh = $false
    try { $res = $script:ZeitenPS.EndInvoke($script:ZeitenHandle); if ($res -and $res.Count) { $script:Zeiten = $res[$res.Count - 1]; $script:ZeitenWeekBuilt = $script:ZeitenReqWeek; $fresh = $true } }
    catch { "[{0}] zeiten collect: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
    finally { try { $script:ZeitenPS.Dispose() } catch {}; try { $script:ZeitenRS.Dispose() } catch {}; $script:ZeitenPS=$null; $script:ZeitenRS=$null; $script:ZeitenHandle=$null; $script:ZeitenBuilding=$false }
    $fresh
  }
  function Ensure-Zeiten {
    if (-not $script:ZeitWeekStart) { $script:ZeitWeekStart = Week-Monday ([datetime]::Now) }
    if (($script:ZeitenWeekBuilt -ne $script:ZeitWeekStart) -and -not $script:ZeitenBuilding) { Start-ZeitenBuild }
  }
  function Nav-Week([int]$delta) {
    if (-not $script:ZeitWeekStart) { $script:ZeitWeekStart = Week-Monday ([datetime]::Now) }
    $script:ZeitWeekStart = $script:ZeitWeekStart.AddDays(7 * $delta)
    Start-ZeitenBuild; Keep-Bottom { Rebuild-Zeiten }
  }
  function Go-ThisWeek {
    $mon = Week-Monday ([datetime]::Now)
    if ($mon -eq $script:ZeitWeekStart) { return }
    $script:ZeitWeekStart = $mon; Start-ZeitenBuild; Keep-Bottom { Rebuild-Zeiten }
  }

  # ── Zeiten: rows for clipboard / CSV (one line per block) ───────────────────────
  function Get-ZeitenRows {
    $rows = @()
    if (-not ($script:Zeiten -and ($script:ZeitenWeekBuilt -eq $script:ZeitWeekStart))) { return , $rows }
    $days = $script:Zeiten.Days
    for ($i = 0; $i -lt 7; $i++) {
      $date = $script:ZeitWeekStart.AddDays($i); $dk = $date.ToString('yyyy-MM-dd')
      if (-not $days.ContainsKey($dk)) { continue }
      $items = @($days[$dk].Items | Sort-Object @{e = { if ($_.Kind -eq 'ticket') { 0 } else { 1 } } }, @{e = { if ($_.Ticket) { $_.Ticket } else { $_.Label } } })
      foreach ($it in $items) {
        $auf = if ($it.Ticket) { $it.Ticket } else { $it.Label }
        foreach ($b in $it.Blocks) { $rows += [pscustomobject]@{ Datum = $date.ToString('dd.MM.yyyy'); Aufgabe = $auf; Von = (Fmt-HM $b.Von); Bis = (Fmt-HM $b.Bis); Stunden = (Fmt-Q (QH $b.Min)) } }
      }
    }
    , $rows
  }
  function Copy-Zeiten {
    $rows = Get-ZeitenRows
    if (-not $rows.Count) { Show-Hint 'Keine Zeiten zum Kopieren in dieser Woche.'; return }
    $sb = [System.Text.StringBuilder]::new(); [void]$sb.AppendLine("Datum`tAufgabe`tVon`tBis`tStunden")
    foreach ($r in $rows) { [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}" -f $r.Datum, $r.Aufgabe, $r.Von, $r.Bis, $r.Stunden)) }
    try { [System.Windows.Clipboard]::SetText($sb.ToString()); Show-Hint ("{0} Zeilen kopiert (Tab-getrennt, in Excel einfügbar)." -f $rows.Count) }
    catch { Show-Hint 'Kopieren fehlgeschlagen.' }
  }
  function Export-ZeitenCsv {
    $rows = Get-ZeitenRows
    if (-not $rows.Count) { Show-Hint 'Keine Zeiten zum Export in dieser Woche.'; return }
    $kw = 0; try { $kw = [System.Globalization.ISOWeek]::GetWeekOfYear($script:ZeitWeekStart) } catch {}
    $name = 'Pulse-Zeiten-{0}-KW{1:00}.csv' -f $script:ZeitWeekStart.ToString('yyyy'), $kw
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) $name
    $sb = [System.Text.StringBuilder]::new(); [void]$sb.AppendLine('Datum;Aufgabe;Von;Bis;Stunden')
    foreach ($r in $rows) { [void]$sb.AppendLine(('{0};{1};{2};{3};{4}' -f $r.Datum, $r.Aufgabe, $r.Von, $r.Bis, $r.Stunden)) }
    try { [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($true)); Show-Hint ("Gespeichert: {0}" -f $path) }
    catch { Show-Hint 'CSV-Export fehlgeschlagen.' }
  }

  # ── Zeiten: UI builders ─────────────────────────────────────────────────────────
  function New-ZNav([string]$glyph, [scriptblock]$onClick) {
    $b = [System.Windows.Controls.Border]::new(); $b.Width = 28; $b.Height = 26; $b.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $b.Background = (Brush '#12FFFFFF'); $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $t = New-Text -Text $glyph -Fg '#C6CCD5' -Size 14 -Semi; $t.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; $t.TextAlignment = [System.Windows.TextAlignment]::Center
    $b.Child = $t; $b.Add_MouseLeftButtonUp($onClick)
    $b.Add_MouseEnter({ param($s, $e) Fade-Brush $s.Background '#20FFFFFF' 150 })
    $b.Add_MouseLeave({ param($s, $e) Fade-Brush $s.Background '#12FFFFFF' 180 })
    $b
  }
  function New-ZBtn([string]$label, [string]$bg, [string]$fg, [scriptblock]$onClick, [switch]$Ghost) {
    $b = [System.Windows.Controls.Border]::new(); $b.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $b.Padding = [System.Windows.Thickness]::new(12, 4, 12, 5); $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Background = (Brush $bg)
    if ($Ghost) { $b.BorderBrush = (Brush '#24FFFFFF'); $b.BorderThickness = [System.Windows.Thickness]::new(1) }
    $b.Child = (New-Text -Text $label -Fg $fg -Size 11 -Semi); $b.Add_MouseLeftButtonUp($onClick); $b
  }
  $script:ZLabW = 56.0
  function New-ZAxis([double]$startMin, [double]$span) {
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $sp.Margin = [System.Windows.Thickness]::new(18, 4, 16, 3)
    $spacer = [System.Windows.Controls.Border]::new(); $spacer.Width = $script:ZLabW; $sp.Children.Add($spacer) | Out-Null
    $cv = [System.Windows.Controls.Canvas]::new(); $cv.Width = $script:ZTrackW; $cv.Height = 11
    $step = if ($span -gt 420) { 180.0 } else { 120.0 }
    for ($m = $startMin; $m -le ($startMin + $span); $m += $step) {
      $x = ($m - $startMin) / $span * $script:ZTrackW
      $t = New-Text -Text ("{0:00}" -f [int]($m / 60)) -Fg '#5E636D' -Size 9 -Mono
      [System.Windows.Controls.Canvas]::SetLeft($t, [math]::Max(0, $x - 6)); [System.Windows.Controls.Canvas]::SetTop($t, 0)
      $cv.Children.Add($t) | Out-Null
    }
    $sp.Children.Add($cv) | Out-Null; $sp
  }
  function New-ZItemRow($item, [double]$startMin, [double]$span) {
    $isT = ($item.Kind -eq 'ticket')
    $labHex = if ($isT) { '#D6DBE2' } else { '#8B929D' }
    $barHex = if ($isT) { '#E8ECF2' } else { '#6E7580' }
    $line = [System.Windows.Controls.StackPanel]::new(); $line.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $line.Margin = [System.Windows.Thickness]::new(18, 3, 16, 0)
    $lblTxt = if ($isT) { [string]$item.Ticket } else { Short $item.Label 9 }
    $lbl = New-Text -Text $lblTxt -Fg $labHex -Size 11 -Mono -Semi; $lbl.Width = $script:ZLabW; $lbl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $lbl.ToolTip = $item.Label
    $track = [System.Windows.Controls.Border]::new(); $track.Width = $script:ZTrackW; $track.Height = 14
    $track.CornerRadius = [System.Windows.CornerRadius]::new(4); $track.Background = (Brush '#10FFFFFF'); $track.ClipToBounds = $true
    $track.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $cv = [System.Windows.Controls.Canvas]::new(); $cv.Width = $script:ZTrackW; $cv.Height = 14
    foreach ($b in $item.Blocks) {
      $x = ($b.Von.TimeOfDay.TotalMinutes - $startMin) / $span * $script:ZTrackW
      $w = [math]::Max(2.5, ($b.Bis - $b.Von).TotalMinutes / $span * $script:ZTrackW)
      $bar = [System.Windows.Controls.Border]::new(); $bar.Height = 9; $bar.Width = $w
      $bar.CornerRadius = [System.Windows.CornerRadius]::new(2.5); $bar.Background = (Brush $barHex)
      $bar.ToolTip = "{0}–{1}" -f (Fmt-HM $b.Von), (Fmt-HM $b.Bis)
      [System.Windows.Controls.Canvas]::SetLeft($bar, [math]::Max(0, $x)); [System.Windows.Controls.Canvas]::SetTop($bar, 2.5)
      $cv.Children.Add($bar) | Out-Null
    }
    $track.Child = $cv
    $hrs = 0.0; foreach ($b in $item.Blocks) { $hrs += (QH $b.Min) }
    $ht = New-Text -Text ((Fmt-Q $hrs) + ' h') -Fg '#C6CCD5' -Size 11 -Mono; $ht.Width = 50; $ht.TextAlignment = [System.Windows.TextAlignment]::Right; $ht.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $ht.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $line.Children.Add($lbl) | Out-Null; $line.Children.Add($track) | Out-Null; $line.Children.Add($ht) | Out-Null
    $line
  }
  function New-ZDay($date, $dd) {
    $dayAuf = 0.0; foreach ($it in $dd.Items) { foreach ($b in $it.Blocks) { $dayAuf += (QH $b.Min) } }
    $wrap = [System.Windows.Controls.StackPanel]::new(); $wrap.Margin = [System.Windows.Thickness]::new(0, 16, 0, 4)
    $hg = [System.Windows.Controls.Grid]::new(); $hg.Margin = [System.Windows.Thickness]::new(18, 0, 16, 3)
    foreach ($w in '*', 'Auto') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }; $hg.ColumnDefinitions.Add($cd) }
    $dl = New-Text -Text ($date.ToString('ddd · dd.MM.', $script:DE)) -Fg '#E8ECF2' -Size 13 -Semi; [System.Windows.Controls.Grid]::SetColumn($dl, 0)
    $tot = New-Text -Text ((Fmt-Q $dayAuf) + ' h') -Fg '#E8ECF2' -Size 13 -Semi -Mono; [System.Windows.Controls.Grid]::SetColumn($tot, 1)
    $hg.Children.Add($dl) | Out-Null; $hg.Children.Add($tot) | Out-Null; $wrap.Children.Add($hg) | Out-Null
    $pres = "Präsenz {0}–{1} · {2} h" -f (Fmt-HM $dd.Von), (Fmt-HM $dd.Bis), (Fmt-Q (QH $dd.PresenceMin))
    $pl = New-Text -Text $pres -Fg '#767D88' -Size 10 -Mono; $pl.Margin = [System.Windows.Thickness]::new(18, 0, 16, 7); $wrap.Children.Add($pl) | Out-Null
    $startMin = [math]::Floor($dd.Von.TimeOfDay.TotalMinutes / 60) * 60
    $endMin = [math]::Ceiling($dd.Bis.TimeOfDay.TotalMinutes / 60) * 60
    if ($endMin -le $startMin) { $endMin = $startMin + 60 }
    $span = $endMin - $startMin
    $wrap.Children.Add((New-ZAxis $startMin $span)) | Out-Null
    $items = @($dd.Items | Sort-Object @{e = { if ($_.Kind -eq 'ticket') { 0 } else { 1 } } }, @{e = { if ($_.Ticket) { $_.Ticket } else { $_.Label } } })
    foreach ($it in $items) { $wrap.Children.Add((New-ZItemRow $it $startMin $span)) | Out-Null }
    $wrap
  }
  function Rebuild-Zeiten {
    $script:PartZeiten.Children.Clear()
    Ensure-Zeiten
    # week navigator
    $nav = [System.Windows.Controls.Grid]::new(); $nav.Margin = [System.Windows.Thickness]::new(18, 12, 16, 2)
    foreach ($w in 'Auto', '*', 'Auto', 'Auto') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }; $nav.ColumnDefinitions.Add($cd) }
    $prev = New-ZNav '‹' { Nav-Week -1 }; [System.Windows.Controls.Grid]::SetColumn($prev, 0)
    $kw = 0; try { $kw = [System.Globalization.ISOWeek]::GetWeekOfYear($script:ZeitWeekStart) } catch {}
    $title = New-Text -Text ("KW {0:00} · {1}–{2}" -f $kw, $script:ZeitWeekStart.ToString('dd.MM.', $script:DE), $script:ZeitWeekStart.AddDays(6).ToString('dd.MM.', $script:DE)) -Fg '#E8ECF2' -Size 13 -Semi
    $title.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; $title.TextAlignment = [System.Windows.TextAlignment]::Center; $title.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [System.Windows.Controls.Grid]::SetColumn($title, 1)
    $next = New-ZNav '›' { Nav-Week 1 }; [System.Windows.Controls.Grid]::SetColumn($next, 2)
    $heute = New-ZBtn 'Heute' '#12FFFFFF' '#C6CCD5' { Go-ThisWeek }; $heute.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0); [System.Windows.Controls.Grid]::SetColumn($heute, 3)
    $nav.Children.Add($prev) | Out-Null; $nav.Children.Add($title) | Out-Null; $nav.Children.Add($next) | Out-Null; $nav.Children.Add($heute) | Out-Null
    $script:PartZeiten.Children.Add($nav) | Out-Null

    if (-not ($script:Zeiten -and ($script:ZeitenWeekBuilt -eq $script:ZeitWeekStart))) {
      $e = New-Text -Text 'Berechne Zeiten …' -Fg '#8A909B' -Size 12.5; $e.Margin = [System.Windows.Thickness]::new(18, 16, 16, 18)
      $script:PartZeiten.Children.Add($e) | Out-Null; return
    }

    $days = $script:Zeiten.Days
    $weekAuf = 0.0; $dayCount = 0
    for ($i = 0; $i -lt 7; $i++) {
      $dk = $script:ZeitWeekStart.AddDays($i).ToString('yyyy-MM-dd')
      if (-not $days.ContainsKey($dk)) { continue }
      $dayCount++
      foreach ($it in $days[$dk].Items) { foreach ($b in $it.Blocks) { $weekAuf += (QH $b.Min) } }
    }
    # week summary + export
    $bar = [System.Windows.Controls.Grid]::new(); $bar.Margin = [System.Windows.Thickness]::new(18, 12, 16, 2)
    foreach ($w in '*', 'Auto') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }; $bar.ColumnDefinitions.Add($cd) }
    $sum = New-Text -Text ("Σ {0} h · {1} {2}" -f (Fmt-Q $weekAuf), $dayCount, $(if ($dayCount -eq 1) { 'Tag' } else { 'Tage' })) -Fg '#C6CCD5' -Size 11.5 -Mono
    $sum.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [System.Windows.Controls.Grid]::SetColumn($sum, 0)
    $tb = [System.Windows.Controls.StackPanel]::new(); $tb.Orientation = [System.Windows.Controls.Orientation]::Horizontal; [System.Windows.Controls.Grid]::SetColumn($tb, 1)
    $tb.Children.Add((New-ZBtn 'Kopieren' '#E8ECF2' '#14171C' { Copy-Zeiten })) | Out-Null
    $csv = New-ZBtn 'CSV' '#00000000' '#9AA0AA' { Export-ZeitenCsv } -Ghost; $csv.Margin = [System.Windows.Thickness]::new(7, 0, 0, 0)
    $tb.Children.Add($csv) | Out-Null
    $bar.Children.Add($sum) | Out-Null; $bar.Children.Add($tb) | Out-Null; $script:PartZeiten.Children.Add($bar) | Out-Null

    $any = $false
    for ($i = 0; $i -lt 7; $i++) {
      $date = $script:ZeitWeekStart.AddDays($i); $dk = $date.ToString('yyyy-MM-dd')
      if (-not $days.ContainsKey($dk)) { continue }
      $any = $true
      $script:PartZeiten.Children.Add((New-ZDay $date $days[$dk])) | Out-Null
    }
    if (-not $any) {
      $e = New-Text -Text 'Keine erfasste Claude-Zeit in dieser Woche.' -Fg '#8A909B' -Size 12; $e.Margin = [System.Windows.Thickness]::new(18, 16, 16, 18)
      $script:PartZeiten.Children.Add($e) | Out-Null
    }
    $fn = New-Text -Text 'Nur Zeit mit laufender Claude-Session · Ränder und Pausen prüfst du selbst.' -Fg '#5E636D' -Size 10
    $fn.Margin = [System.Windows.Thickness]::new(18, 14, 16, 6); $fn.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $script:PartZeiten.Children.Add($fn) | Out-Null
  }

  $script:Win.Add_Deactivated({ $script:Win.Hide() })

  # ── one session row (flat — no boxes; separation by space + subtle hover) ─────
  function New-Row($sess) {
    $st = $sess.State; $hex = $st.Hex; $seen = -not $sess.Unseen
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $b.Padding = [System.Windows.Thickness]::new(14, 10, 12, 11)
    $b.Margin  = [System.Windows.Thickness]::new(8, 1, 8, 1)
    $b.Cursor  = [System.Windows.Input.Cursors]::Hand
    $b.Background = (Brush '#00000000')
    $b.Tag = [pscustomobject]@{ Session = $sess; AiTitle = $sess.Meta.AiTitle }
    $b.Add_MouseEnter({ param($s, $e) Fade-Brush $s.Background '#14FFFFFF' 200 })
    $b.Add_MouseLeave({ param($s, $e) Fade-Brush $s.Background '#00000000' 280 })
    $b.Add_MouseLeftButtonUp({ param($s, $e) Focus-Session $s.Tag })

    $outer = [System.Windows.Controls.StackPanel]::new()

    # row 1: dot | name | status | time
    $r1 = [System.Windows.Controls.Grid]::new()
    foreach ($w in 'Auto', 'Auto', 'Auto', '*', 'Auto') {
      $cd = [System.Windows.Controls.ColumnDefinition]::new()
      $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
      $r1.ColumnDefinitions.Add($cd)
    }
    $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 7; $dot.Height = 7
    $dot.Fill = (Brush $(if ($seen) { "#AA$hex" } else { "#FF$hex" }))
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 11, 0)
    [System.Windows.Controls.Grid]::SetColumn($dot, 0)
    if ($sess.State.Kind -eq 'work') {
      $anim = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.3, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1100)))
      $anim.AutoReverse = $true; $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
      $anim.EasingFunction = [System.Windows.Media.Animation.SineEase]::new()
      $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
    }
    $nameT = if ($seen) { New-Text -Text $sess.Name -Fg '#AEB4BD' -Size 13.5 -Mono } else { New-Text -Text $sess.Name -Fg '#F4F6F8' -Size 13.5 -Mono -Semi }
    $nameT.MaxWidth = 210; [System.Windows.Controls.Grid]::SetColumn($nameT, 1)
    $statusT = New-Text -Text $st.Label -Fg $(if ($seen) { "#B0$hex" } else { "#$hex" }) -Size 11.5
    $statusT.Margin = [System.Windows.Thickness]::new(10, 1, 0, 0); [System.Windows.Controls.Grid]::SetColumn($statusT, 2)
    $timeT = New-Text -Text (Format-Since $sess.StatusUpdatedAt) -Fg '#767D88' -Size 11 -Mono
    $timeT.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [System.Windows.Controls.Grid]::SetColumn($timeT, 4)
    $r1.Children.Add($dot) | Out-Null; $r1.Children.Add($nameT) | Out-Null; $r1.Children.Add($statusT) | Out-Null; $r1.Children.Add($timeT) | Out-Null
    $outer.Children.Add($r1) | Out-Null

    # row 2: what it's doing
    if ($st.Inline) {
      $act = New-Text -Text $st.Inline -Fg $(if ($seen) { '#7C838D' } else { '#A6AEB8' }) -Size 11.5 -Mono
      $act.Margin = [System.Windows.Thickness]::new(18, 6, 8, 0); $act.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
      $outer.Children.Add($act) | Out-Null
    }

    # row 3: metrics — plain icon + value, no boxes
    $tok = Read-Tokens $sess
    $diff = Get-GitDiff $sess.Cwd
    $muted = if ($seen) { '#767D88' } else { '#868D97' }
    $line2 = [System.Windows.Controls.WrapPanel]::new()
    $line2.Margin = [System.Windows.Thickness]::new(18, 8, 8, 0)
    if ($tok.Up -or $tok.Down) { $line2.Children.Add((New-Metric '' ("↑{0} ↓{1}" -f (Format-Tok $tok.Up), (Format-Tok $tok.Down)) $muted)) | Out-Null }
    if ($diff -and $diff.Files) { $line2.Children.Add((New-Metric $script:IcoFile ([string]$diff.Files) $muted)) | Out-Null }
    if ($tok.Tools) { $line2.Children.Add((New-Metric $script:IcoTool ([string]$tok.Tools) $muted)) | Out-Null }
    if ($diff -and ($diff.Add -or $diff.Del)) {
      $dg = [System.Windows.Controls.StackPanel]::new(); $dg.Orientation = [System.Windows.Controls.Orientation]::Horizontal
      $dg.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $dg.Margin = [System.Windows.Thickness]::new(0, 0, 16, 4)
      $dg.Children.Add((New-Text -Text ("+{0}" -f $diff.Add) -Fg '#5FBE86' -Size 11 -Mono)) | Out-Null
      $dmn = New-Text -Text ("−{0}" -f $diff.Del) -Fg '#D97B7B' -Size 11 -Mono; $dmn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
      $dg.Children.Add($dmn) | Out-Null; $line2.Children.Add($dg) | Out-Null
    }
    if ($sess.Cwd -match '[\\/]workspaces[\\/]\d{4}[\\/](\d+)') { $line2.Children.Add((New-Metric $script:IcoTag ([string]$Matches[1]) $muted)) | Out-Null }
    elseif ($st.Sub) { $line2.Children.Add((New-Metric $script:IcoRepo $st.Sub $muted)) | Out-Null }
    if ($line2.Children.Count) { $outer.Children.Add($line2) | Out-Null }

    $b.Child = $outer
    $b
  }

  function Rebuild-List($sessions) {
    $script:PartList.Children.Clear()
    if ($sessions.Count -eq 0) {
      $e = New-Text -Text 'No active sessions' -Fg '#8A909B' -Size 12.5
      $e.Margin = [System.Windows.Thickness]::new(19, 10, 0, 16); $script:PartList.Children.Add($e) | Out-Null
      return
    }
    $ordered = $sessions | Sort-Object @{e = { -[int]$_.Unseen } }, @{e = { $_.State.Sort } }, @{e = { $_.StatusUpdatedAt } }
    foreach ($s in $ordered) { $script:PartList.Children.Add((New-Row $s)) | Out-Null }
  }

  $script:LastSig = ''; $script:LastSessions = @(); $script:StatsPoll = 0
  function Refresh([bool]$Force) {
    $sessions = Get-Sessions
    foreach ($s in $sessions) { $s.Meta = Read-Meta $s; $s.State = Get-StateInfo $s }
    Update-Seen $sessions
    $script:LastSessions = $sessions
    $statsFresh = Collect-Stats    # drain a finished background build regardless of the current view
    $zeitenFresh = Collect-Zeiten
    $unseenList = @($sessions | Where-Object { $_.Unseen })
    $unseen = $unseenList.Count
    $dot = ''
    if ($unseen) { $dot = if (@($unseenList | Where-Object { $_.State.Kind -eq 'attn' }).Count) { '#E9A94A' } else { '#4FC98A' } }
    Update-Tray $dot
    if ($Force -or $script:Win.IsVisible) {
      Update-Usage $Force
      if ($script:View -eq 'agents') {
        $sig = ($sessions | ForEach-Object { "$($_.SessionId)|$($_.State.Kind)|$($_.Unseen)|$($_.State.Inline)|$(Format-Since $_.StatusUpdatedAt)" }) -join "`n"
        if ($Force -or $sig -ne $script:LastSig) { Rebuild-List $sessions; $script:LastSig = $sig }
      } elseif ($script:View -eq 'stats') {
        if ($statsFresh) { Keep-Bottom { Rebuild-Stats } }   # a background build just finished
        $now = [Environment]::TickCount
        if (-not $script:StatsBuilding -and ([math]::Abs($now - $script:StatsPoll) -gt 15000)) {
          $fp = Get-StatsFingerprint
          if ($fp -ne $script:StatsFP) { $script:StatsFP = $fp; Start-StatsBuild }
          $script:StatsPoll = $now
        }
      } else {
        Ensure-Zeiten
        if ($Force -or $zeitenFresh) { Keep-Bottom { Rebuild-Zeiten } }
      }
    }
  }

  # ── crisp multi-size tray icon (logo + badge) ────────────────────────────────
  function Render-Frame([int]$size, [string]$dotHex) {
    $dv = [System.Windows.Media.DrawingVisual]::new(); $ctx = $dv.RenderOpen()
    Draw-Glyph $ctx $size
    if ($dotHex) {
      $r = $size * 0.235; $cx = $size - $r - $size * 0.05; $cy = $size - $r - $size * 0.05
      $ring = [System.Windows.Media.Pen]::new((Brush '#0C0E12'), [math]::Max(1.0, $size * 0.07))
      $ctx.DrawEllipse((Brush $dotHex), $ring, [System.Windows.Point]::new($cx, $cy), $r, $r)
    }
    $ctx.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv); $rtb
  }
  # render at the exact tray size (DPI-correct) → crisp, no downscaling
  function New-TrayIcon([string]$dotHex) {
    $sz = 16
    try { $sz = [int][System.Windows.Forms.SystemInformation]::SmallIconSize.Width } catch {}
    if ($sz -lt 16) { $sz = 16 }
    $rtb = Render-Frame $sz $dotHex
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = [System.IO.MemoryStream]::new(); $enc.Save($ms); $ms.Position = 0
    $bmp = [System.Drawing.Bitmap]::new($ms)
    $hicon = $bmp.GetHicon()
    $bmp.Dispose(); $ms.Dispose()
    @{ Icon = [System.Drawing.Icon]::FromHandle($hicon); HIcon = $hicon }
  }
  function Update-Tray([string]$dotHex) {
    if ($script:Notify.Icon -and $dotHex -eq $script:LastDot) { return }
    $new = New-TrayIcon $dotHex
    $old = $script:LastHIcon
    $script:Notify.Icon = $new.Icon
    $script:Notify.Text = if ($dotHex) { 'Pulse — new activity' } else { 'Pulse' }
    $script:LastHIcon = $new.HIcon; $script:LastDot = $dotHex
    if ($old) { [void][Pulse.Native]::DestroyIcon($old) }
  }

  # ── Frost-Glas: Screenshot hinter dem Flyout -> Blur -> Panel-Hintergrund ─────
  # DWM-Acryl (DWMSBT/SetWindowCompositionAttribute) rendert auf manchen GPU/Build-
  # Kombis opak bzw. wurde ab Win11 22H2 des Blurs beraubt; dieser selbst-gerenderte
  # Frost funktioniert unabhaengig davon. Snapshot beim Oeffnen (kein Live-Update).
  function ConvertTo-FrostSource([System.Drawing.Bitmap]$bmp) {
    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp); $ms.Position = 0
    $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $ms; $bi.EndInit(); $bi.Freeze()
    $ms.Dispose(); $bi
  }
  function Blur-Bitmap([System.Drawing.Bitmap]$src, [int]$scale, [int]$passes) {
    # billiger Gauss-Ersatz: runterskalieren -> hochskalieren (bilinear)
    $w = $src.Width; $h = $src.Height; $cur = $src
    for ($i = 0; $i -lt $passes; $i++) {
      $sw = [Math]::Max(1, [int]($w / $scale)); $sh = [Math]::Max(1, [int]($h / $scale))
      $small = [System.Drawing.Bitmap]::new($sw, $sh)
      $g1 = [System.Drawing.Graphics]::FromImage($small); $g1.InterpolationMode = 'HighQualityBilinear'; $g1.PixelOffsetMode = 'HighQuality'; $g1.DrawImage($cur, 0, 0, $sw, $sh); $g1.Dispose()
      $big = [System.Drawing.Bitmap]::new($w, $h)
      $g2 = [System.Drawing.Graphics]::FromImage($big); $g2.InterpolationMode = 'HighQualityBilinear'; $g2.PixelOffsetMode = 'HighQuality'; $g2.SmoothingMode = 'HighQuality'; $g2.DrawImage($small, 0, 0, $w, $h); $g2.Dispose(); $small.Dispose()
      if (-not [object]::ReferenceEquals($cur, $src)) { $cur.Dispose() }
      $cur = $big
    }
    $cur
  }
  function Set-FrostCapture {
    # Monitor unter dem Cursor abfotografieren (Flyout ist noch nicht sichtbar) + blurren
    try {
      $b = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).Bounds
      $shot = [System.Drawing.Bitmap]::new($b.Width, $b.Height)
      $gc = [System.Drawing.Graphics]::FromImage($shot)
      $gc.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $gc.Dispose()
      $blur = Blur-Bitmap $shot 10 2
      $srcimg = ConvertTo-FrostSource $blur
      $shot.Dispose(); $blur.Dispose()
      $brush = [System.Windows.Media.ImageBrush]::new($srcimg)
      $brush.Stretch = 'Fill'; $brush.ViewboxUnits = 'RelativeToBoundingBox'
      $script:FrostBounds = $b; $script:FrostBrush = $brush
    } catch {
      $script:FrostBrush = $null
      "[{0}] frost: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append
    }
  }
  function Update-FrostViewbox {
    # ImageBrush-Viewbox exakt auf den Bereich HINTER dem sichtbaren Panel (Geraetepixel)
    if (-not $script:FrostBrush -or -not $script:PartRoot -or -not $script:Win.IsVisible) { return }
    $src = [System.Windows.PresentationSource]::FromVisual($script:Win)
    if (-not $src) { return }
    try {
      $m = $src.CompositionTarget.TransformToDevice
      $tl = $script:PartRoot.PointToScreen([System.Windows.Point]::new(0, 0))
      $b = $script:FrostBounds
      $rx = ($tl.X - $b.X) / $b.Width
      $ry = ($tl.Y - $b.Y) / $b.Height
      $rw = ($script:PartRoot.ActualWidth * $m.M11) / $b.Width
      $rh = ($script:PartRoot.ActualHeight * $m.M22) / $b.Height
      # clamp into the captured bitmap so the frost never falls off into transparency
      if ($rw -gt 1) { $rw = 1 }; if ($rh -gt 1) { $rh = 1 }
      if ($rx -lt 0) { $rx = 0 } elseif ($rx + $rw -gt 1) { $rx = 1 - $rw }
      if ($ry -lt 0) { $ry = 0 } elseif ($ry + $rh -gt 1) { $ry = 1 - $rh }
      $script:FrostBrush.Viewbox = [System.Windows.Rect]::new($rx, $ry, $rw, $rh)
      if (-not [object]::ReferenceEquals($script:PartRoot.Background, $script:FrostBrush)) { $script:PartRoot.Background = $script:FrostBrush }
    } catch {}
  }

  function Show-Flyout {
    Hide-Hint
    Refresh $true
    Set-FrostCapture
    $reposition = {
      $pt = [System.Windows.Forms.Cursor]::Position
      $wa = [System.Windows.Forms.Screen]::FromPoint($pt).WorkingArea
      $src = [System.Windows.PresentationSource]::FromVisual($script:Win)
      if ($src -and $src.CompositionTarget) {
        $rb = $src.CompositionTarget.TransformFromDevice.Transform([System.Windows.Point]::new($wa.Right, $wa.Bottom))
        $script:Win.Left = $rb.X - $script:Win.Width
        $script:Win.Top  = $rb.Y - $script:Win.ActualHeight
      } else {
        $script:Win.Left = $wa.Right - $script:Win.Width
        $script:Win.Top  = $wa.Bottom - $script:Win.ActualHeight
      }
      Update-FrostViewbox
    }
    $script:Win.UpdateLayout(); & $reposition
    $script:Win.Show(); $script:Win.Activate(); $script:Win.Topmost = $true
    $script:Win.Dispatcher.BeginInvoke([System.Action]$reposition, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
  }

  # ── tray icon + menu + timer ─────────────────────────────────────────────────
  $script:LastDot = '<init>'; $script:LastHIcon = $null
  $script:Notify = [System.Windows.Forms.NotifyIcon]::new()
  $ti0 = New-TrayIcon ''; $script:Notify.Icon = $ti0.Icon; $script:LastHIcon = $ti0.HIcon; $script:LastDot = ''
  $script:Notify.Text = 'Pulse'; $script:Notify.Visible = $true
  $script:Notify.Add_MouseClick({
      param($s, $e)
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:Win.IsVisible) { $script:Win.Hide() } else { Show-Flyout }
      }
    })
  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $miOpen = $menu.Items.Add('Open'); $miOpen.add_Click({ Show-Flyout })
  $miAuto = [System.Windows.Forms.ToolStripMenuItem]::new('Start at login')
  $miAuto.CheckOnClick = $true
  $miAuto.Checked = Test-Path $script:AutoLnk
  $miAuto.add_Click({
      param($s, $e)
      try {
        if ($s.Checked) { Write-PulseShortcut $script:AutoLnk }
        else { Remove-Item $script:AutoLnk -ErrorAction SilentlyContinue }
      } catch { "[{0}] autostart: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append }
    })
  [void]$menu.Items.Add($miAuto)
  # exact 5h / weekly usage requires a statusLine command in settings.json (the only
  # channel Claude Code exposes rate_limits through). This toggle installs/removes it.
  $script:MiBridge = [System.Windows.Forms.ToolStripMenuItem]::new('Exakte Auslastung (Statusline)')
  $script:MiBridge.CheckOnClick = $true
  $script:MiBridge.add_Click({
      param($s, $e)
      if ($s.Checked) {
        if ((Get-BridgeState) -eq 'foreign') { $s.Checked = $false; "[{0}] bridge: foreign statusLine present; not overwriting" -f (Get-Date -Format o) | Out-File $LogPath -Append; return }
        [void](Install-Bridge)
      } else { [void](Uninstall-Bridge) }
      $script:UsageSig = '<init>'
      if ($script:Win.IsVisible) { Update-Usage $true }
    })
  [void]$menu.Items.Add($script:MiBridge)
  $menu.add_Opening({ try { $script:MiBridge.Checked = ((Get-BridgeState) -eq 'ours') } catch {} })
  [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  $miQuit = $menu.Items.Add('Quit'); $miQuit.add_Click({
      try { $script:Timer.Stop() } catch {}
      try { if ($script:StatsPS) { $script:StatsPS.Stop(); $script:StatsPS.Dispose() }; if ($script:StatsRS) { $script:StatsRS.Dispose() } } catch {}
      try { if ($script:ZeitenPS) { $script:ZeitenPS.Stop(); $script:ZeitenPS.Dispose() }; if ($script:ZeitenRS) { $script:ZeitenRS.Dispose() } } catch {}
      $script:Notify.Visible = $false; $script:Notify.Dispose()
      [System.Windows.Application]::Current.Shutdown()
    })
  $script:Notify.ContextMenuStrip = $menu

  $script:Timer = [System.Windows.Threading.DispatcherTimer]::new()
  $script:Timer.Interval = [TimeSpan]::FromSeconds(2)
  $script:Timer.Add_Tick({ try { Refresh $false } catch { "[{0}] tick: {1}" -f (Get-Date -Format o), $_.Exception.Message | Out-File $LogPath -Append } })
  $script:Timer.Start()
  Set-Toggle
  Refresh $false

  "[{0}] running" -f (Get-Date -Format o) | Out-File $LogPath -Append
  $app = [System.Windows.Application]::new()
  $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
  $app.Run() | Out-Null
}

# ── launch on an STA thread ─────────────────────────────────────────────────────
try {
  if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { & $uiScript }
  else {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('AppDir', $AppDir)
    $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($uiScript); $ps.Invoke()
    foreach ($err in $ps.Streams.Error) { "[{0}] {1}" -f (Get-Date -Format o), $err.ToString() | Out-File $LogPath -Append }
    $ps.Dispose(); $rs.Dispose()
  }
} catch {
  "[{0}] FATAL: {1}`n{2}" -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace | Out-File $LogPath -Append
  throw
}
