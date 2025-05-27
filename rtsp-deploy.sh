#!/usr/bin/env bash
#
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit with task list UI
set -euo pipefail

### Task list ###
TASKS=(
  "Check root privileges"          # 0
  "Update & upgrade packages"      # 1
  "Install dependencies"           # 2
  "Prepare directories"            # 3
  "Prompt for RTSP feeds"          # 4
  "Write rotate-views.sh"          # 5
  "Configure tty1 autologin"       # 6
  "Set up auto-startx"             # 7
)
TOTAL=${#TASKS[@]}

# Print initial task list
echo
for task in "${TASKS[@]}"; do
  printf " [ ] %s\n" "$task"
done

# mark_done: replace line idx with a checkmark
mark_done() {
  local idx=$1
  tput cuu $(( TOTAL - idx ))     # move cursor up
  printf " \e[32m[✔]\e[0m %s\n" "${TASKS[$idx]}"
  tput cud $(( TOTAL - idx - 1 ))  # move back down
}

# spinner: run a background job with a spinner
spin() {
  local pid=$1 msg=$2
  local sp='|/-\' i=0
  printf "%s " "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    printf "\b%s" "${sp:i++%${#sp}:1}"
    sleep 0.1
  done
  printf "\b✅\n"
}

#### 0) Check root privileges
if (( EUID != 0 )); then
  echo "ERROR: please run as root (sudo)" >&2
  exit 1
fi
mark_done 0

# Define variables
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

#### 1) Update & upgrade packages
( apt-get update -qq >/dev/null 2>&1 && apt-get upgrade -qq -y >/dev/null 2>&1 ) &
pid=$!; spin $pid "Updating system…"
mark_done 1

#### 2) Install dependencies
( apt-get install -qq -y \
    ffmpeg screen x11-xserver-utils unclutter \
    xorg xinit git curl >/dev/null 2>&1 ) &
pid=$!; spin $pid "Installing dependencies…"
mark_done 2

#### 3) Prepare directories
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"
mark_done 3

#### 4) Prompt for RTSP feeds
prompt_feeds() {
  for set_num in 1 2 3; do
    echo
    read -rp "Press [Enter] to begin entering URLs for set #$set_num…" _
    file="$FEED_DIR/set${set_num}.txt"
    : >"$file"
    echo "⏺ Enter 4 RTSP URLs for set #${set_num}:"
    for cam in 1 2 3 4; do
      read -rp "   URL #${cam}: " url
      echo "$url" >>"$file"
    done
    chown "$USER_NAME":"$USER_NAME" "$file"
  done
}

if [[ -f "$FEED_DIR/set1.txt" && -f "$FEED_DIR/set2.txt" && -f "$FEED_DIR/set3.txt" ]]; then
  read -rp "Keep existing feed files? [Y/n]: " yn
  yn="${yn:-Y}"
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    prompt_feeds
  fi
else
  prompt_feeds
fi
mark_done 4

#### 5) Write rotate-views.sh
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
    local x=$(( (i%2)*960 )); local y=$(( (i/2)*540 ))
    ffplay -fflags nobuffer -flags low_delay \
           -rtsp_transport tcp -noborder \
           -x 960 -y 540 -left "$x" -top "$y" \
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

#### 6) Configure tty1 autologin
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOC'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin '"$USER_NAME"' --noclear %I $TERM
EOC
systemctl daemon-reload
systemctl enable getty@tty1.service
mark_done 6

#### 7) Set up auto-startx
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
echo "All tasks completed! Reboot now to start the RTSP viewer."
