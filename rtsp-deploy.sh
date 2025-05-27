#!/usr/bin/env bash
#
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit with VA-API detection
set -e -o pipefail

# 1) Root check
if (( EUID != 0 )); then
  echo "ERROR: please run as root (sudo)" >&2
  exit 1
fi

# 2) Variables
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

# 3) Update & upgrade
echo "1/6: Updating package lists..."
apt-get update -qq

echo "2/6: Upgrading installed packages..."
apt-get upgrade -qq -y

# 4) Install dependencies
echo "3/6: Installing dependencies..."
apt-get install -qq -y \
  ffmpeg screen x11-xserver-utils unclutter \
  xorg xinit git curl

# 5) Prepare directories
echo "4/6: Preparing directories..."
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"

# 6) Prompt for RTSP feeds
echo "5/6: Enter your RTSP URLs (4 per set)."
for set_num in 1 2 3; do
  echo
  read -rp "▶ Press [Enter] to begin entering URLs for set #$set_num…" dummy
  out="$FEED_DIR/set${set_num}.txt"
  : >"$out"
  echo "  Enter 4 RTSP URLs for camera set #$set_num:"
  for cam in 1 2 3 4; do
    read -rp "    URL #$cam: " url
    echo "$url" >>"$out"
  done
  chown "$USER_NAME":"$USER_NAME" "$out"
done

# 7) Write rotate-views.sh
echo "6/6: Writing $SCRIPT…"
mkdir -p "$(dirname "$SCRIPT")"
cat > "$SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

FEEDS="/opt/rtsp-viewer/feeds"
DURATION=30

# Detect VA-API device for hardware decode
if [[ -e /dev/dri/renderD128 ]]; then
  HW_FLAGS=(
    -hwaccel vaapi
    -hwaccel_device /dev/dri/renderD128
    -hwaccel_output_format vaapi
  )
else
  HW_FLAGS=()
fi

# Low-latency flags
LOWLATENCY=(
  -fflags nobuffer
  -flags low_delay
  -probesize 32
  -analyzeduration 0
)

play_set() {
  local file="\$1"
  mapfile -t cams < "\$file"
  local pids=()
  for i in {0..3}; do
    local x=\$(( (i % 2) * 960 ))
    local y=\$(( (i / 2) * 540 ))
    ffplay \
      "\${HW_FLAGS[@]}" \
      "\${LOWLATENCY[@]}" \
      -rtsp_transport tcp \
      -noborder \
      -x 960 -y 540 \
      -left "\$x" -top "\$y" \
      "\${cams[\$i]}" \
      >/dev/null 2>&1 &
    pids+=( "\$!" )
  done
  sleep "\$DURATION"
  kill "\${pids[@]}" 2>/dev/null || true
}

while true; do
  play_set "\$FEEDS/set1.txt"
  play_set "\$FEEDS/set2.txt"
  play_set "\$FEEDS/set3.txt"
done
EOF

chmod +x "$SCRIPT"
chown "$USER_NAME":"$USER_NAME" "$SCRIPT"

# 8) Configure tty1 autologin
echo "Configuring auto-login on tty1…"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOINLOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin '"'"$USER_NAME"'"' --noclear %I \$TERM
AUTOINLOG

systemctl daemon-reload
systemctl enable getty@tty1.service

# 9) Auto-start X on tty1 login
echo "Setting up startx on login…"
PROFILE="$HOME_DIR/.bash_profile"
if ! grep -q 'exec xinit /opt/rtsp-viewer/rotate-views.sh' "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" << 'PORTAL'

# Auto-launch RTSP viewer on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1
fi
PORTAL
  chown "$USER_NAME":"$USER_NAME" "$PROFILE"
fi

echo
echo "✅ Deployment complete! Reboot now to start the RTSP viewer."
