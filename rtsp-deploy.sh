#!/usr/bin/env bash
#
# rtsp-deploy.sh
#

set -euo pipefail

# 1) Deploy user
USER_NAME="${SUDO_USER:-ubuntu}"
HOME_DIR="/home/$USER_NAME"

# 2) Paths
BASE_DIR="/opt/rtsp-viewer"
FEED_DIR="$BASE_DIR/feeds"
SCRIPT="$BASE_DIR/rotate-views.sh"

# 3) Must run as root
if (( EUID != 0 )); then
  echo "⚠️  Run as root (sudo)." >&2
  exit 1
fi

echo "🛠 Installing dependencies…"
apt update -y && apt upgrade -y
apt install -y ffmpeg screen x11-xserver-utils unclutter \
               xorg xinit git curl

echo "📂 Preparing directories…"
mkdir -p "$FEED_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR"

# 4) Prompt for RTSP feeds (or reuse existing)
prompt_feeds(){
  for set in 1 2 3; do
    file="$FEED_DIR/set${set}.txt"
    echo
    echo "⏺ Enter 4 RTSP URLs for set #$set:"
    : >"$file"
    for i in 1 2 3 4; do
      read -rp "   URL #$i: " url
      echo "$url" >>"$file"
    done
    chown "$USER_NAME":"$USER_NAME" "$file"
  done
}

if [[ -f "$FEED_DIR/set1.txt" && -f "$FEED_DIR/set2.txt" && -f "$FEED_DIR/set3.txt" ]]; then
  read -rp "Keep existing feeds? [Y/n]: " yn
  yn=${yn:-Y}
  if [[ ! $yn =~ ^[Yy]$ ]]; then
    prompt_feeds
  fi
else
  prompt_feeds
fi

# 5) Write the rotate-views.sh using ffplay
echo "✍️  Writing rotate-views.sh…"
cat >"$SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

FEEDS="/opt/rtsp-viewer/feeds"
DURATION=30

play_set(){
  local file="\$1"; mapfile -t cams < "\$file"; local pids=()
  for i in {0..3}; do
    x=\$(( (i%2)*960 )); y=\$(( (i/2)*540 ))
    ffplay \
      -fflags nobuffer \
      -flags low_delay \
      -rtsp_transport tcp \
      -noborder \
      -x 960 -y 540 \
      -left "\$x" -top "\$y" \
      "\${cams[\$i]}" >/dev/null 2>&1 &
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

# 6) Auto-login on tty1
echo "🔑 Configuring getty@tty1 autologin…"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service

# 7) Auto-start X/init
echo "🖥 Adding startx hook…"
BASHP="$HOME_DIR/.bash_profile"
grep -qxF 'exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1' "$BASHP" 2>/dev/null \
  || cat >>"$BASHP" <<'EOF'

# launch X with our RTSP grid on tty1
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
  exec xinit /opt/rtsp-viewer/rotate-views.sh -- :0 vt1
fi
EOF
chown "$USER_NAME":"$USER_NAME" "$BASHP"

echo -e "\n✅ Deployment done! Reboot to test – you’ll auto-login, launch X, and see your rotating 2×2 grid."