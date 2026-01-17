#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# =========================
# Config / paths
# =========================
STATUS_FILE="/tmp/lid_monitor_active"
STOP_FILE="/tmp/stop_alarm"
DEBUG_LOG="/tmp/unplug_alarm_debug.log"
FFMPEG_LOG="/tmp/ffmpeg_log.txt"
LOCK_DIR="/tmp/unplug_alarm.lock"

PID_MONITOR="/tmp/unplug_alarm_monitor.pid"
PID_VOLUME="/tmp/unplug_alarm_volume.pid"
PID_FFMPEG="/tmp/unplug_alarm_ffmpeg.pid"
PID_CAFFEINATE="/tmp/unplug_alarm_caffeinate.pid"

# =========================
# NEW BASE DIR (moved folder)
# =========================
BASE_DIR="yourdirectorypathhere"

ALARM_SOUND="$BASE_DIR/security-alarm-63578.aiff"
ALARM_WALLPAPER="$BASE_DIR/wallpaper_alarm.png"

# Fixed wallpaper to restore on STOP (set this to what you want)
FIXED_WALLPAPER="//System/Library/Desktop Pictures/The Beach.madesktop"

# Telegram (requested: keep in script)
BOT_TOKEN="yourbottokenthere"
CHAT_ID="yourchatidthere"
TELEGRAM_MESSAGE="Alert: Your Mac's lid was closed, and the alarm has been triggered!"

# CallMeBot
CALL_URL="youapicalllinkhere"

# ffmpeg input settings (macOS AVFoundation)
FFMPEG_INPUT_DEVICE="0"      # video device index
FFMPEG_FRAMERATE="30"
FFMPEG_SIZE="1280x720"
FFMPEG_PRESET="ultrafast"

# =========================
# Helpers
# =========================
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DEBUG_LOG"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

disable_lid_sleep() {
  log "pmset: disablesleep 1 (admin)"
  osascript -e 'do shell script "pmset -a disablesleep 1" with administrator privileges' >/dev/null 2>&1
}

enable_lid_sleep() {
  log "pmset: disablesleep 0 (admin)"
  osascript -e 'do shell script "pmset -a disablesleep 0" with administrator privileges' >/dev/null 2>&1 || true
}

