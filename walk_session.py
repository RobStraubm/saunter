#!/usr/bin/env python3
"""
Gemeinsame Bausteine: FitShow-Protokoll (Pakete, Characteristics, Status-
Parser), Schritt-Schaetzung und Health-Export (CSV, Erinnerung, iMessage-
Trigger fuer die Kurzbefehle-Automation, siehe README.md).
"""
import csv
import json
import os
import subprocess
import tempfile
import urllib.parse
from datetime import datetime

from bleak import BleakClient

WRITE_CHAR_CANDIDATES = {0xAE01, 0xFFE1, 0xFFF2}
NOTIFY_CHAR_CANDIDATES = {0xAE02, 0xFFE4, 0xFFF1}

PKT_HEADER = 0x02
PKT_FOOTER = 0x03
SYS_CONTROL = 83
SYS_INFO = 0x50
SYS_STATUS = 81
CONTROL_READY_OR_START = 1
CONTROL_TARGET_OR_RUN = 2
CONTROL_STOP = 3
CONTROL_PAUSE = 6
CONTROL_USER = 0
INFO_MODEL = 0
INFO_DATE = 1
INFO_SPEED = 2
INFO_INCLINE = 3
INFO_TOTAL = 4

CSV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workouts.csv")
REMINDER_LIST = "Saunter"
SHORTCUT_NAME = "SaunterWorkout"
# Zielnummer fuer den Health-Export steht lokal in config.json ("imessage_target"),
# nicht im Code. Ohne Eintrag wird keine iMessage verschickt.
def _imessage_target() -> str:
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")) as f:
            return str(json.load(f).get("imessage_target", ""))
    except (OSError, ValueError):
        return ""


TRIGGER_PREFIX = "SAUNTER: "


def build_packet(payload: bytes) -> bytes:
    checksum = 0
    for b in payload:
        checksum ^= b
    return bytes([PKT_HEADER]) + payload + bytes([checksum, PKT_FOOTER])


def short_uuid(uuid_str: str):
    try:
        return int(uuid_str.split("-")[0], 16)
    except ValueError:
        return None


FITSHOW_SERVICES = ("fff0", "ffe0", "ae00")
FITSHOW_NAME_HINTS = ("FS-", "FITSHOW", "WALK", "PAD", "TREAD", "KS-", "RUN")


async def scan_treadmills(timeout: float = 8.0) -> list[dict]:
    """Bluetooth-Geraete in der Naehe, wahrscheinliche Laufbaender zuerst."""
    from bleak import BleakScanner
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    devices = []
    for addr, (dev, adv) in found.items():
        name = dev.name or adv.local_name or ""
        uuids = [u.lower()[4:8] for u in adv.service_uuids]
        score = 2 if any(u in FITSHOW_SERVICES for u in uuids) else 0
        if any(k in name.upper() for k in FITSHOW_NAME_HINTS):
            score += 1
        if name or score:
            devices.append({"address": addr, "name": name or "(ohne Namen)", "rssi": adv.rssi,
                            "likely": score >= 2, "score": score})
    devices.sort(key=lambda d: (-d["score"], -d["rssi"]))
    return devices[:20]


def find_characteristics(client: BleakClient):
    write_char = notify_char = None
    for service in client.services:
        for char in service.characteristics:
            short = short_uuid(char.uuid)
            if short in WRITE_CHAR_CANDIDATES:
                write_char = char
            elif short in NOTIFY_CHAR_CANDIDATES:
                notify_char = char
    return write_char, notify_char


def parse_status_packet(full_array: bytes):
    """FITSHOW_SYS_STATUS (cmd=81) Telemetrie-Paket parsen. None wenn kein
    Telemetrie-Paket bzw. zu kurz."""
    if len(full_array) < 16 or full_array[1] != SYS_STATUS:
        return None
    par = full_array[2]
    speed = full_array[3] / 10.0
    incline_raw = full_array[4]
    incline = incline_raw - 256 if incline_raw > 127 else incline_raw
    seconds_elapsed = full_array[5] | (full_array[6] << 8)
    distance = (full_array[7] | (full_array[8] << 8)) / 10.0
    kcal = full_array[9] | (full_array[10] << 8)
    step_count = full_array[11] | (full_array[12] << 8)
    heart = full_array[13]
    return {
        "par": par,
        "speed": speed,
        "incline": incline,
        "seconds_elapsed": seconds_elapsed,
        "distance_km": distance,
        "kcal": kcal,
        "step_count": step_count,
        "heart": heart,
    }


