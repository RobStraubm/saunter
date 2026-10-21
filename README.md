# Laufband

**English summary** · Deutsche Dokumentation unten

- Control a FitShow-based walking pad (treadmill) from your Mac over Bluetooth LE — a replacement for the vendor app and remote.
- A local Python daemon holds the BLE connection, records sessions in SQLite and serves an HTTP/WebSocket API on 127.0.0.1.
- An MCP server lets Claude read your walking stats and, only on explicit request, control the belt.
- A SwiftUI menu bar app (macOS 26) shows live data, history, goals and a virtual journey; finished workouts can be exported to Apple Health.
- Built with Claude Code.
- **Warning:** this software controls a real device with a moving belt. Use it at your own risk, keep the original remote within reach and never start the belt unattended.
- Data stays local: sessions and config live next to the code (SQLite, `config.json`) and the API listens on 127.0.0.1 only. The only things that leave the Mac are optional Apple services: Maps routing for the virtual journey and an iMessage to yourself for the Health export.
- The FitShow protocol notes are based on the open-source project [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) (GPL-3.0); none of its files are included in this repository.
- License: [GPL-3.0](LICENSE).

---

# Laufband per Bluetooth vom Computer steuern (FitShow-Protokoll)

Ersetzt die FitShow-App/Fernbedienung: Start, Stopp, Pause, Live-Tempo — per
Bluetooth LE direkt vom Mac, mit Live-Daten, Auswertungen und automatischem
Eintrag in Apple Health nach dem Training.

Die Protokoll-Notizen (siehe unten) basieren auf dem Open-Source-Projekt
[qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) (GPL-3.0,
`src/devices/fitshowtreadmill/fitshowtreadmill.cpp`). Dateien aus diesem Projekt
sind nicht Teil dieses Repos; die Schrittlängen-Formel in `walk_session.py` folgt
ebenfalls seinem Ansatz.

Lizenz: [GPL-3.0](LICENSE).

**Sicherheitsgrenze:** Das Gerät meldet selbst 1,0–8,0 km/h; der Daemon liest
diese Grenzen beim Verbinden aus und klemmt alle Tempi darauf. Nach jedem
beendeten Training steht das Zieltempo wieder auf `default_speed` (2,0 km/h),
der nächste Start beginnt also nie mit einem hohen Tempo von neulich.

## Aufbau

```
 Laufband ◄─BLE─► laufband_daemon.py ◄─HTTP/WebSocket (127.0.0.1:8765)─┬─ Laufband.app (Menüleiste, Übersicht,
                  (hält die Verbindung,                                │   Rückblick, Widget, Tastenkürzel)
                   fragt 2×/s den Status ab,                           ├─ laufband (Terminal)
                   Sessions → laufband.db)                             ├─ laufband_mcp.py (Claude)
                                                                       └─ laufband://-Links (Kurzbefehle,
                                                                           Kontrollzentrum, Spotlight, Siri)
```

| Datei | Zweck |
|---|---|
| `laufband_daemon.py` | Hintergrunddienst: dauerhafte BLE-Verbindung, Live-Telemetrie, Sessions in SQLite, HTTP-API, Health-Export |
| `config.example.json` → `config.json` | Geräte-Adresse, Größe/Gewicht (Schritte, kcal), Standardtempo, Tagesziel, Auto-Ende nach Pause. `config.json` ist persönlich und nicht im Repo (`install.sh` legt sie aus der Vorlage an) |
| `live_control.py` + `laufband.sh` | Terminal-Client (`laufband …`) |
| `LaufbandMenuBar/` | SwiftUI-App (macOS 26, Liquid Glass): Menüleiste, Übersicht, Rückblick, Widget → `~/Applications/Laufband.app` |
| `laufband_mcp.py` | MCP-Server: Claude liest Trainings/Statistiken und steuert auf Wunsch das Band |
| `walk_session.py` | Gemeinsame Bausteine: FitShow-Pakete, Status-Parser, Schritt-Schätzung, Health-Export |
| `probe_status.py` | Diagnose: fragt nur den Status ab (`--run`: 20 s bei 1 km/h); Adresse aus `config.json` |
| `laufband.db` | Alle Trainings + Tempo-Verlauf je Sekunde (entsteht lokal beim ersten Start, nicht im Repo; eine alte `workouts.csv` wird einmalig übernommen) |

