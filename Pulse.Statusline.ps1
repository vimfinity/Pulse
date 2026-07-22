# Pulse statusline bridge — captures Claude Code's rate_limits (the ONLY local channel
# for the official 5h / weekly usage) into a small JSON file that Pulse reads, and prints
# a compact one-line status. The status line is how Claude Code exposes rate_limits: it
# pipes the session JSON to this command on stdin after each assistant message.
#
# Contract-critical: must be fast and ALWAYS exit 0 with >=1 line of output — a non-zero
# exit or empty output blanks the status line. Installed/removed by Pulse via the tray
# menu ("Exakte Auslastung"), which adds a single statusLine entry to ~/.claude/settings.json.
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$raw = [Console]::In.ReadToEnd()
$out = Join-Path $HOME '.claude\Pulse.usage.json'

$model = $null; $cost = $null; $five = $null; $seven = $null; $sid = $null; $ctx = $null
try {
  $j = $raw | ConvertFrom-Json
  if ($j.model)   { $model = $j.model.display_name }
  if ($null -ne $j.cost.total_cost_usd) { $cost = [double]$j.cost.total_cost_usd }
  if ($null -ne $j.context_window.used_percentage) { $ctx = [double]$j.context_window.used_percentage }
  $sid = $j.session_id
  if ($j.rate_limits) {
    if ($null -ne $j.rate_limits.five_hour.used_percentage) {
      $five = @{ pct = [double]$j.rate_limits.five_hour.used_percentage; resetsAt = [int64]$j.rate_limits.five_hour.resets_at }
    }
    if ($null -ne $j.rate_limits.seven_day.used_percentage) {
      $seven = @{ pct = [double]$j.rate_limits.seven_day.used_percentage; resetsAt = [int64]$j.rate_limits.seven_day.resets_at }
    }
  }
} catch {}

# write the capture file atomically (temp + move); data is account-global so last writer wins
try {
  $rec = [ordered]@{ capturedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); model = $model; costUsd = $cost; sessionId = $sid }
  if ($five)  { $rec.fiveHour = $five }
  if ($seven) { $rec.sevenDay = $seven }
  $tmp = "$out.$PID.tmp"
  $rec | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $tmp -Encoding UTF8 -NoNewline
  Move-Item -Path $tmp -Destination $out -Force
} catch { try { Remove-Item $tmp -ErrorAction SilentlyContinue } catch {} }

# compact one-line status (mini bars). Kept minimal on purpose.
function Bar([double]$p) {
  $n = [int][math]::Round([math]::Max(0, [math]::Min(100, $p)) / 20)  # 0..5 cells
  ('█' * $n) + ('░' * (5 - $n))
}
$parts = @()
if ($model) { $parts += $model }
if ($five)  { $parts += ("5h {0} {1:0}%" -f (Bar $five.pct),  $five.pct) }
if ($seven) { $parts += ("7d {0} {1:0}%" -f (Bar $seven.pct), $seven.pct) }
if ((-not $five -and -not $seven) -and ($null -ne $ctx)) { $parts += ("ctx {0:0}%" -f $ctx) }
if ($parts.Count -eq 0) { $parts += 'Pulse' }
[Console]::Out.WriteLine(($parts -join '  ·  '))
exit 0
