#!/usr/bin/env bash
# x11 — infinite halving countdown, with optional GUI.
#
# Usage:
#   ./x11 [start] [mode] [--gui] [--csv FILE] [--max-ticks N] [--no-sleep]
#
#   mode: frac (default, Zeno) | str
#   --gui       force a graphical frontend (yad > zenity > ANSI fallback)
#   --csv FILE  append tick,value,sleep,elapsed,frac per tick
#   --max-ticks stop after N ticks
#   --no-sleep  spin (benchmark)
#
# Ctrl-C (terminal) or close the window to stop.

set -u

start="11"; mode="frac"; csv_file=""; no_sleep=0; max_ticks=0; want_gui=0
args=()
for a in "$@"; do
  case "$a" in
    --gui)        want_gui=1 ;;
    --csv)        shift; csv_file="${1:-}"; shift || true ;;
    --csv=*)      csv_file="${a#*=}" ;;
    --no-sleep)   no_sleep=1 ;;
    --max-ticks)  shift; max_ticks="${1:-0}"; shift || true ;;
    --max-ticks=*) max_ticks="${a#*=}" ;;
    -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
    *)            args+=("$a") ;;
  esac
done
[ "${#args[@]}" -ge 1 ] && start="${args[0]}"
[ "${#args[@]}" -ge 2 ] && mode="${args[1]}"

# ---- pick frontend ----
frontend="ansi"
if [ "$want_gui" -eq 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if   command -v yad    >/dev/null 2>&1; then frontend="yad"
  elif command -v zenity >/dev/null 2>&1; then frontend="zenity"
  fi
fi

# ---- csv ----
if [ -n "$csv_file" ] && [ ! -s "$csv_file" ]; then
  printf 'tick,value,sleep,elapsed,frac\n' > "$csv_file"
fi
tick=0; t0=$(date +%s.%N)
csv_row() {  # $1 value  $2 sleep  $3 frac
  [ -z "$csv_file" ] && return 0
  local now el; now=$(date +%s.%N)
  el=$(awk -v a="$t0" -v b="$now" 'BEGIN{printf "%.6f", b-a}')
  printf '%d,%s,%s,%s,%s\n' "$tick" "$1" "$2" "$el" "$3" >> "$csv_file"
}
tick_bump() {
  tick=$((tick+1))
  if [ "$max_ticks" -gt 0 ] && [ "$tick" -ge "$max_ticks" ]; then cleanup_and_exit; fi
}
do_sleep() { [ "$no_sleep" -eq 1 ] && return 0; sleep "$1" 2>/dev/null || true; }
fmt() { printf '%.6f' "$1" | sed 's/0*$//; s/\.$//'; }

# ============================================================
#  Frontend implementations
# ============================================================

# ---------------- yad (GTK) ----------------
# One persistent window; we rewrite its text + progress via --title / echo.
YAD_PID=""
yad_start() {
  # start an empty yad progress dialog in the background, feed it on stdin
  mkfifo "${YAD_FIFO:?}" 2>/dev/null
  yad --progress --title="x11 — Zeno countdown" --width=520 --height=120 \
      --auto-close --no-buttons --percentage=0 --text="starting…" \
      < "${YAD_FIFO}" &
  YAD_PID=$!
  exec 9>"${YAD_FIFO}"
}
yad_update() {  # $1 pct  $2 text
  printf '%s\n' "$1" >&9
  printf '# %s\n' "$2" >&9
}

# ---------------- zenity ----------------
# zenity --progress reads "pct\n# comment\n" lines from stdin.
ZEN_PID=""
zenity_start() {
  mkfifo "${ZEN_FIFO:?}" 2>/dev/null
  zenity --progress --title="x11 — Zeno countdown" --width=520 \
         --auto-close --no-cancel --percentage=0 --text="starting…" \
         < "${ZEN_FIFO}" &
  ZEN_PID=$!
  exec 9>"${ZEN_FIFO}"
}
zenity_update() {
  printf '%s\n' "$1" >&9
  printf '# %s\n' "$2" >&9
}

# ---------------- ANSI TUI ----------------
ansi_start() { printf '\033[?25l'; }          # hide cursor
ansi_update() {  # $1 value  $2 pct   (frac-mode: pct = frac*100 clamped)
  local val="$1" pct="$2" w=40 filled bar i
  filled=$(awk -v p="$pct" -v w="$w" 'BEGIN{ n=int(p/100*w+0.5); if(n<0)n=0; if(n>w)n=w; print n }')
  bar=""
  for ((i=0;i<w;i++)); do
    if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
  done
  # move cursor to home, print two lines
  printf '\033[H\033[2K  x11   value = %-14s  [%s] %5.1f%%\n' "$val" "$bar" "$pct"
  printf '\033[2K  (Ctrl-C to stop)\n'
}

cleanup_and_exit() {
  [ "$frontend" = "ansi" ] && printf '\033[?25h'   # show cursor
  exec 9>&- 2>/dev/null || true
  [ -n "${YAD_PID:-}" ]  && kill "$YAD_PID"  2>/dev/null
  [ -n "${ZEN_PID:-}" ]  && kill "$ZEN_PID"  2>/dev/null
  rm -f "${YAD_FIFO:-}" "${ZEN_FIFO:-}" 2>/dev/null
  exit 0
}
trap cleanup_and_exit INT TERM EXIT

# ============================================================
#  Core countdown (same math as before)
# ============================================================
run_frac() {
  # tick 0: the big "11"
  case "$frontend" in
    yad)    yad_update    100 "11" ;;
    zenity) zenity_update 100 "11" ;;
    ansi)   ansi_update   "11" 100 ;;
  esac
  csv_row "$start" "1" "1"; tick_bump; do_sleep 1

  local whole=1 frac=0.5
  while :; do
    local val disp slp pct
    val=$(awk -v w="$whole" -v f="$frac" 'BEGIN{printf "%.17g", w+f}')
    disp="$(fmt "$val")"
    slp=$(awk  -v f="$frac" 'BEGIN{ x=f; if(x>1)x=1; printf "%.9f", x }')
    pct=$(awk  -v f="$frac" 'BEGIN{ x=f*100; if(x>100)x=100; printf "%.1f", x }')

    case "$frontend" in
      yad)    yad_update    "$pct" "$disp" ;;
      zenity) zenity_update "$pct" "$disp" ;;
      ansi)   ansi_update   "$disp" "$pct" ;;
    esac
    csv_row "$disp" "$slp" "$frac"; tick_bump; do_sleep "$slp"
    frac=$(awk -v f="$frac" 'BEGIN{printf "%.17g", f/2}')
  done
}

