#!/usr/bin/env bash
#
# rtsp-deploy.sh — install RTSP viewer + autologin + xinit with baked HW-accel flags
set -e -o pipefail

### 1) Root check
if (( EUID != 0 )); then
  echo "ERROR: run as root (sudo)" >&2
  exit 1
fi

### 2) Variables
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

### 3) Update & upgrade
echo "1/6: Updating package lists..."
touch ~/apt.log
apt-get update &>> ~/apt.log 
echo "2/6: Upgrading packages..."
apt-get upgrade -y &>> ~/apt.log

### 4) Install dependencies + VA-API tools
echo "3/6: Installing dependencies + VA-API tooling..."
apt-get install -y \
  ffmpeg screen x11-xserver-utils unclutter \
  xorg xinit git curl \
  vainfo intel-media-va-driver-non-free &>> ~/apt.log

### 5) Probe for real H.264 decode support
echo -n "   Probing VA-API for H.264 decode support… "
if vainfo 2>&1 | grep -q 'VAProfileH264.*VAEntrypoint.*VLD'; then
  echo "found."
  HWFLAGS="-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi"
else
  echo "not found; software fallback."
  HWFLAGS=""
fi

### 6) Prepare directories
echo "4/6: Preparing directories..."
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"

### 7) Write the RTSP feed files (hard-coded)
echo "5/6: Writing RTSP feed lists…"
cat > "$FEED_DIR/set1.txt" <<EOF
rtsps://10.0.23.1:7441/FnYrNPfHNWVaROyy?enableSrtp
rtsps://10.0.23.1:7441/BZKLt5TQ23oT6gf3?enableSrtp
rtsps://10.0.23.1:7441/vG4KDLEyFDcMSufH?enableSrtp
rtsps://10.0.23.1:7441/jhsn4gHsXtv1CIQY?enableSrtp
EOF

cat > "$FEED_DIR/set2.txt" <<EOF
rtsps://10.0.23.1:7441/dacNxekxq3U2Zsg2?enableSrtp
rtsps://10.0.23.1:7441/sxwTFZMuF9Cg2lcy?enableSrtp
rtsps://10.0.23.1:7441/BWQ9L2nMjZUZh8Z8?enableSrtp
rtsps://10.0.23.1:7441/RIyAFigT0foCy8wp?enableSrtp
EOF

cat > "$FEED_DIR/set3.txt" <<EOF
rtsps://10.0.23.1:7441/g5iXuY0PzPO50jQJ?enableSrtp
rtsps://10.0.23.1:7441/fGUUVqUA3rOV9dmE?enableSrtp
rtsps://10.0.23.1:7441/L7q0oP9yUR2tK2Sk?enableSrtp
rtsps://10.0.23.1:7441/IFIapnss0tr60pUd?enableSrtp
EOF

chown "$USER_NAME":"$USER_NAME" "$FEED_DIR"/*.txt

### 8) Write rotate-views.sh with baked HWFLAGS
echo "6/6: Writing rotation script to $SCRIPT…"
mkdir -p "$(dirname "$SCRIPT")"

cat > "$SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Where our feed files live
FEEDS="$FEED_DIR"
# How long each 2×2 grid stays on-screen
DURATION=30
# Any hardware-accel flags we detected at deploy
HWFLAGS="$HWFLAGS"
# Low-latency flags, always the same
LOWER_FLAGS="-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0"

play_set() {
  local file="\$1"
  mapfile -t cams < "\$file"
  local pids=()
  for idx in 0 1 2 3; do
    local x=\$(( (idx % 2) * 960 ))
    local y=\$(( (idx / 2) * 540 ))
    ffplay \\
      \$LOWER_FLAGS \\
      \$HWFLAGS \\
      -rtsp_transport tcp \\
      -noborder \\
      -x 960 -y 540 \\
      -left "\$x" -top "\$y" \\
      "\${cams[\$idx]}" \\
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

### 9) Autologin drop-in for tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service

### 10) /etc/profile.d launcher for X
cat >/etc/profile.d/rtsp-viewer.sh <<EOF
#!/usr/bin/env bash
# Launch RTSP viewer on tty1 after autologin
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
  exec xinit $SCRIPT -- :0 vt1
fi
EOF
chmod +x /etc/profile.d/rtsp-viewer.sh

echo
echo "✅ Deployment complete! Reboot to start the RTSP viewer."