def log_workout_csv(summary: dict):
    fieldnames = ["date", "duration_s", "distance_km", "steps", "kcal", "avg_speed_kmh"]
    file_exists = os.path.exists(CSV_PATH)
    with open(CSV_PATH, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        if not file_exists:
            writer.writeheader()
        writer.writerow(summary)


def send_trigger_message(summary: dict):
    """Schickt eine iMessage an das eigene iPhone. Eine Kurzbefehle-Automation
    mit 'Nachricht empfangen'-Ausloeser fischt das Praefix raus und loggt den
    Workout automatisch in Apple Health, ganz ohne Tippen."""
    target = _imessage_target()
    if not target:
        return
    payload = json.dumps(summary, ensure_ascii=False)
    message_text = f"{TRIGGER_PREFIX}{payload}"

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    script = f'''
tell application "Messages"
    set targetService to 1st service whose service type = iMessage
    set targetBuddy to buddy "{esc(target)}" of targetService
    send "{esc(message_text)}" to targetBuddy
end tell
'''
    with tempfile.NamedTemporaryFile("w", suffix=".applescript", delete=False) as f:
        f.write(script)
        path = f.name
    try:
        subprocess.run(["osascript", path], check=True)
    finally:
        os.unlink(path)


def build_shortcut_link(summary: dict) -> str:
    """shortcuts://-Link, der den Kurzbefehl 'SaunterWorkout' mit den
    Workout-Daten als Text-Input startet (offizielles URL-Schema von Apple)."""
    payload = json.dumps(summary, ensure_ascii=False)
    query = urllib.parse.urlencode({"name": SHORTCUT_NAME, "input": "text", "text": payload})
    return f"shortcuts://run-shortcut?{query}"


def create_health_reminder(summary: dict):
    minutes, seconds = divmod(summary["duration_s"], 60)
    dt = datetime.fromisoformat(summary["date"])
    title = f"Laufband-Workout {dt.strftime('%Y-%m-%d %H:%M')} ({minutes}:{seconds:02d} min)"
    link = build_shortcut_link(summary)
    body = (
        f"{summary['distance_km']} km, {summary['steps']} Schritte, "
        f"{summary['kcal']} kcal, {summary['avg_speed_kmh']} km/h\n\n"
        f"Zum Eintragen in Apple Health antippen:\n{link}"
    )

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    # AppleScript-Stringliterale duerfen keine rohen Zeilenumbrueche enthalten,
    # daher zeilenweise mit "return" verketten statt \n einzubetten.
    body_as_applescript = " & return & ".join(f'"{esc(line)}"' for line in body.split("\n"))

    script = f'''
tell application "Reminders"
    if not (exists list "{esc(REMINDER_LIST)}") then
        make new list with properties {{name:"{esc(REMINDER_LIST)}"}}
    end if
    tell list "{esc(REMINDER_LIST)}"
        make new reminder with properties {{name:"{esc(title)}", body:{body_as_applescript}}}
    end tell
end tell
'''
    with tempfile.NamedTemporaryFile("w", suffix=".applescript", delete=False) as f:
        f.write(script)
        path = f.name
    try:
        subprocess.run(["osascript", path], check=True)
    finally:
        os.unlink(path)


def estimate_steps(distance_km: float, height_cm: float, sex: str) -> int:
    """Schrittlaenge = Koerpergroesse x 0.415 (m) / x 0.413 (w), wie in
    qdomyos-zwift treadmill.cpp calculateCadenceFromSpeed()."""
    factor = 0.415 if sex.lower().startswith("m") else 0.413
    stride_m = (height_cm / 100.0) * factor
    if stride_m <= 0:
        return 0
    return round((distance_km * 1000.0) / stride_m)
