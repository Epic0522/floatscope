#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FloatScope"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Stopping $APP_NAME..."

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.5

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME is still running, forcing quit..."
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
fi

mapfile -t extra_pids < <(
  pgrep -f "$ROOT_DIR/(dist/$APP_NAME.app/Contents/MacOS/$APP_NAME|\\.build/.*/$APP_NAME)" || true
)

if ((${#extra_pids[@]} > 0)); then
  echo "Killing leftover $APP_NAME processes: ${extra_pids[*]}"
  kill -9 "${extra_pids[@]}" >/dev/null 2>&1 || true
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Failed to stop $APP_NAME." >&2
  exit 1
fi

echo "$APP_NAME stopped."