run_str() {
  case "$frontend" in
    yad)    yad_update    100 "$start" ;;
    zenity) zenity_update 100 "$start" ;;
    ansi)   ansi_update   "$start" 100 ;;
  esac
  csv_row "$start" "1" ""; tick_bump; do_sleep 1

  local cur="1.5"
  while :; do
    local frac="${cur#*.}" slp pct
    slp=$(awk -v s="0.$frac" 'BEGIN{ x=s+0; if(x>1)x=1; printf "%.9f", x }')
    pct=$(awk -v s="0.$frac" 'BEGIN{ x=s*100; if(x>100)x=100; printf "%.1f", x }')
    case "$frontend" in
      yad)    yad_update    "$pct" "$cur" ;;
      zenity) zenity_update "$pct" "$cur" ;;
      ansi)   ansi_update   "$cur" "$pct" ;;
    esac
    csv_row "$cur" "$slp" "$frac"; tick_bump; do_sleep "$slp"

    local n="$frac" half
    half=$(awk -v n="$n" 'BEGIN{ printf "%d", int(n/2) }')
    [ "${#half}" -lt "${#n}" ] && half=$(printf '%0*d' "${#n}" "$half")
    cur="1.${half}"
    if [[ "$half" =~ ^0+$ ]]; then
      while :; do
        case "$frontend" in
          yad)    yad_update 0 "1.0" ;;
          zenity) zenity_update 0 "1.0" ;;
          ansi)   ansi_update "1.0" 0 ;;
        esac
        csv_row "1.0" "0" "0"; tick_bump
      done
    fi
  done
}

# ============================================================
#  Boot the chosen frontend
# ============================================================
case "$frontend" in
  yad)
    YAD_FIFO="$(mktemp -u /tmp/x11yad.XXXXXX)"
    yad_start ;;
  zenity)
    ZEN_FIFO="$(mktemp -u /tmp/x11zen.XXXXXX)"
    zenity_start ;;
  ansi)
    ansi_start
    printf '\033[2J\033[H'   # clear
    ;;
esac

case "$mode" in
  frac) run_frac ;;
  str)  run_str  ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
