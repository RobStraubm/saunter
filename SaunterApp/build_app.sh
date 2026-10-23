#!/bin/zsh
# Baut die Menueleisten-App und legt sie als App-Bundle nach ~/Applications/Saunter.app.
#   ./build_app.sh            bauen + Bundle aktualisieren
#   ./build_app.sh --restart  zusaetzlich die laufende App neu starten
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Saunter.app"

# Die Command Line Tools liefern ab dem macOS-27-SDK das SwiftUI-Makro-Plugin (@State) nicht mit.
# Ohne Xcode deshalb gegen ein installiertes macOS-26-SDK bauen (SDKROOT von aussen hat Vorrang).
DEV_DIR=$(xcode-select -p)
if [[ -z "${SDKROOT:-}" && "$DEV_DIR" == *CommandLineTools* && -d "$DEV_DIR/SDKs/MacOSX26.sdk" ]] \
   && ! find "$DEV_DIR" -name 'libSwiftUIMacros*' -print -quit 2>/dev/null | grep -q .; then
  export SDKROOT="$DEV_DIR/SDKs/MacOSX26.sdk"
  echo "Command Line Tools ohne SwiftUI-Makros – baue mit $(basename "$(readlink -f "$SDKROOT")")"
fi

swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Saunter "$APP/Contents/MacOS/Saunter"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
if [[ -f Bundle/AppIcon.icns ]]; then
  cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Bundle aktualisiert: $APP"

if [[ "${1:-}" == "--restart" ]]; then
  # Laufende Instanz beenden, egal ob per launchd oder per Doppelklick gestartet; kickstart allein
  # erwischt eine per "open" gestartete App nicht und startet dann eine zweite.
  BIN="$APP/Contents/MacOS/Saunter"
  if pgrep -f "$BIN" >/dev/null; then
    osascript -e "tell application id \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")\" to quit" || true
    for _ in {1..20}; do pgrep -f "$BIN" >/dev/null || break; sleep 0.25; done
    pkill -f "$BIN" || true
  fi
  open "$APP"
  echo "App neu gestartet"
fi
