#!/bin/zsh
# Sichert die Laufband-Steuerung komplett in den Google-Drive-Ordner „Laufband“.
# Wiederherstellen auf einem neuen Mac: install.sh aus der Sicherung ausführen.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/Library/CloudStorage/$(ls "$HOME/Library/CloudStorage" | grep -m1 '^GoogleDrive-')/Meine Ablage/Laufband"
mkdir -p "$D/Application Support" "$D/LaunchAgents" "$D/Einstellungen"

"$SRC/venv/bin/pip" freeze > "$SRC/requirements.txt"
rsync -a --delete --exclude 'laufband.db*' --exclude .DS_Store "$SRC/" "$D/treadmill-remote/"
# Datenbank konsistent kopieren, auch wenn der Daemon gerade schreibt
rm -f "$D/treadmill-remote/laufband.db"*
sqlite3 "$SRC/laufband.db" ".backup '$D/treadmill-remote/laufband.db'"
sqlite3 "$D/treadmill-remote/laufband.db" "pragma journal_mode=DELETE;" >/dev/null
rm -f "$D/treadmill-remote/laufband.db-shm" "$D/treadmill-remote/laufband.db-wal"

rsync -a --delete "$HOME/Library/Application Support/Laufband/" "$D/Application Support/Laufband/"
cp "$HOME"/Library/LaunchAgents/de.straubmueller.laufband*.plist "$D/LaunchAgents/"
defaults export de.straubmueller.laufband "$D/Einstellungen/de.straubmueller.laufband.plist"
rm -rf "$D/Laufband.app" && ditto "$HOME/Applications/Laufband.app" "$D/Laufband.app"
echo "Gesichert nach: $D ($(du -sh "$D" | cut -f1))"
