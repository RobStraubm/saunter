#!/usr/bin/env python3
"""
Kommandozeilen-Client fuer den Saunter-Daemon (saunter_daemon.py).

Benutzung:
    python3 live_control.py start [TEMPO]
    python3 live_control.py faster | slower | setspeed TEMPO
    python3 live_control.py pause | resume | stop
    python3 live_control.py status [--watch]
    python3 live_control.py sessions [ANZAHL]
    python3 live_control.py buero nein|ja [JJJJ-MM-TT]   (Streak: nicht im Buero / war im Buero)
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

PHASE_LABELS = {
    "offline": "Nicht verbunden",
    "idle": "Bereit",
    "countdown": "Startet",
    "running": "Läuft",
    "paused": "Pausiert",
    "error": "Fehler am Gerät (Sicherheitsschlüssel?)",
}


def base_url() -> str:
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    return f"http://{cfg['host']}:{cfg['port']}/api/"


def call(method: str, path: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base_url() + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return json.load(e)
    except urllib.error.URLError:
        sys.exit("Daemon nicht erreichbar. Läuft er? -> saunter log")


def fmt_duration(seconds: int) -> str:
    h, rest = divmod(int(seconds), 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def fmt_status(st: dict) -> str:
    phase = st["phase"]
    head = PHASE_LABELS.get(phase, phase)
    if phase == "countdown" and st.get("countdown"):
        head += f" … {st['countdown']}"
    if phase == "running":
        head += f"  {st['speed']:.1f} km/h"
    head += f"  (Ziel {st['target_speed']:.1f} km/h)"
    lines = [head]
    s = st.get("session")
    if s:
        lines.append(
            f"  {fmt_duration(s['active_s'])}  ·  {s['distance_km']:.2f} km  ·  "
            f"{s['kcal']:.0f} kcal  ·  {s['steps']} Schritte"
        )
        if s["paused"]:
            left = max(0, st["auto_finish_after_s"] - (s["paused_for_s"] or 0))
            lines.append(f"  Pause seit {fmt_duration(s['paused_for_s'] or 0)} – endet automatisch in {fmt_duration(left)}")
    elif st.get("last_finished"):
        f = st["last_finished"]
        note = "" if f["logged"] else "  (zu kurz, nicht in Health)"
        lines.append(
            f"  Letztes Training: {fmt_duration(f['duration_s'])} · {f['distance_km']:.2f} km · {f['kcal']} kcal{note}"
        )
    totals, goal = st.get("totals"), st.get("weekly_goal")
    if totals:
        km = lambda v: f"{v:.2f}".replace(".", ",")  # noqa: E731
        lines.append(f"  Heute {km(totals['today']['km'])} km · Woche {km(totals['week']['km'])} km · "
                     f"Gesamt {km(totals['total']['km'])} km ({totals['total']['n']} Trainings)")
        if goal and goal.get("km"):
            pct = totals["week"]["km"] / goal["km"] * 100
            lines.append(f"  Wochenziel {goal['label']}: {km(totals['week']['km'])} von {goal['km']:g} km "
                         f"({pct:.1f} %)".replace(".", ",", 1))
    streak = st.get("streak")
    if streak:
        today = {"done": "heute erledigt", "open": f"heute noch {max(0, streak['required_min'] - streak['today']['minutes']):.0f} min",
                 "excused": "heute nicht im Büro", "optional": "Wochenende"}.get(streak["today"]["state"], "")
        days = "Tag" if streak["current"] == 1 else "Tage"
        lines.append(f"  Wanderstreak {streak['current']} {days} ({today}, Rekord {streak['best']})")
        for d in streak["pending"]:
            lines.append(f"  ? Warst du am {d} im Büro?  ->  saunter buero nein {d}  |  saunter buero ja {d}")
    if st.get("last_error"):
        lines.append(f"  ! {st['last_error']}")
    return "\n".join(lines)


def run_command(action: str, payload: dict | None = None):
    resp = call("POST", action, payload or {})
    if not resp.get("ok"):
        print(f"Fehler: {resp.get('error')}")
    if resp.get("status"):
        print(fmt_status(resp["status"]))
    result = resp.get("result")
    if action == "stop" and result:
        print("\nZusammenfassung:")
        for k, v in result.items():
            print(f"  {k}: {v}")
    sys.exit(0 if resp.get("ok") else 1)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    action, rest = args[0], args[1:]

    if action == "start":
        run_command("start", {"speed": float(rest[0])} if rest else None)
    elif action in ("faster", "slower", "pause", "resume", "stop"):
        run_command(action)
    elif action == "setspeed" and rest:
        run_command("speed", {"value": float(rest[0])})
    elif action == "buero" and rest and rest[0] in ("ja", "nein"):
        payload = {"status": "present" if rest[0] == "ja" else "excused"}
        if len(rest) > 1:
            payload["date"] = rest[1]
        run_command("streak", payload)
    elif action == "status":
        if "--watch" in rest:
            try:
                while True:
                    out = fmt_status(call("GET", "status"))
                    print("\033[2J\033[H" + out, flush=True)
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
        else:
            print(fmt_status(call("GET", "status")))
    elif action == "sessions":
        limit = int(rest[0]) if rest else 10
        for s in call("GET", f"sessions?limit={limit}"):
            start = datetime.fromtimestamp(s["start_ts"]).strftime("%a %d.%m. %H:%M")
            print(f"{start}  {fmt_duration(s['active_s']):>8}  {s['distance_km']:5.2f} km  "
                  f"{s['avg_speed_kmh'] or 0:4.1f} km/h  {s['kcal']:4.0f} kcal  {s['steps']:5d} Schritte")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
