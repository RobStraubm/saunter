#!/bin/zsh
# Richtet die Laufband-Steuerung auf einem (neuen) Mac ein – aus einem Klon dieses Repos
# oder aus der Sicherung im Google-Drive-Ordner „Laufband“ (angelegt mit sichern.sh).
#
#   ./install.sh                                                  (im Repo-Ordner)
#   zsh ".../Meine Ablage/Laufband/treadmill-remote/install.sh"   (aus der Sicherung)
#
# Was passiert:
#   1. Projekt nach ~/laufband kopieren (inkl. laufband.db, falls vorhanden);
#      ohne eigene config.json wird sie aus config.example.json angelegt
#   2. Python-Umgebung neu anlegen (die gesicherte venv passt nur zum alten Mac)
#   3. Laufband per Bluetooth suchen und die Adresse in config.json eintragen
#      (die Bluetooth-Adresse ist auf jedem Mac eine andere)
#   4. Routen, Applaus-Ton und App-Einstellungen (Erfolge) zurückspielen
#   5. Laufband.app bauen (oder die gesicherte App übernehmen)
#   6. Autostart (LaunchAgents), Terminal-Befehl `laufband` und Claude-MCP einrichten
#
# Vorher auf dem ALTEN Mac den Daemon beenden – das Band erlaubt nur eine Verbindung:
#   launchctl bootout gui/$(id -u)/de.straubmueller.laufbanddaemon
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"          # Repo-Ordner bzw. .../Laufband/treadmill-remote
BACKUP="$(dirname "$SRC")"                    # .../Laufband (nur bei Sicherung relevant)
DEST="$HOME/laufband"
UID_=$(id -u)

say() { print -P "\n%B==> $1%b"; }

# ---------------------------------------------------------------- Voraussetzungen
say "Voraussetzungen prüfen"
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Hinweis: Die App ist für Apple-Silicon-Macs gebaut (arm64)."
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools fehlen – Installation wird gestartet. Danach dieses Skript erneut ausführen."
  xcode-select --install || true
  exit 1
fi
PY=""
for c in /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [[ -x "$c" ]] && "$c" -c 'import sys; sys.exit(sys.version_info < (3,11))' 2>/dev/null; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  if command -v brew >/dev/null; then
    brew install python@3.14
    PY=/opt/homebrew/bin/python3.14
  else
    echo "Kein Python ≥ 3.11 gefunden. Homebrew installieren (https://brew.sh), dann: brew install python@3.14"
    exit 1
  fi
fi
echo "Python: $PY ($("$PY" -V))"

# ---------------------------------------------------------------- 1. Projekt kopieren
say "Projekt nach $DEST kopieren"
if [[ "$SRC" != "$DEST" ]]; then
  if [[ -e "$DEST/laufband.db" ]]; then
    echo "Achtung: $DEST existiert schon mit einer laufband.db."
    read -q "?Überschreiben mit der Sicherung? [j/N] " || { echo; exit 1; }
    echo
  fi
  mkdir -p "$DEST"
  rsync -a --exclude venv --exclude .build --exclude __pycache__ --exclude .DS_Store "$SRC/" "$DEST/"
fi
cd "$DEST"
# Ohne eigene config.json (z. B. frischer Klon des Repos): Vorlage kopieren, Streak startet heute
if [[ ! -f config.json ]]; then
  cp config.example.json config.json
  "$PY" - <<'EOF'
