#!/bin/zsh
# Baut die Menueleisten-App und legt sie als App-Bundle nach ~/Applications/Laufband.app.
#   ./build_app.sh            bauen + Bundle aktualisieren
#   ./build_app.sh --restart  zusaetzlich die laufende App neu starten
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Laufband.app"
swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LaufbandMenuBar "$APP/Contents/MacOS/Laufband"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
if [[ -f Bundle/AppIcon.icns ]]; then
  cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Bundle aktualisiert: $APP"

if [[ "${1:-}" == "--restart" ]]; then
  launchctl kickstart -k "gui/$(id -u)/de.straubmueller.laufbandmenubar"
  echo "App neu gestartet"
fi
