#!/usr/bin/env bash
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit with task list UI
set -euo pipefail

### Spinner and task list UI ###
TASKS=(
  "Check root privileges"
  "Update & upgrade packages"
  "Install dependencies"
  "Prepare directories"
  "Prompt for RTSP feeds"
  "Write rotate-views.sh"
  "Configure tty1 autologin"
  "Set up auto-startx"
)
TOTAL=${#TASKS[@]}

# Display tasks
echo
for task in "${TASKS[@]}"; do
  printf " [ ] %s\n" "$task"
done

# mark_done: mark task index with check
mark_done() {
  local idx=$1
  # Move cursor up
  tput cuu $((TOTAL - idx))
  # Overwrite line
  printf " \e[32m[✔]\e[0m %s\n" "${TASKS[$idx]}"
  # Move cursor down to bottom
  tput cud $((TOTAL - idx - 1))
}

# Spinner function
spin() {
  local pid=$1 msg=$2
  local sp="|/-\\" i=0
  printf "%s " "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    printf "\b%s" "${sp:i++%${#sp}:1}"
    sleep 0.1
  done
  printf "\b✅\n"
}

# 1) Check root
if ((EUID != 0)); then
  echo "ERROR: Run as root (sudo)." >&2; exit 1
fi
mark_done 0

# 2) Update & upgrade packages
( apt update -qq >/dev/null 2>&1 && apt upgrade -qq -y >/dev/null 2>&1 ) &
pid=$!
spin $pid "Updating packages…"
mark_done 1

# 3) Install dependencies
( apt install -qq -y ffmpeg screen x11-xserver-utils unclutter \
    xorg xinit git curl >/dev/null 2>&1 ) &
pid=$!
spin $pid "Installing dependencies…"
mark_done 2

# 4) Prepare directories
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"
mark_done 3

# 5) Prompt for RTSP feeds
prompt_feeds() {
  for set_num in 1 2 3; do
    local file="$FEED_DIR/set${set_num}.txt"
    echo
    echo "⏺ Enter 4 RTSP URLs for set #${set_num}:"
    : >"$file"
    for cam in 1 2 3 4; do
      read -rp "  URL #${cam}: " url
      echo "$url" >>"$file"
    done
    chown "$USER_NAME":"$USER_NAME" "$file"
  done
}
if [[ -f "$FEED_DIR/set1.txt" && -f "$FEED_DIR/set2.txt" && -f "$FEED_DIR/set3.txt" ]]; then
  read -rp "Keep existing feeds? [Y/n]: " yn
  yn="${yn:-Y}"
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    prompt_feeds
  fi
else
  prompt_feeds
fi
mark_done 4

# 6) Write rotate-views.sh
SCRIPT="$BASE_DIR/rotate-views.sh"
echo
spin_cmd="Writing rotate-views.sh…"
# simulate spin
( sleep 0.1 ) & pid=$!
spin $pid "$spin_cmd"
cat >"$SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

FEEDS="/opt/rtsp-viewer/feeds"
DURATION=30

play_set() {
  local file="$1"
  mapfile -t cams < "$file"
  local pids=()
  for i in {0..3}; do
    local x=$(( (i % 2) * 960 ))
    local y=$(( (i / 2) * 540 ))
    ffplay \
      -fflags nobuffer \
      -flags low_delay \
      -rtsp_transport tcp \
      -noborder \
      -x 960 -y 540 \
      -left "$x" -top "$y" \
      "${cams[$i]}" >/dev/null 2>&1 &
    pids+=( "$!" )
  done
  sleep "$DURATION"
  kill "${pids[@]}" 2>/dev/null || true
}

while true; do
  play_set "$FEEDS/set1.txt"
  play_set "$FEEDS/set2.txt"
  play_set "$FEEDS/set3.txt"
done
EOF
chmod +x "$SCRIPT"
chown "$USER_NAME":"$USER_NAME" "$SCRIPT"
mark_done 5

# 7) Configure tty1 autologin
( mkdir -p /etc/systemd/system/getty@tty1.service.d && \
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOC'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I $TERM
EOC
) >/dev/null 2>&1
systemctl daemon-reload
systemctl enable getty@tty1.service
mark_done 6

# 8) Set up auto-startx
BASHP="$HOME_DIR/.bash_profile"
if ! grep -q 'exec xinit /opt/rtsp-viewer/rotate-views.sh' "$BASHP" 2>/dev/null; then
  cat >>"$BASHP" << 'EOB'

# Auto-launch X + RTSP grid on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1
fi
EOB
  chown "$USER_NAME":"$USER_NAME" "$BASHP"
fi
mark_done 7

echo
echo "All tasks completed! Reboot to start the RTSP viewer."
