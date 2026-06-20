#!/bin/bash
# Run the Agent Watch bridge INSIDE cmux (a cmux workspace/surface) so it shares
# cmux's GUI login session and can reach the cmux control socket. A launchd
# agent runs in a different audit session that cmux's socket rejects, so the
# cmux-mirror feature requires the bridge to live in-session.
#
# Launch with:  cmux workspace create --name "Agent Bridge" --command "/Users/limseungwon/claude-watch/skill/bridge/run-in-cmux.sh"
# Restart loop keeps the bridge up across crashes; cmux session-restore brings
# this workspace back after a cmux restart.

cd "$(dirname "$0")" || exit 1
NODE="/Users/limseungwon/.local/bin/node"
[ -x "$NODE" ] || NODE="$(command -v node)"

while true; do
  echo "[run-in-cmux] starting bridge ($(date '+%H:%M:%S'))"
  "$NODE" server.js
  echo "[run-in-cmux] bridge exited ($?), restarting in 2s…"
  sleep 2
done