safe_kill_pidfile() {
  local pidfile="$1"
  local sig="${2:-TERM}"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "-$sig" "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

ensure_single_instance() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    : # ok
  else
    log "LOCK: allarme già in esecuzione (lock presente: $LOCK_DIR)"
    exit 0
  fi
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# =========================
# Telegram + call
# =========================
send_telegram_message() {
  curl -s --data "chat_id=$CHAT_ID&text=$TELEGRAM_MESSAGE" \
    "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" >/dev/null 2>&1 || true
}

send_call() {
  curl -s "$CALL_URL" >/dev/null 2>&1 || true
}

# =========================
# Wallpaper set/restore (fixed restore)
# =========================
set_alert_wallpaper() {
  log "Imposto wallpaper di allerta"
  if have_cmd osascript; then
    osascript -e 'tell application "System Events" to set picture of every desktop to "'"$ALARM_WALLPAPER"'"' >/dev/null 2>&1 || true
  fi
}

restore_fixed_wallpaper() {
  log "Ripristino wallpaper fisso: $FIXED_WALLPAPER"
  if have_cmd osascript; then
    osascript -e 'tell application "System Events" to set picture of every desktop to "'"$FIXED_WALLPAPER"'"' >/dev/null 2>&1 || true
  fi
}

# =========================
# Screen / sleep control
# =========================
keep_screen_on() {
  log "caffeinate: tengo schermo acceso"
  if have_cmd caffeinate; then
    caffeinate -d &
    echo $! > "$PID_CAFFEINATE"
  else
    log "WARN: caffeinate non trovato"
  fi
}

allow_sleep() {
  log "caffeinate: termino"
  safe_kill_pidfile "$PID_CAFFEINATE" TERM
  killall caffeinate 2>/dev/null || true
}

# =========================
# UI dialog
# =========================
display_alert_message() {
  if have_cmd osascript; then
    osascript -e 'tell application "System Events"
      display dialog "⚠️ Allarme Attivo: Non chiudere il coperchio!" buttons {"OK"} default button "OK" with icon caution giving up after 86400
    end tell' >/dev/null 2>&1 &
    log "Dialog visualizzato (osascript in background)"
  fi
}

# =========================
# Volume enforcement
# =========================
block_volume_controls() {
  log "Tento di disabilitare tasti volume"
  if have_cmd osascript; then
    osascript -e 'tell application "System Events" to set volume control enabled to false' >/dev/null 2>&1 || true
  fi
}

unblock_volume_controls() {
  log "Riabilito tasti volume"
  if have_cmd osascript; then
    osascript -e 'tell application "System Events" to set volume control enabled to true' >/dev/null 2>&1 || true
  fi
}

enforce_max_volume_loop() {
  log "Loop volume: avviato"
  while [[ ! -f "$STOP_FILE" ]]; do
    if have_cmd osascript; then
      osascript -e 'set volume output volume 100' >/dev/null 2>&1 || true
    fi
    sleep 0.25
  done
  log "Loop volume: terminato"
}

start_volume_enforcer() {
  enforce_max_volume_loop &
  echo $! > "$PID_VOLUME"
}

stop_volume_enforcer() {
  safe_kill_pidfile "$PID_VOLUME" TERM
}

# =========================
# Video recording (ffmpeg)
# =========================
start_video_recording() {
  if ! have_cmd ffmpeg; then
    log "WARN: ffmpeg non trovato; salto registrazione"
    return 0
  fi

  mkdir -p "$BASE_DIR" 2>/dev/null || true
  local ts video_path
  ts="$(date +"%Y%m%d_%H%M%S")"
  video_path="$BASE_DIR/video_$ts.mp4"

  log "ffmpeg: start recording -> $video_path"
  ffmpeg -f avfoundation -framerate "$FFMPEG_FRAMERATE" -video_size "$FFMPEG_SIZE" \
    -i "$FFMPEG_INPUT_DEVICE" -vcodec libx264 -preset "$FFMPEG_PRESET" \
    "$video_path" > "$FFMPEG_LOG" 2>&1 &
  echo $! > "$PID_FFMPEG"
}

stop_video_recording() {
  if [[ -f "$PID_FFMPEG" ]]; then
    local pid
    pid="$(cat "$PID_FFMPEG" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "ffmpeg: stop (SIGINT)"
      kill -INT "$pid" 2>/dev/null || true
      sleep 0.7
      if kill -0 "$pid" 2>/dev/null; then
        log "ffmpeg: force stop (SIGTERM)"
        kill -TERM "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$PID_FFMPEG"
  fi
}

# =========================
# Lid monitoring + alarm sound
# =========================
get_lid_status() {
  ioreg -r -k AppleClamshellState 2>/dev/null | \
    awk -F'= ' '/AppleClamshellState/ {print $2; exit}'
}

play_alarm_sound() {
  log "Audio: tentativo avvio allarme"

  if [[ ! -f "$ALARM_SOUND" ]]; then
    log "ERROR: file audio non trovato: $ALARM_SOUND"
    return
  fi

  osascript -e 'set volume output volume 100' >/dev/null 2>&1 || true
  sleep 0.5

  (
    while [[ ! -f "$STOP_FILE" ]]; do
      afplay "$ALARM_SOUND"
      sleep 0.2
    done
  ) &

  echo $! > /tmp/unplug_alarm_audio.pid
  log "Audio: loop avviato"
}

stop_alarm_sound() {
  local pidfile="/tmp/unplug_alarm_audio.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(cat "$pidfile")
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  pkill -9 afplay 2>/dev/null || true
  log "Audio: terminato"
}

monitor_lid_loop() {
  log "Monitor lid: avviato"
  while true; do
    if [[ ! -f "$STATUS_FILE" ]]; then
      log "Monitor lid: STATUS_FILE non presente, esco"
      exit 0
    fi

    local lid
    lid="$(get_lid_status)"
    if [[ "$lid" == "Yes" ]]; then
      log "Coperchio chiuso: trigger allarme"

      play_alarm_sound
      send_telegram_message
      send_call

      while [[ ! -f "$STOP_FILE" ]]; do
        sleep 1
      done

      rm -f "$STOP_FILE"
      stop_alarm_sound
      log "Allarme fermato (stop richiesto)"
    fi

    sleep 1
  done
}

start_monitor() {
  monitor_lid_loop &
  echo $! > "$PID_MONITOR"
}

stop_monitor() {
  safe_kill_pidfile "$PID_MONITOR" TERM
}

# =========================
# Start / Stop orchestration
# =========================
start_alarm() {
  disable_lid_sleep
  ensure_single_instance
  : > "$DEBUG_LOG" 2>/dev/null || true
  log "=== START ==="

  rm -f "$STOP_FILE"
  touch "$STATUS_FILE"

  mkdir -p "$BASE_DIR" 2>/dev/null || true

  set_alert_wallpaper
  keep_screen_on
  display_alert_message

  start_volume_enforcer
  block_volume_controls

  start_video_recording
  start_monitor

  log "=== START COMPLETATO ==="
}

stop_alarm() {
  log "=== STOP ==="

  touch "$STOP_FILE"
  rm -f "$STATUS_FILE"

  stop_monitor
  stop_volume_enforcer
  stop_alarm_sound
  stop_video_recording
  allow_sleep
  unblock_volume_controls

  restore_fixed_wallpaper

  enable_lid_sleep

  rm -f "$STOP_FILE"
  release_lock

  log "=== STOP COMPLETATO ==="
}

# =========================
# Main
# =========================
case "$1" in
  start) start_alarm ;;
  stop)  stop_alarm  ;;
  *) log "WARN: parametro sconosciuto: $1" ;;
esac