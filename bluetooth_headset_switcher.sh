#!/usr/bin/env bash

# Bluetooth headset profile toggle (WH-1000XM4)
#
# ------------------------------------------------------------
# Regolith/i3 keybinding setup (for future machine rebuilds)
# ------------------------------------------------------------
# 1) Make this script executable:
#      chmod +x /home/marios/PycharmProjects/linux-util-scripts/bluetooth_headset_switcher.sh
#
# 2) Create a Regolith user config partial (recommended path):
#      mkdir -p /home/marios/.config/regolith3/i3/config.d
#      nano /home/marios/.config/regolith3/i3/config.d/90-bluetooth-toggle
#
# 3) Add one or both bindings in that file (example):
#      bindsym $mod+Shift+u exec --no-startup-id /home/marios/PycharmProjects/linux-util-scripts/bluetooth_headset_switcher.sh
#      bindsym $mod+Shift+y exec --no-startup-id /home/marios/PycharmProjects/linux-util-scripts/bluetooth_headset_switcher.sh --silent
#
# 4) Reload i3/Regolith:
#      i3-msg reload
#
# Notes:
# - In Regolith, user partials under ~/.config/regolith3/i3/config.d/ are safer than
#   replacing the full i3 config file.
# - Use absolute paths in bindings so they keep working from any app/window.

# Exit on:
# - any command failure (-e)
# - unset variable use (-u)
# - failed command inside a pipeline (-o pipefail)
set -euo pipefail

# -----------------------------
# Configuration (edit if needed)
# -----------------------------

# Your headset MAC address (preferred target when connected).
PREFERRED_MAC="88:C9:E8:07:6B:B6"

# PipeWire/PulseAudio card name for the same headset.
PREFERRED_CARD="bluez_card.88_C9_E8_07_6B_B6"

# Audio profiles to switch between.
# Music mode: plain SBC as requested.
MUSIC_PROFILE="a2dp-sink"

# Meeting mode with mic (first choice and fallback).
MEETING_PROFILE_PRIMARY="headset-head-unit-msbc"
MEETING_PROFILE_FALLBACK="headset-head-unit"

# Different cue sounds per mode (option 2).
# These are short system sound files available on Ubuntu.
MUSIC_CUE_FILE="/usr/share/sounds/freedesktop/stereo/complete.oga"
MEETING_CUE_FILE="/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"

# Cooldown to prevent accidental rapid double-trigger from keybindings.
COOLDOWN_SECONDS=1
COOLDOWN_FILE="/tmp/bluetooth_headset_toggle.cooldown"

# Runtime flag toggled by --silent.
SILENT_MODE=0


# ------------------------------------------
# Notification helper with fallback behavior
# ------------------------------------------
# This function tries multiple ways to show a message:
#   1) notify-send (desktop notification)
#   2) i3-nagbar for warning/error if notify-send is not available
#   3) stderr/stdout as final fallback
#
# Usage:
#   notify_user "info" "Title" "Message"
#   notify_user "warning" "Title" "Message"
#   notify_user "error" "Title" "Message"
notify_user() {
  local level="$1"
  local title="$2"
  local message="$3"

  local urgency="normal"
  case "$level" in
    info) urgency="normal" ;;
    warning) urgency="normal" ;;
    error) urgency="critical" ;;
    *) urgency="normal" ;;
  esac

  # Always print a log line too, so manual runs are never silent.
  # - stderr for warning/error
  # - stdout for info
  if [[ "$level" == "error" ]]; then
    echo "[ERROR] $title - $message" >&2
  elif [[ "$level" == "warning" ]]; then
    echo "[WARN] $title - $message" >&2
  else
    echo "[INFO] $title - $message"
  fi

  # Preferred path: desktop notification.
  if command -v notify-send >/dev/null 2>&1; then
    if notify-send -u "$urgency" "$title" "$message" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Visible fallback for i3 users on warnings/errors.
  if [[ "$level" != "info" ]] && command -v i3-nagbar >/dev/null 2>&1; then
    # Run in background so the script can finish immediately.
    i3-nagbar -m "$title: $message" >/dev/null 2>&1 &
    return 0
  fi

  # Last fallback already covered by terminal output above.
}


