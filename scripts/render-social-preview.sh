#!/bin/bash
# Render the two PNGs the repo needs from the HTML that defines them.
#
#   docs/assets/social-preview.png   1280x630, upload in Settings -> Social preview
#   docs/assets/trace.png            README hero: the same trace, chart-sized
#
# Chrome is used as the renderer because it is already installed and because these
# are HTML: the histogram is the recorded trace, not an illustration of one. Both
# images are committed, so a fresh clone needs no browser to look right.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 2; }

profile=$(mktemp -d)          # left in TMPDIR: a scratch dir is not worth a recursive delete

shoot() {  # shoot <html> <png> <w> <h> <scale>
  local html="$1" png="$2" w="$3" h="$4" scale="$5"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$profile" --force-device-scale-factor="$scale" \
    --window-size="$w,$h" --screenshot="$png" \
    "file://$(cd "$(dirname "$html")" && pwd)/$(basename "$html")" >/dev/null 2>&1
  [ -s "$png" ] || { echo "render failed: $png" >&2; exit 2; }
  printf '  %-34s %s\n' "$(basename "$png")" "$(sips -g pixelWidth -g pixelHeight "$png" | awk '/pixel/{printf "%s ", $2}')"
}

echo "rendering:"
shoot docs/assets/social-preview.html docs/assets/social-preview.png 1280 630 2
shoot docs/assets/trace.html           docs/assets/trace.png           880  236 2
echo "done."