#!/usr/bin/env python3
"""
MCP-Server "laufband": gibt Claude Zugriff auf Live-Status, Trainings und
Auswertungen des Laufbands und erlaubt das Steuern ueber den Daemon
(laufband_daemon.py, http://127.0.0.1:8765). Start (stdio):

    venv/bin/python laufband_mcp.py
"""
import json
import os
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Literal

import aiohttp
from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(BASE_DIR, "config.json")) as f:
    CONFIG = json.load(f)
API = f"http://{CONFIG['host']}:{CONFIG['port']}/api"

server = MCPServer(
    name="laufband",
    title="Laufband",
    instructions=(
        "Zugriff auf das Walking-Pad des Nutzers (FitShow, 1–8 km/h) ueber einen lokalen Daemon. "
        "Fuer Fragen zu Trainings, Fortschritt und Gewohnheiten die Lese-Werkzeuge nutzen und auf Deutsch, "
        "knapp und konkret antworten (km mit Komma, z. B. 2,4 km). "
        "laufband_steuern bewegt ein echtes Geraet: nur aufrufen, wenn der Nutzer es ausdruecklich verlangt."
    ),
)

READ_ONLY = ToolAnnotations(read_only_hint=True, destructive_hint=False, idempotent_hint=True, open_world_hint=False)
CONTROL = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False, open_world_hint=True)


TIMEOUT = aiohttp.ClientTimeout(total=5)


async def _get(path: str):
    async with aiohttp.ClientSession(timeout=TIMEOUT) as client:
        async with client.get(f"{API}{path}") as resp:
            resp.raise_for_status()
            return await resp.json()


async def _post(path: str, payload: dict | None = None):
    async with aiohttp.ClientSession(timeout=TIMEOUT) as client:
        async with client.post(f"{API}{path}", json=payload or {}) as resp:
            return await resp.json()


def _fmt_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{int(round(seconds))} s"
    m = int(round(seconds / 60))
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def _session_row(s: dict) -> dict:
    start = datetime.fromtimestamp(s["start_ts"])
    active = s["active_s"]
    avg = s.get("avg_speed_kmh") or (s["distance_km"] / (active / 3600) if active else 0)
    return {
        "id": s["id"],
        "start": start.isoformat(timespec="minutes"),
        "wochentag": ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][start.weekday()],
        "dauer": _fmt_duration(active),
        "dauer_s": int(active),
        "distanz_km": round(s["distance_km"], 2),
        "tempo_schnitt_kmh": round(avg, 1),
        # alte, aus der CSV uebernommene Trainings kennen kein Maximaltempo
        "tempo_max_kmh": s.get("max_speed_kmh") if s.get("has_samples") else None,
        "kcal_aktiv": round(s["kcal"]),
        "schritte": s["steps"],
        "tempo_verlauf_vorhanden": bool(s.get("has_samples")),
    }


async def _all_sessions() -> list[dict]:
    sessions = await _get("/sessions?limit=100000")
    status = await _get("/status")
    live = status.get("session")
    if live:
        sessions.append({
            "id": live["id"], "start_ts": live["start_ts"], "active_s": live["active_s"],
            "distance_km": live["distance_km"], "kcal": live["kcal"], "steps": live["steps"],
            "max_speed_kmh": live["max_speed"], "avg_speed_kmh": None, "has_samples": 1, "live": True,
        })
    return sessions


def _totals(sessions: list[dict]) -> dict:
    km = sum(s["distance_km"] for s in sessions)
    secs = sum(s["active_s"] for s in sessions)
    return {
        "trainings": len(sessions),
        "distanz_km": round(km, 2),
        "aktive_zeit": _fmt_duration(secs),
        "aktive_zeit_s": int(secs),
        "schritte": sum(s["steps"] for s in sessions),
        "kcal_aktiv": round(sum(s["kcal"] for s in sessions)),
        "tempo_schnitt_kmh": round(km / (secs / 3600), 2) if secs else 0,
    }