import datetime, json
p = "config.json"; c = json.load(open(p, encoding="utf-8")); c["streak_start"] = datetime.date.today().isoformat()
json.dump(c, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
EOF
  echo "config.json aus config.example.json angelegt – Größe, Gewicht und iMessage-Ziel bei Bedarf anpassen."
fi

# ---------------------------------------------------------------- 2. Python-Umgebung
say "Python-Umgebung anlegen"
rm -rf venv
"$PY" -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q -r requirements.txt

# ---------------------------------------------------------------- 3. Laufband suchen
say "Laufband per Bluetooth suchen (Band einschalten, alter Mac getrennt)"
echo "macOS fragt ggf. nach Bluetooth-Zugriff für das Terminal – bitte erlauben."
ADDR=$(./venv/bin/python - <<'EOF'
import asyncio, sys
from bleak import BleakScanner, BleakClient

FITSHOW = ("fff0", "ffe0", "ae00")          # typische FitShow-Services
async def main():
    found = await BleakScanner.discover(timeout=10, return_adv=True)
    cands = []
    for addr, (dev, adv) in found.items():
        name = dev.name or adv.local_name or ""
        uuids = [u.lower()[4:8] for u in adv.service_uuids]
        score = 2 if any(u in FITSHOW for u in uuids) else 0
        if any(k in name.upper() for k in ("FS-", "FITSHOW", "WALK", "PAD", "TREAD", "KS-", "RUN")):
            score += 1
        if name or score:
            cands.append((score, adv.rssi, addr, name or "(ohne Namen)"))
    cands.sort(key=lambda c: (-c[0], -c[1]))
    if not cands:
        print("Keine Geräte gefunden.", file=sys.stderr); return
    if cands[0][0] >= 2 and (len(cands) == 1 or cands[1][0] < 2):
        print(f"Gefunden: {cands[0][3]} ({cands[0][2]})", file=sys.stderr)
        print(cands[0][2]); return
    for i, (s, rssi, addr, name) in enumerate(cands[:20], 1):
        mark = "  ← wahrscheinlich" if s >= 2 else ""
        print(f"{i:2}) {name:30} Signal {rssi:4}  {addr}{mark}", file=sys.stderr)
    sys.stderr.write("Nummer des Laufbands (leer = später eintragen): ")
    sys.stderr.flush()
    choice = open("/dev/tty").readline().strip()
    if choice.isdigit() and 1 <= int(choice) <= len(cands):
        print(cands[int(choice) - 1][2])
asyncio.run(main())
EOF
) || true
if [[ -n "$ADDR" ]]; then
  ./venv/bin/python - "$ADDR" <<'EOF'
import json, sys
p = "config.json"; c = json.load(open(p)); c["address"] = sys.argv[1]
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
EOF
  echo "Adresse $ADDR in config.json eingetragen."
else
  echo "Keine Adresse gewählt – später in $DEST/config.json bei \"address\" eintragen"
  echo "und den Daemon neu starten: launchctl kickstart -k gui/$UID_/de.straubmueller.laufbanddaemon"
fi

# ---------------------------------------------------------------- 4. Daten zurückspielen
say "Routen, Einstellungen und Erfolge zurückspielen"
if [[ -d "$BACKUP/Application Support/Laufband" ]]; then
  mkdir -p "$HOME/Library/Application Support/Laufband"
  rsync -a "$BACKUP/Application Support/Laufband/" "$HOME/Library/Application Support/Laufband/"
fi
if [[ -f "$BACKUP/Einstellungen/de.straubmueller.laufband.plist" ]]; then
  pkill -x Laufband 2>/dev/null || true
  defaults import de.straubmueller.laufband "$BACKUP/Einstellungen/de.straubmueller.laufband.plist"
fi

# ---------------------------------------------------------------- 5. App
say "Laufband.app bauen"
mkdir -p "$HOME/Applications"
if (cd LaufbandMenuBar && ./build_app.sh); then
  :
elif [[ -d "$BACKUP/Laufband.app" ]]; then
  echo "Bauen fehlgeschlagen (Command Line Tools 26 nötig) – nehme die gesicherte App."
  rm -rf "$HOME/Applications/Laufband.app"
  ditto "$BACKUP/Laufband.app" "$HOME/Applications/Laufband.app"
  xattr -dr com.apple.quarantine "$HOME/Applications/Laufband.app" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "$HOME/Applications/Laufband.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Laufband.app"
else
  echo "App konnte nicht gebaut werden und keine gesicherte App gefunden."
fi

# ---------------------------------------------------------------- 6. Autostart
say "Autostart einrichten"
LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA" "$HOME/Library/Logs"
cat > "$LA/de.straubmueller.laufbanddaemon.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>de.straubmueller.laufbanddaemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/venv/bin/python</string>
        <string>$DEST/laufband_daemon.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$DEST</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/laufband_daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/laufband_daemon.log</string>
</dict>
</plist>
EOF
cat > "$LA/de.straubmueller.laufbandmenubar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>de.straubmueller.laufbandmenubar</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HOME/Applications/Laufband.app/Contents/MacOS/Laufband</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/tmp/laufband_menubar.log</string>
	<key>StandardOutPath</key>
	<string>/tmp/laufband_menubar.log</string>
</dict>
</plist>
EOF
for L in de.straubmueller.laufbanddaemon de.straubmueller.laufbandmenubar; do
  launchctl bootout "gui/$UID_/$L" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$LA/$L.plist"
done

# ---------------------------------------------------------------- Terminal + Claude
say "Terminal-Befehl und Claude einrichten"
if ! grep -q 'alias laufband=' "$HOME/.zshrc" 2>/dev/null; then
  echo "alias laufband=\"$DEST/laufband.sh\"" >> "$HOME/.zshrc"
fi
if command -v claude >/dev/null; then
  claude mcp remove -s user laufband >/dev/null 2>&1 || true
  claude mcp add -s user laufband -- "$DEST/venv/bin/python" "$DEST/laufband_mcp.py" && echo "Claude Code: MCP „laufband“ eingetragen"
fi
CD="$HOME/Library/Application Support/Claude"
if [[ -d "$CD" ]]; then
  ./venv/bin/python - "$CD/claude_desktop_config.json" "$DEST" <<'EOF'
import json, os, sys
p, dest = sys.argv[1], sys.argv[2]
c = json.load(open(p)) if os.path.exists(p) else {}
c.setdefault("mcpServers", {})["laufband"] = {
    "command": f"{dest}/venv/bin/python", "args": [f"{dest}/laufband_mcp.py"]}
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
print("Claude Desktop: MCP „laufband“ eingetragen (Claude Desktop neu starten)")
EOF
fi

# ---------------------------------------------------------------- Fertig
say "Fertig"
sleep 5
curl -s --max-time 3 http://127.0.0.1:8765/api/status | head -c 300 || echo "Daemon antwortet noch nicht – Log: tail -f ~/Library/Logs/laufband_daemon.log"
cat <<EOF


Noch von Hand:
  • Optional: eigene Kurzbefehle mit der Aktion „URL öffnen“ (z. B. laufband://toggle) anlegen – siehe README
  • Neues Terminal-Fenster öffnen, dann: laufband status
  • Bluetooth-Freigabe erlauben, falls macOS für Python/Laufband fragt
  • Optional: Apple Intelligence einschalten, Kalender im Analyse-Tab verbinden
  • Den alten Mac nicht wieder mit dem Band verbinden lassen (Daemon dort aus lassen)
EOF
