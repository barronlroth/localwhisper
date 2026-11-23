#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.localwhisper.server"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/LocalWhisper"
PORT="${PARAKEET_PORT:-43120}"
MODEL="${PARAKEET_MODEL:-mlx-community/parakeet-tdt-0.6b-v3}"
SERVE_PATH="${TAILSCALE_SERVE_PATH:-/parakeet}"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

echo "==> Syncing Python 3.14 environment with uv..."
cd "$SCRIPT_DIR"
uv sync --python 3.14

echo "==> Generating LaunchAgent: $PLIST_DST"
cat > "$PLIST_DST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/.venv/bin/uvicorn</string>
    <string>app:app</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${SCRIPT_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>PARAKEET_MODEL</key>
    <string>${MODEL}</string>
    <key>PARAKEET_KEEPWARM_SECONDS</key>
    <string>180</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
EOF

# Reload LaunchAgent cleanly (wait briefly after bootout so launchd finishes unloading)
if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  sleep 1
fi
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "==> Waiting for local server on http://127.0.0.1:${PORT}/health ..."
for _ in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:${PORT}/health" | grep -q '"ready":true'; then
    echo "==> LocalWhisper server is READY!"
    break
  fi
  sleep 0.5
done

if command -v tailscale >/dev/null 2>&1; then
  echo "==> Exposing ${SERVE_PATH} over Tailscale HTTPS (tailnet-only)..."
  tailscale serve --bg --set-path "${SERVE_PATH}" "http://127.0.0.1:${PORT}"
  echo "==> Tailscale Serve status:"
  tailscale serve status
else
  echo "==> Tailscale CLI not found; server is listening locally on http://127.0.0.1:${PORT}"
fi
