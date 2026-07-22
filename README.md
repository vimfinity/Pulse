# Pulse

A dependency-free Windows tray tool that shows, at a glance, **what your parallel
Claude Code agents are doing** — inspired by [agentpeek.app](https://agentpeek.app/),
but for Windows and read locally from the files under `~/.claude`.

## What it does

- **Tray icon** (a white activity pulse) in the bottom-right. A coloured **dot** signals
  new activity (amber = needs you, green = done).
- **Left-click** opens a flyout listing every live session. Status-dot colour:
  🔵 working · 🟠 needs you · 🟢 done · ⚪ ready. Next to the name, the agent's
  **current action** (colour-coded); below it **tokens ↑/↓ · changed files · tools ·
  +/− diff · ticket/repo**, shown with icons.
- **New** items are highlighted subtly (read/unread). Clicking a row — or focusing the
  terminal yourself — clears the highlight.
- **Click a session** to bring its window to the foreground (best effort, works across
  virtual desktops).
- **Header** shows your **exact 5-hour and weekly usage** (once enabled — see below) with
  a bar, percentage and reset countdown, plus a **Agents │ Statistik** toggle.
- **Statistics view** (dependency-free WPF charts): a GitHub-style contribution calendar,
  a last-30-days activity trend, a per-model token split, an activity-by-hour heatmap,
  top projects by tokens, and live tiles (active now · today · this week · lifetime).
- **Right-click** → Open · Start at login · *Exakte Auslastung (Statusline)* · Quit.

Refreshes every ~2 s. Reads only: `~/.claude/sessions/*.json`,
`~/.claude/projects/…/*.jsonl`, `~/.claude/stats-cache.json` and (once enabled)
`~/.claude/Pulse.usage.json`.

## Run

- **No console window (recommended):** double-click `Pulse.vbs`, or type **Pulse** in the
  Start menu / Windows search (a `Pulse` shortcut with the app icon is installed there).
- **Directly:** `pwsh -NoProfile -File Pulse.ps1`
- **Autostart:** right-click the icon → *Start at login* (creates/removes a `Pulse.lnk`
  shortcut in `shell:startup`). If the folder is later moved, Pulse repairs a stale
  autostart shortcut automatically on next launch.

## Notes & limits

- **Focus** brings a session's Windows Terminal tab forward even when it isn't the
  active tab, by activating it via UI Automation. The one case it can't reach is an
  inactive tab in a window on **another virtual desktop** (WT doesn't expose that
  tab's tree until its desktop is current) — there you get a subtle in-flyout hint.
- **Exact usage (5h / weekly)** are Anthropic's server-computed numbers, which Claude Code
  only ever exposes to a **status line** command (piped as JSON on stdin, Pro/Max only,
  after the first API response of a session). Pulse never *estimates* them. Enabling
  *Exakte Auslastung* (tray menu, or the header prompt) adds a single `statusLine` entry to
  `~/.claude/settings.json` pointing at `Pulse.Statusline.ps1`; that script captures the
  `rate_limits` field into `~/.claude/Pulse.usage.json` (and prints a compact status line).
  It's opt-in and fully reversible — disabling removes the entry again (a `.pulsebak`
  backup of settings.json is made on install). If you already run your own status line,
  Pulse leaves it untouched and the meters stay hidden. Values refresh on each assistant
  message, so they update while a Claude Code session is open.
- **Tokens** count input + cache-creation for ↑ and output for ↓ (cache re-reads excluded).
- **Background** is solid-ish black with slight transparency. Real frosted-glass/acrylic
  is not reliably available to WPF on .NET Framework, so it is intentionally not used.

Startup problems are logged to `%TEMP%\Pulse.log`.