# ---------------------------------------
# Parse command-line flags (currently only --silent)
# ---------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --silent)
        SILENT_MODE=1
        shift
        ;;
      -h|--help)
        cat <<'USAGE'
Usage: ./script.sh [--silent]

Options:
  --silent   Switch profile but skip headset cue sounds.
  -h, --help Show this help text.
USAGE
        exit 0
        ;;
      *)
        notify_user "error" "Bluetooth audio" "Unknown option: $1"
        exit 2
        ;;
    esac
  done
}


# ---------------------------------------
# Simple cooldown guard
# ---------------------------------------
# Returns 0 when execution is allowed.
# Returns 1 when called too quickly after previous run.
cooldown_allows_run() {
  local now_ts
  now_ts="$(date +%s)"

  # If no timestamp file exists yet, allow run and create one.
  if [[ ! -f "$COOLDOWN_FILE" ]]; then
    echo "$now_ts" > "$COOLDOWN_FILE"
    return 0
  fi

  local last_ts
  last_ts="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"

  # Basic numeric sanity check.
  if ! [[ "$last_ts" =~ ^[0-9]+$ ]]; then
    last_ts=0
  fi

  if (( now_ts - last_ts < COOLDOWN_SECONDS )); then
    return 1
  fi

  # Update timestamp when cooldown passed.
  echo "$now_ts" > "$COOLDOWN_FILE"
  return 0
}


# ------------------------------------------------------
# Return connected Bluetooth MACs (one per line, or none)
# ------------------------------------------------------
get_connected_macs() {
  bluetoothctl devices Connected 2>/dev/null | awk '{print $2}'
}


# -----------------------------------------------------
# Check whether a PipeWire/PulseAudio card currently exists
# -----------------------------------------------------
card_exists() {
  local card_name="$1"
  pactl list cards short 2>/dev/null | awk '{print $2}' | grep -Fxq "$card_name"
}


# ---------------------------------------------------------
# Pick the headset card to control
# Priority:
#   1) preferred XM4 card if connected and present
#   2) first connected Bluetooth device that has a bluez card
# ---------------------------------------------------------
pick_target_card() {
  local connected_macs
  connected_macs="$(get_connected_macs)"

  # Nothing connected at all.
  if [[ -z "$connected_macs" ]]; then
    return 1
  fi

  # Preferred headset path.
  if echo "$connected_macs" | grep -Fxq "$PREFERRED_MAC" && card_exists "$PREFERRED_CARD"; then
    echo "$PREFERRED_CARD"
    return 0
  fi

  # Fallback path: first connected Bluetooth MAC that maps to a bluez card.
  local mac
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    local candidate_card="bluez_card.${mac//:/_}"
    if card_exists "$candidate_card"; then
      echo "$candidate_card"
      return 0
    fi
  done <<< "$connected_macs"

  # Connected devices exist, but none are audio cards.
  return 1
}


# --------------------------------------------------
# Read active profile for one specific card
# --------------------------------------------------
get_active_profile() {
  local card_name="$1"

  pactl list cards 2>/dev/null | awk -v card="$card_name" '
    /^[[:space:]]*Name: / { in_card = ($2 == card) }
    in_card && /^[[:space:]]*Active Profile: / {
      print $3
      exit
    }
  '
}