## Installation, Sichern und Umzug auf einen neuen Mac

**Neu installieren:** Laufband einschalten, Repo klonen und im Repo-Ordner
`./install.sh` ausführen. Das Skript legt aus `config.example.json` eine eigene
`config.json` an (falls noch keine existiert), kopiert das Projekt nach
`~/laufband`, sucht das Band per Bluetooth (die BLE-Adresse ist pro Mac
verschieden), legt die venv aus `requirements.txt` an, baut die App und richtet
Autostart, `laufband`-Befehl und Claude-MCP ein. Danach in `config.json` Größe
und Gewicht (Schritte, kcal) und optional `imessage_target` (Health-Export)
anpassen.

**Sichern / Umzug:** `./sichern.sh` kopiert alles (Code, `laufband.db`, Routen,
Erfolge, App, LaunchAgents) nach Google Drive → „Meine Ablage/Laufband“ (Pfad im
Skript anpassen, falls du etwas anderes nutzt). Auf dem neuen Mac: Daemon auf dem
alten Mac beenden (siehe unten), Laufband einschalten, dann `install.sh` aus dem
Sicherungsordner ausführen
(`zsh ".../Meine Ablage/Laufband/treadmill-remote/install.sh"`).

## Setup

Von Hand (ohne `install.sh`), im Projektordner (z. B. `~/laufband`):

