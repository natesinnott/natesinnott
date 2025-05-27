#!/usr/bin/env bash
#
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit (VA-API aware)

set -e      # exit on errors
set -o pipefail   # catch pipeline failures

# 1) Ensure root
if (( EUID != 0 )); then
  echo "ERROR: run as root (sudo)" >&2
  exit 1
fi

# 2) Variables
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

# 3) Update & upgrade
echo "1/6) Updating package lists..."
apt-get update -qq
echo "2/6) Upgrading installed packages..."
apt-get upgrade -qq -y

# 4) Install deps
echo "3/6) Installing dependencies..."
apt-get install -qq -y \
  ffmpeg screen x11-xserver-utils unclutter \
  xorg xinit git curl

# 5) Prepare directories
echo "4/6) Preparing directories..."
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"

# 6) Prompt for feeds
echo "5/6) Enter your RTSP URLs (4 per set)."
for set in 1 2 3; do
  echo
  read -rp "▶ Press [Enter] for set #$set…" _
  target="$FEED_DIR/set${set}.txt"
  : >"$target"
  echo "  Enter 4 RTSP URLs for set #$set:"
  for cam in 1 2 3 4; do
    read -rp "    URL #$cam: " url
    echo "$url" >>"$target"
  done
  chown "$USER_NAME":"$USER_NAME" "$target"
done

# 7) Write rotate-views.sh verbatim
echo "6/6) Writing rotation script..."
mkdir -p "$(dirname "$SCRIPT")"
cat >"$SCRIPT" << 'ROTATE_EOF'
#!/usr/bin/env bash
set -euo pipefail

FEEDS="/opt/rtsp-viewer/feeds"
DURATION=30

# Detect hardware-acceleration flags at runtime
detect_hw() {
  if [[ -e /dev/dri/renderD128 ]]; then
    echo -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi
  fi
}

# Build arrays
IFS=' ' read -r -a HW_FLAGS <<< "$(detect_hw)"
LOW_FLAGS=(-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0)

play_set() {
  local file="$1"
  mapfile -t cams < "$file"
  local pids=()
  for idx in 0 1 2 3; do
    local x=$(( (idx % 2) * 960 ))
    local y=$(( (idx / 2) * 540 ))
    ffplay \
      "${HW_FLAGS[@]}" \
      "${LOW_FLAGS[@]}" \
      -rtsp_transport tcp \
      -noborder \
      -x 960 -y 540 \
      -left "$x" -top "$y" \
      "${cams[$idx]}" \
      >/dev/null 2>&1 &
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
ROTATE_EOF

chmod +x "$SCRIPT"
chown "$USER_NAME":"$USER_NAME" "$SCRIPT"

# 8) Configure autologin on tty1
echo "Configuring auto-login on tty1..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin '"'"$USER_NAME"'"' --noclear %I \$TERM
AUTOLOGIN

systemctl daemon-reload
systemctl enable getty@tty1.service

# 9) Hook startx on tty1
echo "Setting up X auto-start on tty1..."
PROFILE="$HOME_DIR/.bash_profile"
if ! grep -q 'exec xinit /opt/rtsp-viewer/rotate-views.sh' "$PROFILE" 2>/dev/null; then
  cat >>"$PROFILE" << 'XEOF'

# Auto-launch RTSP viewer on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1
fi
XEOF
  chown "$USER_NAME":"$USER_NAME" "$PROFILE"
fi

echo
echo "✅ Deployment complete! Reboot to start the RTSP viewer."
