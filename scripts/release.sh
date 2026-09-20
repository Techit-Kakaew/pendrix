#!/bin/zsh
# Cut a release: bump version, build universal dmg, publish a GitHub release the in-app updater can find.
#   scripts/release.sh 0.2.0 ["release notes"]
# Needs: gh (logged in), the repo in Config.updateRepo (default Techit-Kakaew/pendrix) to exist and be `origin`.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?version, e.g. 0.2.0}"
NOTES="${2:-Pendrix $VER}"
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" Info.plist
./build.sh --dmg
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add Info.plist && git commit -m "release: v$VER" >/dev/null || true
  git tag -f "v$VER" && git push && git push -f origin "v$VER"
fi
gh release create "v$VER" "dist/Pendrix-$VER.dmg" "dist/Pendrix-$VER.dmg.sha256" --title "Pendrix $VER" --notes "$NOTES"
echo "released v$VER"