```bash
cp config.example.json config.json   # dann Adresse, Größe, Gewicht eintragen
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

`install.sh` richtet beide Teile als LaunchAgent ein; sie starten bei jedem Login automatisch:
`~/Library/LaunchAgents/de.straubmueller.laufbanddaemon.plist` und
`~/Library/LaunchAgents/de.straubmueller.laufbandmenubar.plist`.

```bash
# nach Änderungen am Daemon
launchctl kickstart -k gui/$(id -u)/de.straubmueller.laufbanddaemon
# nach Änderungen an der App (baut ~/Applications/Laufband.app neu und startet sie)
cd LaufbandMenuBar && ./build_app.sh --restart
```

Die App braucht die Command Line Tools 26 (macOS-26-SDK: Liquid Glass, 3D-Charts,
Foundation Models). Das App-Bundle ist ad hoc signiert; nach einem Neubau fragt
macOS ggf. erneut nach der Kalender-Freigabe.

**Wichtig:** Das Laufband erlaubt nur *eine* BLE-Verbindung. Solange der Daemon
verbunden ist, kann sich die FitShow-App nicht verbinden (und umgekehrt).
Zum Freigeben: `launchctl bootout gui/$(id -u)/de.straubmueller.laufbanddaemon`.

## Benutzung

### Menüleiste

Symbol oben rechts; während des Laufens steht dort z. B. `4,5 · 12:34`.
Im Panel: Live-Zeit/km/kcal/Schritte, Start/Pause/Weiter/Stopp und der
Tempo-Regler:

- Zeiger auf das Tempo-Feld und scrollen — der Wert folgt flüssig.
- **Trackpad/Magic Mouse:** gesendet wird, wenn du die Finger hebst
  (schnell aufeinanderfolgende Wischer werden zu einem Befehl).
- **Klassisches Mausrad:** 0,1 km/h pro Raste, gesendet nach 0,6 s Ruhe.
- `+`/`−` für 0,5-km/h-Schritte.

### Tastenkürzel (überall, auch wenn das Panel zu ist)

| Kürzel | Aktion |
|---|---|
| ⌃⌥⌘ Leertaste | Start / Pause / Weiter |
| ⌃⌥⌘ ↑ / ↓ | Zieltempo ±0,5 km/h (mehrfach drücken = ein Befehl) |
| ⌃⌥⌘ E | Training beenden (mit Health-Eintrag) |
| ⌃⌥⌘ U | Übersicht öffnen |

Oben am Bildschirm erscheint jeweils kurz eine Einblendung (Tempo, Pause …).
⌃⌥ allein ist bewusst nicht belegt — das nutzt Rectangle. Die Liste steht auch
im Panel unter „Tastenkürzel & Automatik".

### Automatik bei Sperre/Ruhezustand

Wird der Mac gesperrt oder geht in den Ruhezustand, pausiert das Band
(Einstellung im Panel, standardmäßig an). Beim Entsperren läuft es *nicht*
automatisch weiter — das lässt sich im Panel einschalten, startet das Band dann
aber ohne Rückfrage. App-Log: `/tmp/laufband_menubar.log`.

### Übersicht (⌃⌥⌘ U, Button im Panel oder `laufband übersicht`)

Liquid-Glass-Kopfleiste mit Tabs, Zeitraum (7 Tage – Gesamt), **2D/3D-Umschalter**
und **Rückblick**. Überall Tooltips beim Überfahren.

- **Übersicht:** Heute / Diese Woche / Insgesamt + **Wochenziel** (Standard: 1×
  Bodensee-Runde = 260 km, über „Ziel" änderbar; zeigt nötige km pro Tag und wie
  weit du diese Woche um den See gekommen wärst), Distanz mit Vergleich zum
  Vorzeitraum, Tagesziel (Schritte), Kennzahlen, **Einschätzung** (Regeln + mit
  Apple Intelligence eine KI-Zusammenfassung direkt auf dem Mac), Reise-Teaser,
  Distanz pro Tag/Woche, Tempo-Verlauf (live), Bestwerte.
- **Analyse:** Jahreskalender (12 Monate), Tempozonen je Training, Prognose mit
  80-%-Unsicherheitsband, „Wann du läufst" (in 3D als Aktivitätslandschaft),
  Tempo-Entwicklung, Gehen & Termine (Kalender, nur nach Freigabe, lokal).
- **Reise:** Virtuelle Route auf der Satellitenkarte mit 3D-Relief – Bodensee-Runde
  ab Konstanz (260 km), Tegernsee (20 km), Alpenüberquerung E5 (120 km),
  Jakobsweg (780 km). Wahlweise mit allen bisherigen km oder ab heute.
- **Trainings:** Liste aller Trainings, Klick zeigt den Tempo-Verlauf.
- **3D** (Umschalter): Aktivitätslandschaft und Tempo-Gebirge; zum Drehen ziehen.

**Rückblick:** Wochen-/Monatsrückblick im Story-Format (Klick/Pfeiltasten),
Abschlusskarte als Bild (1080 × 1920) nach `~/Downloads` + Teilen.

**Schreibtisch-Widget:** Glaskarte auf dem Schreibtisch mit Kartenvorschau
(wo du auf deiner Reise gerade wärst), Wochenziel, Heute/Woche/Gesamt, Streak
und Live-Tempo (im Panel ein-/ausschaltbar, verschiebbar, Klick öffnet die Übersicht).

### Reise auf echten Wegen

Die Routen (Standard: **Bodensee-Runde ab Konstanz**) werden einmalig mit Apple
Karten als **Fußweg** berechnet (`~/Library/Application Support/Laufband/Routen/`)
– kein Laufen über den See. Die Bodensee-Runde misst so ~204 km. Abschnitte ohne
brauchbaren Fußweg (riesiger Umweg, z. B. Alpenpässe) bleiben gerade; das Panel
zeigt, wie viele Abschnitte echte Wege sind. Zum Neuberechnen die JSON-Datei löschen.

### Wochenziel

Standard „1× Bodensee-Runde" (echte Länge), im Übersichts-Tab über „Ziel"
änderbar (½, ¼, 50 km, 25 km, eigener Wert). Gespeichert in `config.json`
(`weekly_goal_km`, `weekly_goal_label`). Angezeigt in Übersicht, Panel, Widget,
Terminal und für Claude – inklusive „nötig pro Tag" und wie weit du diese Woche
um den See gekommen wärst.

### Wanderstreak (wie bei Duolingo)

Jeden **Werktag mindestens 5 Minuten** laufen (`streak_min_minutes`). Wochenenden
zählen als Bonus, brechen den Streak aber nicht. Hast du an einem Werktag nicht
gelaufen, **fragt die App, ob du im Büro warst**: „Nicht im Büro" → der Tag zählt
nicht gegen den Streak, „War im Büro" → der Streak reißt. Bis zur Antwort bleibt
der Streak stehen. Fragen kommen im Panel, in der Übersicht und als Glas-Banner
oben rechts mit Antwort-Knöpfen; um 17 Uhr erinnert ein Banner, falls der Tag noch
offen ist („Jetzt starten" / „Heute nicht im Büro"). Echte macOS-Mitteilungen
erlaubt das System nur signierten Apps, daher die Banner. In der Wochenleiste jeden
Tag per Rechtsklick nachträglich markieren. Terminal: `laufband buero nein [JJJJ-MM-TT]`.

### Erfolge

~40 Erfolge in „Erfolge" (Kilometer bis 1.000 km, Schritte bis zur Million,
Tagesleistungen, lange/schnelle Trainings, Streak-Stufen, Wochenziel,
Frühaufsteher/Nachteule, Bodensee-Etappen von Kreuzlingen bis „Einmal rum!").
Beim Erreichen – auch mitten im Training – gibt es Konfetti, eine Glas-Karte
und Applaus (synthetisch erzeugt; im Panel abschaltbar). „Feier testen" im Tab
zeigt, wie es aussieht.

### Kurzbefehle, Kontrollzentrum, Spotlight, Siri

Die signierten Kurzbefehle der Originalinstallation liegen nicht in diesem Repo.
Lege in der Kurzbefehle-App eigene an (Aktion „URL öffnen“ mit einem der
`laufband://`-Links unten, Name z. B. „Laufband schneller“). Danach:
Kontrollzentrum → „Steuerelemente bearbeiten" → Kurzbefehle, oder in Spotlight
„Laufband …" tippen, oder „Hey Siri, Laufband schneller". Die
`laufband://`-Links lassen sich auch direkt nutzen (z. B. in Raycast):