# --------------------------------------------------
# Check if a profile exists on the target card
# --------------------------------------------------
profile_available() {
  local card_name="$1"
  local profile_name="$2"

  pactl list cards 2>/dev/null | awk -v card="$card_name" -v profile="$profile_name" '
    /^[[:space:]]*Name: / { in_card = ($2 == card) }
    in_card && /^[[:space:]]*Profiles:/ { in_profiles = 1; next }
    in_card && in_profiles && /^[[:space:]]*Active Profile:/ { exit }
    in_card && in_profiles && $1 ~ ("^" profile ":$") { found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}


# --------------------------------------------------
# Find a headset sink that belongs to the target card
# --------------------------------------------------
# We derive the sink prefix from card name:
#   bluez_card.88_C9... -> bluez_output.88_C9...
get_sink_for_card() {
  local card_name="$1"
  local card_suffix="${card_name#bluez_card.}"
  local sink_prefix="bluez_output.${card_suffix}."

  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -m1 -E "^${sink_prefix}"
}


# --------------------------------------------------
# Play a short cue only on headset sink (never speaker)
# --------------------------------------------------
play_mode_cue() {
  local card_name="$1"
  local target_profile="$2"

  # Respect --silent flag.
  if [[ "$SILENT_MODE" -eq 1 ]]; then
    return 0
  fi

  # If paplay is missing, skip quietly with warning.
  if ! command -v paplay >/dev/null 2>&1; then
    notify_user "warning" "Bluetooth audio" "paplay not found; skipping cue sound"
    return 0
  fi

  # Profile switch can take a moment to expose the new sink name.
  # Retry for a short period before giving up.
  local sink_name=""
  local attempt
  for attempt in {1..10}; do
    sink_name="$(get_sink_for_card "$card_name" || true)"
    if [[ -n "$sink_name" ]]; then
      break
    fi
    sleep 0.2
  done

  # Enforce headset-only playback: if no headset sink, do not play anywhere else.
  if [[ -z "$sink_name" ]]; then
    notify_user "warning" "Bluetooth audio" "No headset sink found for cue; skipped to avoid speaker output"
    return 0
  fi

  local cue_file
  local cue_repeats=1
  local cue_gap_seconds=0.15

  # Meeting-mode transition can drop the first very short sound while the
  # headset path is still settling. So we use a slightly stronger cue and
  # play it twice for reliability.
  if [[ "$target_profile" == "$MUSIC_PROFILE" ]]; then
    cue_file="$MUSIC_CUE_FILE"
  else
    cue_file="$MEETING_CUE_FILE"
    cue_repeats=2
  fi

  if [[ ! -f "$cue_file" ]]; then
    notify_user "warning" "Bluetooth audio" "Cue file missing: $cue_file"
    return 0
  fi

  # Explicit --device keeps playback on headset only.
  local i
  for (( i=1; i<=cue_repeats; i++ )); do
    paplay --device="$sink_name" "$cue_file" >/dev/null 2>&1 || {
      notify_user "warning" "Bluetooth audio" "Failed to play cue on headset sink"
      return 0
    }
    if (( i < cue_repeats )); then
      sleep "$cue_gap_seconds"
    fi
  done
}


# -----------------
# Main toggle logic
# -----------------
main() {
  # Parse optional flags first.
  parse_args "$@"

  # Debounce rapid repeats from keyboard shortcut presses.
  if ! cooldown_allows_run; then
    notify_user "warning" "Bluetooth audio" "Toggle ignored (cooldown ${COOLDOWN_SECONDS}s)"
    exit 0
  fi

  local card_name
  if ! card_name="$(pick_target_card)"; then
    notify_user "warning" "Bluetooth audio" "No connected Bluetooth headset audio card found."
    exit 1
  fi

  local active_profile
  active_profile="$(get_active_profile "$card_name")"

  # Safety check: if active profile is empty, something is off.
  if [[ -z "$active_profile" ]]; then
    notify_user "error" "Bluetooth audio" "Could not read active profile for $card_name"
    exit 1
  fi

  local target_profile

  # If we are in any headset-head-unit mode, switch to music (A2DP SBC).
  if [[ "$active_profile" == headset-head-unit* ]]; then
    target_profile="$MUSIC_PROFILE"

    if ! profile_available "$card_name" "$target_profile"; then
      notify_user "error" "Bluetooth audio" "Profile '$target_profile' is not available on $card_name"
      exit 1
    fi

  # Otherwise switch to meeting mode (prefer mSBC, fallback to generic HSP/HFP).
  else
    if profile_available "$card_name" "$MEETING_PROFILE_PRIMARY"; then
      target_profile="$MEETING_PROFILE_PRIMARY"
    elif profile_available "$card_name" "$MEETING_PROFILE_FALLBACK"; then
      target_profile="$MEETING_PROFILE_FALLBACK"
    else
      notify_user "error" "Bluetooth audio" "No headset profile available on $card_name"
      exit 1
    fi
  fi

  # Apply the profile switch.
  if pactl set-card-profile "$card_name" "$target_profile" >/dev/null 2>&1; then
    notify_user "info" "Bluetooth audio" "Switched $card_name: $active_profile → $target_profile"
    play_mode_cue "$card_name" "$target_profile"
  else
    notify_user "error" "Bluetooth audio" "Failed to switch $card_name to $target_profile"
    exit 1
  fi
}

main "$@"