def _bucket_key(d: date, gruppierung: str) -> str:
    if gruppierung == "tag":
        return d.isoformat()
    if gruppierung == "woche":
        iso = d.isocalendar()
        return f"{iso.year}-KW{iso.week:02d}"
    return f"{d.year}-{d.month:02d}"


def _streaks(sessions: list[dict]) -> dict:
    days = {datetime.fromtimestamp(s["start_ts"]).date() for s in sessions}
    best = 0
    for d in days:
        if d - timedelta(days=1) not in days:
            length, cur = 1, d + timedelta(days=1)
            while cur in days:
                length, cur = length + 1, cur + timedelta(days=1)
            best = max(best, length)
    cur = date.today()
    if cur not in days:
        cur -= timedelta(days=1)
    current = 0
    while cur in days:
        current, cur = current + 1, cur - timedelta(days=1)
    return {"aktuelle_serie_tage": current, "laengste_serie_tage": best}


@server.tool(annotations=READ_ONLY)
async def laufband_status() -> dict:
    """Aktueller Zustand: verbunden?, Phase (idle/countdown/running/paused/offline), Ist- und Zieltempo,
    laufendes Training (Zeit, km, kcal, Schritte) sowie die Summe von heute inkl. Tagesziel."""
    status = await _get("/status")
    sessions = await _all_sessions()
    today = [s for s in sessions if datetime.fromtimestamp(s["start_ts"]).date() == date.today()]
    heute = _totals(today)
    goal = status.get("daily_step_goal") or 10000
    heute["tagesziel_schritte"] = goal
    heute["tagesziel_erreicht_prozent"] = round(100 * heute["schritte"] / goal) if goal else None
    result = {
        "phase": status["phase"],
        "verbunden": status["connected"],
        "tempo_ist_kmh": status["speed"],
        "tempo_ziel_kmh": status["target_speed"],
        "tempo_bereich_kmh": [status["min_speed"], status["max_speed"]],
        "laufendes_training": status["session"],
        "letztes_training": status["last_finished"],
        "heute": heute,
        "fehler": status["last_error"],
    }
    totals, goal = status.get("totals"), status.get("weekly_goal")
    if totals:
        result["diese_woche_km"] = round(totals["week"]["km"], 2)
        result["insgesamt_km"] = round(totals["total"]["km"], 2)
        result["insgesamt_trainings"] = totals["total"]["n"]
        if goal:
            done = totals["week"]["km"]
            days_left = 7 - date.today().weekday()
            result["wochenziel"] = {
                "ziel": goal["label"],
                "ziel_km": goal["km"],
                "geschafft_km": round(done, 2),
                "geschafft_prozent": round(100 * done / goal["km"], 1) if goal["km"] else None,
                "noetig_pro_tag_km": round(max(0, goal["km"] - done) / days_left, 1),
            }
    streak = status.get("streak")
    if streak:
        result["wanderstreak"] = {
            "tage": streak["current"],
            "rekord": streak["best"],
            "regel": f"jeden Werktag mind. {streak['required_min']:g} min (Wochenende und 'nicht im Buero' zaehlen nicht dagegen)",
            "heute": streak["today"],
            "offene_fragen_im_buero": streak["pending"],
        }
    return result


@server.tool(annotations=CONTROL)
async def laufband_buero_tag(im_buero: bool, datum: str | None = None) -> dict:
    """Beantwortet die Streak-Frage fuer einen Werktag (Standard: heute): im_buero=False markiert den Tag
    als 'nicht im Buero' (zaehlt nicht gegen den Wanderstreak), True bestaetigt die Anwesenheit.
    datum im Format JJJJ-MM-TT. Nur auf Wunsch des Nutzers."""
    payload = {"status": "present" if im_buero else "excused"}
    if datum:
        payload["date"] = datum
    resp = await _post("/streak", payload)
    streak = (resp.get("status") or {}).get("streak") or {}
    return {"ok": resp.get("ok", False), "fehler": resp.get("error"), "streak_tage": streak.get("current"),
            "offene_fragen": streak.get("pending")}