```
laufband://toggle  start?tempo=3,5  pause  weiter  beenden
laufband://schneller  langsamer  tempo?wert=4,5
laufband://uebersicht  rueckblick  reise
```

### Claude als Laufband-Assistent (MCP)

In Claude Code (und nach Neustart in Claude Desktop) ist der Server `laufband`
eingetragen. Beispiele: „Wie war meine Woche auf dem Laufband?", „Schaffe ich
mein Wochenziel noch?", „Ich war heute nicht im Büro", „Stell das Band auf
4 km/h". Steuerbefehle nur auf deinen ausdrücklichen Wunsch; Claude Code fragt
vor jedem Aufruf nach.

### Terminal

```bash
laufband start 3.0        # Start (ohne Zahl: aktuelles Zieltempo)
laufband faster | slower  # ±0,5 km/h
laufband setspeed 4.5
laufband pause | resume   # Pause ohne Health-Eintrag
laufband stop             # beendet das Training + Health-Eintrag
laufband status --watch   # Live-Werte
laufband sessions 10      # letzte Trainings
laufband log              # Daemon-Log
laufband übersicht        # Übersichts-Fenster öffnen
```

### HTTP-API (für Kurzbefehle, Raycast, Stream Deck …)

```
GET  http://127.0.0.1:8765/api/status   (inkl. totals heute/woche/gesamt, weekly_goal)
GET  /api/sessions?limit=20    GET /api/sessions/<id>/samples    GET /api/zones
POST /api/start {"speed": 3}   /api/stop  /api/pause  /api/resume
POST /api/faster  /api/slower  /api/speed {"value": 4.5}
POST /api/settings {"weekly_goal_km": 65, "weekly_goal_label": "¼ Bodensee-Runde"}
POST /api/streak {"date": "2026-09-29", "status": "excused"}   (excused | present | clear)
GET  /ws                       (WebSocket, pusht jeden neuen Zustand)
```

