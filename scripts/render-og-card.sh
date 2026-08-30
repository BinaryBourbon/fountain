#!/bin/sh
set -eu

repo_dir=$(
  CDPATH= cd -- "$(dirname -- "$0")/.."
  pwd
)
source_file="$repo_dir/scripts/og-card.svg"
target_file="$repo_dir/apps/fountain/priv/static/images/og-card.png"

if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert --width 1200 --height 630 "$source_file" --output "$target_file"
elif command -v google-chrome >/dev/null 2>&1; then
  chrome=$(command -v google-chrome)
elif command -v chromium >/dev/null 2>&1; then
  chrome=$(command -v chromium)
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else
  echo "render-og-card: install librsvg (rsvg-convert), Chrome or Chromium" >&2
  exit 1
fi

if [ "${chrome:-}" ]; then
  "$chrome" \
    --headless \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=1200,630 \
    --screenshot="$target_file" \
    "file://$source_file" >/dev/null 2>&1
fi

echo "rendered $target_file"
