#!/usr/bin/env bash
#
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit
set -euo pipefail

#— 1) ROOT CHECK
if (( EUID != 0 )); then
  echo "ERROR: please run as root (sudo)" >&2
  exit 1
fi

#— 2) VARIABLES
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

#— 3) UPDATE & UPGRADE
echo "1/6: Updating package lists..."
apt-get update -qq
echo "2/6: Upgrading installed packages..."
apt-get upgrade -qq -y

#— 4) INSTALL DEPENDENCIES
echo "3/6: Installing dependencies..."
apt-get install -qq -y \
  ffmpeg screen x11-xserver-utils unclutter \
  xorg xinit git curl

#— 5) PREPARE DIRECTORIES
echo "4/6: Preparing directories..."
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"

#— 6) PROMPT FOR RTSP FEEDS
echo "5/6: Enter your RTSP URLs."
for set_num in 1 2 3; do
  echo
  read -rp "Press [Enter] to begin set #$set_num…" _
  file="$FEED_DIR/set${set_num}.txt"
  : > "$file"
  echo "  Enter 4 RTSP URLs for camera set #$set_num:"
  for cam in 1 2 3 4; do
    read -rp "    URL #$cam: " url
    echo "$url" >> "$file"
  done
  chown "$USER_NAME":"$USER_NAME" "$file"
done

#— 7) WRITE ROTATE SCRIPT
echo "6/6: Writing rotate-views.sh…"
cat > "$SCRIPT" << 'EOF'
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

#— 8) CONFIGURE TTY1 AUTOLOGIN
echo "Configuring autologin on tty1…"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOC'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin '"'"$USER_NAME"'"' --noclear %I $TERM
EOC
systemctl daemon-reload
systemctl enable getty@tty1.service

#— 9) SET UP AUTO-STARTX
echo "Setting up startx on login…"
BASH_PROFILE="$HOME_DIR/.bash_profile"
if ! grep -q 'exec xinit' "$BASH_PROFILE" 2>/dev/null; then
  cat >> "$BASH_PROFILE" << 'EOB'

# Auto-launch X + RTSP grid on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1
fi
EOB
  chown "$USER_NAME":"$USER_NAME" "$BASH_PROFILE"
fi

echo
echo "✅ Deployment complete! Reboot now to start the RTSP viewer."
