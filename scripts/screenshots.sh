#!/usr/bin/env bash
#
# Every screenshot in docs/screenshots, regenerated.
#
# The rule this exists to make cheap: change the UI, change the screenshots, in the
# same commit. A stale screenshot is worse than none - it is a confident picture of a
# product that no longer exists, and it is what someone judges this by before they
# ever run it.
#
#   bash scripts/screenshots.sh            # everything
#   bash scripts/screenshots.sh mac        # just the macOS ones
#   bash scripts/screenshots.sh ios        # just iPad and iPhone
#
# The web shots are not here: headless Chrome races the page badly enough that it
# needs a human to confirm the overlay actually rendered. See AGENTS.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
shots="$here/docs/screenshots"
what="${1:-all}"

mac() {
  echo "==> macOS, via the offscreen renderer"
  # A real NSWindow rendered offscreen. `ImageRenderer` is the wrong tool: it will not
  # draw a live TextField and it ignores the drawing appearance.
  ( cd "$here/Examples/LoupeDemo" && swift run LoupeSnapshots "$shots" )
}

device() {
  xcrun simctl list devices available | grep -m1 -F "$1" \
    | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}'
}

ios() {
  echo "==> iPad and iPhone, by driving the real app"
  local dd; dd="$(mktemp -d)"
  local pad phone
  # Named models, not "the first iPad". More than one agent works this repo and its
  # adopter, and picking whatever came first in the list meant screenshotting whatever
  # somebody else had in the foreground - once, a whole page of the adopter's real
  # app, on its way into a public README. Override with LOUPE_SHOT_IPAD /
  # LOUPE_SHOT_IPHONE if these models are not on your machine.
  pad="$(device "${LOUPE_SHOT_IPAD:-iPad mini}")"
  phone="$(device "${LOUPE_SHOT_IPHONE:-iPhone 17 Pro}")"
  [ -n "$pad" ] && [ -n "$phone" ] || {
    echo "no simulator matching '${LOUPE_SHOT_IPAD:-iPad mini}' / '${LOUPE_SHOT_IPHONE:-iPhone 17 Pro}'"
    echo "set LOUPE_SHOT_IPAD and LOUPE_SHOT_IPHONE, or run: xcrun simctl list devices available"
    exit 1
  }

  ( cd "$here/Examples/LoupeDemoApp" && xcodegen generate >/dev/null )
  ( cd "$here/Examples/LoupeDemoApp" && xcodebuild build \
      -project LoupeDemo.xcodeproj -scheme LoupeDemo \
      -destination "id=$pad" -derivedDataPath "$dd" \
      CODE_SIGNING_ALLOWED=NO >/dev/null )

  local app="$dd/Build/Products/Debug-iphonesimulator/LoupeDemo.app"

  # `simctl terminate` often does not take, and a surviving process keeps the previous
  # run's notes - which reads as a bug in the next screenshot. Reinstall every time.
  shoot() { # device, scene, filename
    xcrun simctl boot "$1" 2>/dev/null || true
    xcrun simctl bootstatus "$1" -b >/dev/null 2>&1 || true
    xcrun simctl uninstall "$1" dev.loupe.demo >/dev/null 2>&1 || true
    xcrun simctl install "$1" "$app" >/dev/null
    xcrun simctl launch "$1" dev.loupe.demo "scene=$2" >/dev/null
    sleep 5
    # Whose app is actually in front of the camera. Another agent driving the same
    # simulator will happily put its own app there, and the picture looks fine.
    local front
    front="$(xcrun simctl listapps "$1" >/dev/null 2>&1; \
             xcrun simctl launch "$1" dev.loupe.demo 2>&1 | head -1)"
    case "$front" in
      *dev.loupe.demo*) ;;
      *) echo "    !! the demo is not in front on $1 - got: $front"; return 1 ;;
    esac
    xcrun simctl io "$1" screenshot "$shots/$3" >/dev/null 2>&1
    echo "    $3"
  }

  shoot "$pad"   pick  06-ipad-pick.png
  shoot "$pad"   tray  07-ipad-tray.png
  shoot "$phone" tray  08-iphone-sheet.png
  shoot "$pad"   drag  09-ipad-drag-region.png
  rm -rf "$dd"
}

case "$what" in
  mac) mac ;;
  ios) ios ;;
  all) mac; ios ;;
  *) echo "usage: screenshots.sh [mac|ios|all]"; exit 2 ;;
esac
# A shot nothing points at is either about to go stale unnoticed or is already dead.
orphans() {
  echo "==> screenshots nothing references"
  local found=0
  for f in "$shots"/*.png; do
    local name; name="$(basename "$f")"
    if ! grep -rql --include='*.md' --include='*.html' --include='*.ts' \
         --exclude-dir=node_modules "$name" "$here" 2>/dev/null; then
      echo "    orphan: $name"
      found=1
    fi
  done
  [ "$found" = 0 ] && echo "    none"
  return 0
}

orphans
echo "==> done. Look at them before you commit them."
