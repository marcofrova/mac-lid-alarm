# Mac Lid Alarm (macOS)

Shell script that triggers an alarm when the laptop lid is closed
(using AppleClamshellState).

Built to practice low-level system scripting on macOS:
power management, audio enforcement, UI scripting, and optional notifications.

## Features
- Detects lid close via `ioreg`
- Alarm sound loop (`afplay`) with forced max volume
- Optional wallpaper change
- Optional video recording (ffmpeg)
- Optional notifications via environment variables (no secrets in code)

## Requirements
- macOS
- Optional: `ffmpeg` (for video recording)

## Install
```bash
chmod +x mac_lid_alarm.sh