Anfragen mit fremdem `Origin`-Header werden abgewiesen, damit keine Webseite im
Browser das Band starten kann.

## Trainings, Pausen, Apple Health

- Ein Training beginnt, sobald das Band läuft — auch wenn es per Fernbedienung
  gestartet wurde. Tempoänderungen an der Fernbedienung werden übernommen.
- Band steht (Pause, Sicherheitsschlüssel, Stopp am Gerät) → Training pausiert;
  nach `auto_finish_pause_s` (10 min) wird es automatisch beendet.
- Dauer = echte Laufzeit laut Band, Distanz = gemessenes Tempo × Zeit, aktive
  kcal nach ACSM-Gehformel mit deinem Gewicht, Schritte über die Schrittlänge
  (Größe × 0,415). Trainings unter `min_session_s` (60 s) werden verworfen.

Beim Beenden: Eintrag in `workouts.csv`, Erinnerung in der iCloud-Liste
**„Laufband"** (mit `shortcuts://`-Link als Fallback) und **iMessage an dich
selbst** (`LAUFBAND: {...json...}`), die per Kurzbefehle-Automation auf dem
iPhone automatisch einen Eintrag in Health → Training anlegt.

### Einmalige Einrichtung auf dem iPhone

**1. Kurzbefehl `LaufbandWorkout`:**
- Kurzbefehle-App → „+" → Name exakt `LaufbandWorkout`
- Aktion „Wörterbuch aus Eingabe abrufen" (Eingabe = Kurzbefehl-Eingabe)
- Aktion „Training aufzeichnen" — Felder als Variable aus dem Wörterbuch:
  Startdatum ← `date`, Dauer ← `duration_s` (Sekunden),
  Distanz ← `distance_km` (Kilometer), Aktive Energie ← `kcal`

**2. Automation:**
- Kurzbefehle → „Automation" → „+" → Auslöser „Nachricht"
- „Wird empfangen von": deine eigene Nummer (dieselbe wie `imessage_target` in `config.json`)
- Filter „Nachricht enthält" → `LAUFBAND:`
- „Vor Ausführung fragen" deaktivieren
- Aktionen: „Text ersetzen" (`LAUFBAND: ` → leer) → „Kurzbefehl ausführen" →
  `LaufbandWorkout` mit dem Ergebnis als Eingabe

Die Ziel-Nummer steht lokal in `config.json` als `imessage_target`, das Präfix
in `walk_session.py` als `TRIGGER_PREFIX`.

## Protokoll-Notizen

- Characteristics: schreiben `fff2`, Antworten `fff1` (Kandidaten `ae01`/`ffe1`/
  `fff2` bzw. `ae02`/`ffe4`/`fff1` werden automatisch gesucht).
- Live-Daten kommen nur auf Anfrage: `SYS_STATUS` (0x51) senden → Antwort mit
  Status (Bereit/Countdown/Läuft/Stopp/Fehler), Tempo, Zeit, Distanz, kcal,
  Schritte, Puls. Dieses Band liefert Tempo und Zeit zuverlässig; Schritte und
  Puls kamen in den Tests als 0 (daher Berechnung auf dem Mac).
- `FITSHOW_CONTROL_PAUSE` (6) wird ignoriert und Tempo 0 auch — Pause ist
  deshalb ein echter Stopp-Befehl, „Weiter" schickt wieder die Startsequenz.
