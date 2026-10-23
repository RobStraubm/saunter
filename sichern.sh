#!/bin/zsh
# Sichert Saunter komplett in den Google-Drive-Ordner „Saunter“.
# Wiederherstellen auf einem neuen Mac: install.sh aus der Sicherung ausführen.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/Library/CloudStorage/$(ls "$HOME/Library/CloudStorage" | grep -m1 '^GoogleDrive-')/Meine Ablage/Saunter"
mkdir -p "$D/Application Support" "$D/LaunchAgents" "$D/Einstellungen"

"$SRC/venv/bin/pip" freeze > "$SRC/requirements.txt"
rsync -a --delete --exclude 'saunter.db*' --exclude .DS_Store "$SRC/" "$D/saunter/"
# Datenbank konsistent kopieren, auch wenn der Daemon gerade schreibt
rm -f "$D/saunter/saunter.db"*
sqlite3 "$SRC/saunter.db" ".backup '$D/saunter/saunter.db'"
sqlite3 "$D/saunter/saunter.db" "pragma journal_mode=DELETE;" >/dev/null
rm -f "$D/saunter/saunter.db-shm" "$D/saunter/saunter.db-wal"

rsync -a --delete "$HOME/Library/Application Support/Saunter/" "$D/Application Support/Saunter/"
cp "$HOME"/Library/LaunchAgents/de.straubmueller.saunter*.plist "$D/LaunchAgents/"
defaults export de.straubmueller.saunter "$D/Einstellungen/de.straubmueller.saunter.plist"
rm -rf "$D/Saunter.app" && ditto "$HOME/Applications/Saunter.app" "$D/Saunter.app"
echo "Gesichert nach: $D ($(du -sh "$D" | cut -f1))"