@server.tool(annotations=READ_ONLY)
async def laufband_trainings(tage: int = 30, anzahl: int = 50) -> dict:
    """Einzelne Trainings der letzten `tage` Tage (neueste zuerst, hoechstens `anzahl`): Start, Dauer,
    Distanz, Schnitt-/Maximaltempo, aktive kcal, Schritte, ob ein Tempo-Verlauf existiert."""
    since = datetime.now() - timedelta(days=tage)
    sessions = [s for s in await _all_sessions() if datetime.fromtimestamp(s["start_ts"]) >= since]
    sessions.sort(key=lambda s: s["start_ts"], reverse=True)
    return {"zeitraum_tage": tage, "trainings": [_session_row(s) for s in sessions[:anzahl]]}


@server.tool(annotations=READ_ONLY)
async def laufband_statistik(
    tage: int = 30,
    gruppierung: Literal["tag", "woche", "monat"] = "woche",
) -> dict:
    """Auswertung ueber die letzten `tage` Tage (0 = gesamte Historie): Summen, Vergleich mit dem gleich
    langen Zeitraum davor, Aufschluesselung nach Tag/Woche/Monat, Lieblings-Wochentag und -Uhrzeit,
    Serien und Bestwerte."""
    sessions = await _all_sessions()
    now = datetime.now()
    if tage > 0:
        start = now - timedelta(days=tage)
        current = [s for s in sessions if datetime.fromtimestamp(s["start_ts"]) >= start]
        previous = [s for s in sessions if start - timedelta(days=tage) <= datetime.fromtimestamp(s["start_ts"]) < start]
    else:
        current, previous = sessions, None

    buckets: dict[str, list] = defaultdict(list)
    weekday_min: dict[str, float] = defaultdict(float)
    hour_min: dict[int, float] = defaultdict(float)
    for s in current:
        st = datetime.fromtimestamp(s["start_ts"])
        buckets[_bucket_key(st.date(), gruppierung)].append(s)
        weekday_min[["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][st.weekday()]] += s["active_s"] / 60
        hour_min[st.hour] += s["active_s"] / 60

    records = {}
    if sessions:
        far = max(sessions, key=lambda s: s["distance_km"])
        long = max(sessions, key=lambda s: s["active_s"])
        records = {
            "weiteste_strecke": _session_row(far),
            "laengstes_training": _session_row(long),
        }

    result = {
        "zeitraum": f"letzte {tage} Tage" if tage > 0 else "gesamt",
        "summe": _totals(current),
        "aufschluesselung": {k: _totals(v) for k, v in sorted(buckets.items())},
        "minuten_je_wochentag": {k: round(v) for k, v in weekday_min.items()},
        "minuten_je_startstunde": {f"{h}:00": round(v) for h, v in sorted(hour_min.items())},
        "serien": _streaks(sessions),
        "bestwerte_gesamt": records,
    }
    if previous is not None:
        prev = _totals(previous)
        cur = result["summe"]
        result["vorzeitraum"] = prev
        result["veraenderung"] = {
            "distanz_km": round(cur["distanz_km"] - prev["distanz_km"], 2),
            "aktive_zeit_min": round((cur["aktive_zeit_s"] - prev["aktive_zeit_s"]) / 60),
            "trainings": cur["trainings"] - prev["trainings"],
        }
    return result


@server.tool(annotations=READ_ONLY)
async def laufband_tempo_verlauf(training_id: int | None = None) -> dict:
    """Tempo-Verlauf eines Trainings (Standard: laufendes, sonst letztes mit Sekundenwerten) als Liste der
    Tempowechsel [Minute, km/h] plus Zeit je Tempobereich."""
    if training_id is None:
        status = await _get("/status")
        if status.get("session"):
            training_id = status["session"]["id"]
        else:
            with_samples = [s for s in await _get("/sessions?limit=200") if s.get("has_samples")]
            if not with_samples:
                return {"hinweis": "Noch kein Training mit Tempo-Verlauf aufgezeichnet."}
            training_id = with_samples[0]["id"]

    samples = await _get(f"/sessions/{training_id}/samples")
    if not samples:
        return {"training_id": training_id, "hinweis": "Fuer dieses Training gibt es keine Sekundenwerte."}

    bounds = CONFIG.get("speed_zones_kmh", [3.0, 4.5, 6.0])
    fmt = lambda v: f"{v:g}".replace(".", ",")  # noqa: E731
    labels = ([f"unter {fmt(bounds[0])} km/h"]
              + [f"{fmt(a)}–{fmt(b)} km/h" for a, b in zip(bounds, bounds[1:])]
              + [f"ab {fmt(bounds[-1])} km/h"])
    zones = dict.fromkeys(labels, 0.0)

    t0 = samples[0][0]
    changes, last = [], None
    for (t, v), nxt in zip(samples, samples[1:] + [None]):
        if v != last:
            changes.append([round((t - t0) / 60, 2), v])
            last = v
        if v > 0:
            zones[labels[sum(v >= b for b in bounds)]] += min((nxt[0] - t) if nxt else 1.0, 2.0)
    return {
        "training_id": training_id,
        "tempowechsel_minute_kmh": changes,
        "zeit_je_tempobereich": {k: _fmt_duration(v) for k, v in zones.items() if v > 0},
    }


@server.tool(annotations=CONTROL)
async def laufband_wochenziel_setzen(ziel_km: float, bezeichnung: str | None = None) -> dict:
    """Setzt das Wochenziel in km (z. B. 260 = einmal um den Bodensee, 65 = eine Viertelrunde).
    Nur auf Wunsch des Nutzers aendern."""
    resp = await _post("/settings", {"weekly_goal_km": ziel_km, "weekly_goal_label": bezeichnung or f"{ziel_km:g} km"})
    return {"ok": resp.get("ok", False), "fehler": resp.get("error"),
            "wochenziel": (resp.get("status") or {}).get("weekly_goal")}


@server.tool(annotations=CONTROL)
async def laufband_steuern(
    aktion: Literal["start", "pause", "weiter", "stopp", "tempo", "schneller", "langsamer"],
    tempo_kmh: float | None = None,
) -> dict:
    """Steuert das echte Laufband. NUR auf ausdruecklichen Wunsch des Nutzers aufrufen.
    - start: Band laeuft nach 3 s Countdown an (optional mit tempo_kmh)
    - pause / weiter: anhalten bzw. fortsetzen, Training bleibt offen
    - stopp: Training beenden und in Apple Health eintragen
    - tempo: Zieltempo auf tempo_kmh setzen (1–8 km/h); schneller/langsamer: ±0,5 km/h"""
    mapping = {"start": "start", "pause": "pause", "weiter": "resume", "stopp": "stop",
               "tempo": "speed", "schneller": "faster", "langsamer": "slower"}
    payload: dict = {}
    if aktion == "tempo":
        if tempo_kmh is None:
            return {"ok": False, "fehler": "Fuer 'tempo' bitte tempo_kmh angeben."}
        payload["value"] = tempo_kmh
    elif aktion == "start" and tempo_kmh is not None:
        payload["speed"] = tempo_kmh
    resp = await _post(f"/{mapping[aktion]}", payload)
    status = resp.get("status") or {}
    return {
        "ok": resp.get("ok", False),
        "fehler": resp.get("error"),
        "phase": status.get("phase"),
        "tempo_ziel_kmh": status.get("target_speed"),
        "ergebnis": resp.get("result"),
    }


if __name__ == "__main__":
    server.run()
