#!/usr/bin/env python3
"""
Laufband-Daemon: haelt die Bluetooth-Verbindung dauerhaft offen, fragt jede
halbe Sekunde den Status ab (SYS_STATUS), zeichnet Sessions in SQLite auf und
bietet eine HTTP/WebSocket-API auf 127.0.0.1:8765 fuer CLI, Menueleiste & Co.

    GET  /api/status             aktueller Zustand (JSON)
    GET  /api/sessions?limit=20  letzte Trainings
    POST /api/start {"speed":3}  /api/stop  /api/pause  /api/resume
    POST /api/faster  /api/slower  /api/speed {"value":4.5}
    GET  /ws                     WebSocket, pusht den Zustand bei jeder Aenderung
"""
import asyncio
import csv
import json
import logging
import os
import sqlite3
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from aiohttp import web
from bleak import BleakClient

from walk_session import (
    CONTROL_READY_OR_START,
    CONTROL_STOP,
    CONTROL_TARGET_OR_RUN,
    CONTROL_USER,
    INFO_DATE,
    INFO_INCLINE,
    INFO_MODEL,
    INFO_SPEED,
    INFO_TOTAL,
    SYS_CONTROL,
    SYS_INFO,
    SYS_STATUS,
    build_packet,
    create_health_reminder,
    estimate_steps,
    find_characteristics,
    log_workout_csv,
    parse_status_packet,
    send_trigger_message,
)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
DB_PATH = os.path.join(BASE_DIR, "laufband.db")

POLL_INTERVAL_S = 0.5
STALE_AFTER_S = 10
MAX_SAMPLE_GAP_S = 2.0

ST_NORMAL, ST_END, ST_START, ST_RUNNING, ST_STOP = 0, 1, 2, 3, 4
ST_ERROR, ST_SAFETY, ST_STUDY, ST_PAUSED = 5, 6, 7, 10
STATUS_NAMES = {
    ST_NORMAL: "normal", ST_END: "end", ST_START: "countdown", ST_RUNNING: "running",
    ST_STOP: "stop", ST_ERROR: "error", ST_SAFETY: "safety", ST_STUDY: "study", ST_PAUSED: "paused",
}

log = logging.getLogger("laufband")


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return json.load(f)


def compute_streak(per_day: dict, marks: dict, today: date, start: date, required_s: float,
                   weekdays_only: bool) -> dict:
    """Wanderstreak: jeder Werktag braucht `required_s` aktive Sekunden. Wochenenden und als
    'nicht im Buero' markierte Tage sind freiwillig. Verpasste Werktage ab `start` ohne Antwort
    bleiben 'pending' (Frage an den Nutzer) und brechen die Serie nicht."""
    def state(d: date) -> str:
        if d > today:
            return "future"
        if per_day.get(d, 0.0) >= required_s:
            return "done"
        if weekdays_only and d.weekday() >= 5:
            return "optional"
        mark = marks.get(d)
        if mark == "excused":
            return "excused"
        if d == today:
            return "open"
        if d < start or mark == "present":
            return "missed"
        return "pending"

    first = min([start, *per_day.keys()])
    current, pending, d = 0, [], today
    while d >= first:
        st = state(d)
        if st == "done":
            current += 1
        elif st == "missed":
            break
        elif st == "pending":
            pending.append(d.isoformat())
        d -= timedelta(days=1)

    best, run, d = 0, 0, first
    while d <= today:
        st = state(d)
        if st == "done":
            run += 1
            best = max(best, run)
        elif st == "missed":
            run = 0
        d += timedelta(days=1)

    week_start = today - timedelta(days=today.weekday())
    week = []
    for i in range(7):
        day = week_start + timedelta(days=i)
        week.append({"date": day.isoformat(), "state": state(day), "minutes": round(per_day.get(day, 0.0) / 60, 1)})
    return {
        "current": current,
        "best": max(best, current),
        "required_min": required_s / 60,
        "today": {"date": today.isoformat(), "state": state(today), "minutes": round(per_day.get(today, 0.0) / 60, 1)},
        "at_risk": state(today) == "open",
        "pending": sorted(pending),
        "week": week,
    }


def net_kcal_per_second(speed_kmh: float, weight_kg: float) -> float:
    # ACSM-Gehformel ohne Ruheanteil (3.5 ml/kg/min) -> "aktive Energie" wie in Apple Health
    m_per_min = speed_kmh * 1000 / 60
    return 0.1 * m_per_min * weight_kg * 5 / 1000 / 60


class CommandError(Exception):
    def __init__(self, message: str, http_status: int = 409):
        super().__init__(message)
        self.http_status = http_status


@dataclass
class Session:
    id: int
    start_ts: float
    active_s: float = 0.0
    distance_km: float = 0.0
    kcal: float = 0.0
    steps_committed: int = 0
    seg_steps: int = 0
    max_speed: float = 0.0
    paused: bool = False
    pause_since: float | None = None
    last_run_ts: float | None = None
    last_sample_ts: float = 0.0
    last_persist_ts: float = 0.0

    @property
    def device_steps(self) -> int:
        return self.steps_committed + self.seg_steps


SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY,
    start_ts REAL NOT NULL,
    end_ts REAL,
    updated_ts REAL,
    active_s REAL NOT NULL DEFAULT 0,
    distance_km REAL NOT NULL DEFAULT 0,
    kcal REAL NOT NULL DEFAULT 0,
    steps INTEGER NOT NULL DEFAULT 0,
    steps_source TEXT,
    max_speed_kmh REAL NOT NULL DEFAULT 0,
    avg_speed_kmh REAL,
    discarded INTEGER NOT NULL DEFAULT 0,
    health_logged INTEGER NOT NULL DEFAULT 0,
    end_reason TEXT
);
CREATE TABLE IF NOT EXISTS samples (
    session_id INTEGER NOT NULL REFERENCES sessions(id),
    ts REAL NOT NULL,
    speed_kmh REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_by_session ON samples(session_id, ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS streak_days (
    date TEXT PRIMARY KEY,
    status TEXT NOT NULL CHECK (status IN ('excused', 'present')),
    updated_ts REAL NOT NULL
);
"""


class Store:
    def __init__(self, path: str):
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)

    def new_session(self, start_ts: float) -> int:
        cur = self.db.execute("INSERT INTO sessions (start_ts, updated_ts) VALUES (?, ?)", (start_ts, start_ts))
        self.db.commit()
        return cur.lastrowid

    def add_sample(self, session_id: int, ts: float, speed: float):
        self.db.execute("INSERT INTO samples VALUES (?, ?, ?)", (session_id, ts, speed))
        self.db.commit()

    def persist(self, s: Session, now: float):
        self.db.execute(
            "UPDATE sessions SET updated_ts=?, active_s=?, distance_km=?, kcal=?, steps=?, max_speed_kmh=? WHERE id=?",
            (now, s.active_s, s.distance_km, s.kcal, s.device_steps, s.max_speed, s.id),
        )
        self.db.commit()

    def finish(self, s: Session, end_ts: float, summary: dict, steps_source: str, discarded: bool, reason: str):
        self.db.execute(
            """UPDATE sessions SET end_ts=?, updated_ts=?, active_s=?, distance_km=?, kcal=?, steps=?,
               steps_source=?, max_speed_kmh=?, avg_speed_kmh=?, discarded=?, end_reason=? WHERE id=?""",
            (end_ts, end_ts, summary["duration_s"], summary["distance_km"], summary["kcal"], summary["steps"],
             steps_source, s.max_speed, summary["avg_speed_kmh"], int(discarded), reason, s.id),
        )
        self.db.commit()

    def mark_health_logged(self, session_id: int):
        self.db.execute("UPDATE sessions SET health_logged=1 WHERE id=?", (session_id,))
        self.db.commit()

    def take_open_session(self) -> Session | None:
        rows = self.db.execute("SELECT * FROM sessions WHERE end_ts IS NULL ORDER BY id DESC").fetchall()
        for stale in rows[1:]:
            self.db.execute("UPDATE sessions SET end_ts=updated_ts, discarded=1, end_reason='orphaned' WHERE id=?",
                            (stale["id"],))
        self.db.commit()
        if not rows:
            return None
        r = rows[0]
        return Session(
            id=r["id"], start_ts=r["start_ts"], active_s=r["active_s"], distance_km=r["distance_km"],
            kcal=r["kcal"], steps_committed=r["steps"], max_speed=r["max_speed_kmh"],
            paused=True, pause_since=r["updated_ts"],
        )

    def recent(self, limit: int) -> list[dict]:
        rows = self.db.execute(
            """SELECT s.*, EXISTS(SELECT 1 FROM samples WHERE session_id = s.id) AS has_samples
               FROM sessions s WHERE end_ts IS NOT NULL AND discarded=0 ORDER BY start_ts DESC LIMIT ?""",
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]

    def distance_totals(self, day_start: float, week_start: float) -> dict:
        """Summen heute / diese Woche / insgesamt ueber abgeschlossene Trainings."""
        def agg(since: float) -> dict:
            r = self.db.execute(
                "SELECT COALESCE(SUM(distance_km),0) km, COALESCE(SUM(active_s),0) s, COALESCE(SUM(steps),0) steps, "
                "COUNT(*) n FROM sessions WHERE end_ts IS NOT NULL AND discarded=0 AND start_ts >= ?", (since,)
            ).fetchone()
            return {"km": r["km"], "s": r["s"], "steps": r["steps"], "n": r["n"]}
        return {"today": agg(day_start), "week": agg(week_start), "total": agg(0)}

    def daily_seconds(self) -> dict:
        """Aktive Sekunden je Kalendertag (lokal) ueber alle gueltigen Trainings."""
        per_day: dict = {}
        for r in self.db.execute("SELECT start_ts, active_s FROM sessions WHERE end_ts IS NOT NULL AND discarded=0"):
            d = datetime.fromtimestamp(r["start_ts"]).date()
            per_day[d] = per_day.get(d, 0.0) + r["active_s"]
        return per_day

    def streak_marks(self) -> dict:
        return {date.fromisoformat(r["date"]): r["status"] for r in self.db.execute("SELECT date, status FROM streak_days")}

    def set_streak_mark(self, day: str, status: str):
        if status == "clear":
            self.db.execute("DELETE FROM streak_days WHERE date=?", (day,))
        else:
            self.db.execute("INSERT OR REPLACE INTO streak_days VALUES (?, ?, ?)", (day, status, time.time()))
        self.db.commit()

    def samples(self, session_id: int) -> list[list[float]]:
        rows = self.db.execute("SELECT ts, speed_kmh FROM samples WHERE session_id=? ORDER BY ts", (session_id,))
        return [[r["ts"], r["speed_kmh"]] for r in rows]

    def last_speed(self, session_id: int) -> float | None:
        r = self.db.execute("SELECT speed_kmh FROM samples WHERE session_id=? AND speed_kmh > 0 ORDER BY ts DESC LIMIT 1",
                            (session_id,)).fetchone()
        return r["speed_kmh"] if r else None

    def zones(self, since_ts: float, bounds: list[float]) -> list[dict]:
        """Sekunden je Tempobereich pro Training. Ohne Sekundenwerte (alte CSV-Trainings)
        wird die ganze Dauer dem Bereich des Durchschnittstempos zugeordnet."""
        def zone_of(v: float) -> int:
            return sum(v >= b for b in bounds)

        result = []
        sessions = self.db.execute(
            "SELECT id, start_ts, active_s, avg_speed_kmh FROM sessions "
            "WHERE end_ts IS NOT NULL AND discarded=0 AND start_ts >= ? ORDER BY start_ts",
            (since_ts,),
        ).fetchall()
        for s in sessions:
            secs = [0.0] * (len(bounds) + 1)
            rows = self.samples(s["id"])
            if rows:
                for (t, v), nxt in zip(rows, rows[1:] + [None]):
                    if v > 0:
                        secs[zone_of(v)] += min((nxt[0] - t) if nxt else 1.0, MAX_SAMPLE_GAP_S)
            elif s["avg_speed_kmh"]:
                secs[zone_of(s["avg_speed_kmh"])] = s["active_s"]
            result.append({"session_id": s["id"], "start_ts": s["start_ts"],
                           "estimated": not rows, "seconds": [round(x, 1) for x in secs]})
        return result

    def import_csv_once(self, csv_path: str, cfg: dict):
        """Uebernimmt die Trainings aus der Zeit vor dem Daemon. In der alten
        CSV ist 'date' der Stopp-Zeitpunkt, daher Start = date - Dauer."""
        if self.db.execute("SELECT 1 FROM meta WHERE key='csv_imported'").fetchone() or not os.path.exists(csv_path):
            return
        with open(csv_path) as f:
            for row in csv.DictReader(f):
                duration = int(row["duration_s"])
                end_ts = datetime.fromisoformat(row["date"]).timestamp()
                speed = float(row["avg_speed_kmh"])
                self.db.execute(
                    """INSERT INTO sessions (start_ts, end_ts, updated_ts, active_s, distance_km, kcal, steps,
                       steps_source, max_speed_kmh, avg_speed_kmh, discarded, health_logged, end_reason)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'estimate', ?, ?, ?, 1, 'csv-import')""",
                    (end_ts - duration, end_ts, end_ts, duration, float(row["distance_km"]),
                     round(net_kcal_per_second(speed, cfg["weight_kg"]) * duration), int(row["steps"]),
                     speed, speed, int(duration < cfg["min_session_s"])),
                )
        self.db.execute("INSERT INTO meta VALUES ('csv_imported', ?)", (datetime.now().isoformat(),))
        self.db.commit()


class Daemon:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.store = Store(DB_PATH)
        self.store.import_csv_once(os.path.join(BASE_DIR, "workouts.csv"), cfg)
        if "streak_start" not in cfg:
            # Rueckfragen ("warst du im Buero?") erst ab Einfuehrung des Streaks, nicht fuer die ganze Historie
            self._persist_config({"streak_start": date.today().isoformat(), "streak_min_minutes": 5,
                                  "streak_weekdays_only": True})
        self.queue: asyncio.Queue = asyncio.Queue()
        self.connected = False
        self.device_status: int | None = None
        self.countdown: int | None = None
        self.speed = 0.0
        self.heart = 0
        self.min_speed = 1.0
        self.max_speed = 8.0
        self.target_speed = float(cfg["default_speed"])
        self.last_speed_cmd_ts = 0.0
        self._last_seen_speed = 0.0
        self._speed_stable_since = 0.0
        self.ignore_running_until = 0.0
        # Das Band ignoriert Tempo-Befehle waehrend des Countdowns und laeuft mit 1,0 km/h an
        self.apply_target_on_run = False
        self.ignore_external_until = 0.0
        self.last_packet_ts = 0.0
        self.last_finished: dict | None = None
        self.last_error: str | None = None
        self.session = self.store.take_open_session()
        if self.session:
            # "Weiter" soll im zuletzt gelaufenen Tempo fortsetzen, nicht beim Standardtempo
            self.target_speed = self.store.last_speed(self.session.id) or self.target_speed
            log.info("Offene Session %s wiederhergestellt (pausiert, Tempo %.1f)", self.session.id, self.target_speed)
        self.ws_clients: set[web.WebSocketResponse] = set()
        self._broadcast_pending = False
        self._tasks: set[asyncio.Task] = set()

    # ---------------------------------------------------------------- Bluetooth

    async def ble_loop(self):
        backoff = 2
        while True:
            try:
                await self._connect_and_run()
                backoff = 2
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.info("Keine Verbindung (%s: %s), neuer Versuch in %ss", type(e).__name__, e, backoff)
            self._set_disconnected()
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 15)

    async def _connect_and_run(self):
        disconnected = asyncio.Event()
        async with BleakClient(self.cfg["address"], timeout=15,
                               disconnected_callback=lambda _c: disconnected.set()) as client:
            write_char, notify_char = find_characteristics(client)
            if write_char is None or notify_char is None:
                raise RuntimeError("FitShow-Characteristics nicht gefunden")
            await client.start_notify(notify_char, self._on_notify)

            async def write(payload: bytes, label: str | None):
                if label:
                    log.info("-> %s  %s", build_packet(payload).hex(" "), label)
                await client.write_gatt_char(write_char, build_packet(payload), response=False)

            while not self.queue.empty():
                self.queue.get_nowait()
            self.connected = True
            self.last_packet_ts = time.time()
            log.info("Verbunden mit %s", self.cfg["address"])

            now = datetime.now()
            await write(bytes([SYS_INFO, INFO_MODEL, now.year - 2000, now.month, now.day,
                               now.hour, now.minute, now.second]), "info_model")
            for info in (INFO_SPEED, INFO_INCLINE, INFO_TOTAL, INFO_DATE):
                await asyncio.sleep(0.2)
                await write(bytes([SYS_INFO, info]), f"info_{info}")
            self._changed()

            while not disconnected.is_set():
                try:
                    payload, label = await asyncio.wait_for(self.queue.get(), timeout=POLL_INTERVAL_S)
                    await write(payload, label)
                    await asyncio.sleep(0.15)
                except TimeoutError:
                    await write(bytes([SYS_STATUS]), None)
                if time.time() - self.last_packet_ts > STALE_AFTER_S:
                    raise RuntimeError("Laufband antwortet nicht mehr")
            log.info("Verbindung getrennt")

    def _set_disconnected(self):
        if self.connected:
            self.connected = False
            self.device_status = None
            self.countdown = None
            self.speed = 0.0
            self._changed()

    def _on_notify(self, _sender, data):
        raw = bytes(data)
        now = time.time()
        self.last_packet_ts = now
        if len(raw) < 4:
            return
        if raw[1] == SYS_INFO and raw[2] == INFO_SPEED and len(raw) >= 7:
            hi, lo = raw[3] / 10, raw[4] / 10
            if 0 < lo < hi:
                self.max_speed, self.min_speed = hi, lo
                log.info("Tempo-Bereich laut Geraet: %.1f-%.1f km/h", lo, hi)
        elif raw[1] == SYS_STATUS:
            self._on_status(raw, now)

    def _on_status(self, raw: bytes, now: float):
        status = raw[2]
        if status != self.device_status:
            log.info("Status: %s", STATUS_NAMES.get(status, status))
        self.device_status = status
        self.countdown = raw[3] if status == ST_START and len(raw) > 4 else None
        parsed = parse_status_packet(raw)
        dev_steps = None
        if parsed and status == ST_RUNNING:
            self.speed = parsed["speed"]
            self.heart = parsed["heart"]
            dev_steps = parsed["step_count"]
        else:
            self.speed = 0.0
        self._track(status, now, dev_steps)
        if status == ST_RUNNING and self.apply_target_on_run:
            self.apply_target_on_run = False
            self.ignore_external_until = now + 8
            if abs(self.speed - self.target_speed) >= 0.1:
                log.info("Countdown vorbei, setze Zieltempo %.1f km/h", self.target_speed)
                self._enqueue(self._speed_cmd(self.target_speed))
        self._follow_external_speed_change(status, now)
        self._changed()

    def _follow_external_speed_change(self, status: int, now: float):
        # Tempo an der Fernbedienung geaendert -> Zielwert uebernehmen (aber nicht waehrend das Band hochfaehrt)
        if self.speed != self._last_seen_speed:
            self._last_seen_speed = self.speed
            self._speed_stable_since = now
        if (status == ST_RUNNING and self.speed > 0 and abs(self.speed - self.target_speed) >= 0.1
                and self.queue.empty() and now - self.last_speed_cmd_ts > 5
                and now - self._speed_stable_since > 3 and now > self.ignore_external_until):
            log.info("Tempo extern geaendert: %.1f km/h", self.speed)
            self.target_speed = self.speed

    # ---------------------------------------------------------------- Sessions

    def _track(self, status: int, now: float, dev_steps: int | None):
        s = self.session
        if status == ST_RUNNING:
            if s is None:
                if now < self.ignore_running_until:
                    return
                s = self.session = Session(id=self.store.new_session(now), start_ts=now)
                log.info("Session %s gestartet", s.id)
            if s.paused:
                s.paused, s.pause_since, s.last_run_ts = False, None, None
            if s.last_run_ts is not None:
                dt = min(now - s.last_run_ts, MAX_SAMPLE_GAP_S)
                s.active_s += dt
                s.distance_km += self.speed * dt / 3600
                s.kcal += net_kcal_per_second(self.speed, self.cfg["weight_kg"]) * dt
            s.last_run_ts = now
            s.max_speed = max(s.max_speed, self.speed)
            if dev_steps:
                s.seg_steps = dev_steps
            if now - s.last_sample_ts >= 1:
                self.store.add_sample(s.id, now, self.speed)
                s.last_sample_ts = now
            if now - s.last_persist_ts >= 5:
                self.store.persist(s, now)
                s.last_persist_ts = now
        elif s is not None and not s.paused and status != ST_START:
            self._pause_session(now)

    def _pause_session(self, now: float):
        s = self.session
        s.paused = True
        s.pause_since = s.last_run_ts or now
        s.steps_committed += s.seg_steps
        s.seg_steps = 0
        s.last_run_ts = None
        self.store.persist(s, now)
        log.info("Session %s pausiert", s.id)

    async def housekeeping_loop(self):
        while True:
            await asyncio.sleep(2)
            now = time.time()
            s = self.session
            if s is None:
                continue
            if not s.paused and (not self.connected or (s.last_run_ts and now - s.last_run_ts > 5)):
                self._pause_session(now)
                self._changed()
            elif s.paused and now - s.pause_since > self.cfg["auto_finish_pause_s"]:
                self._finalize("auto")
                self._changed()

    def _finalize(self, reason: str) -> dict | None:
        s = self.session
        if s is None:
            return None
        self.session = None
        self._streak_cache = None
        if hasattr(self, "_totals_cache"):
            del self._totals_cache
        # naechster Start beginnt wieder beim Standardtempo, nicht beim letzten (evtl. hohen) Wert
        self.target_speed = float(self.cfg["default_speed"])
        end_ts = s.pause_since if s.paused else time.time()
        if not s.paused:
            s.steps_committed += s.seg_steps
            s.seg_steps = 0

        duration_s = int(round(s.active_s))
        distance_km = round(s.distance_km, 3)
        if s.steps_committed > 0:
            steps, steps_source = s.steps_committed, "device"
        else:
            steps, steps_source = estimate_steps(distance_km, self.cfg["height_cm"], self.cfg["sex"]), "estimate"
        summary = {
            "date": datetime.fromtimestamp(s.start_ts).isoformat(timespec="seconds"),
            "duration_s": duration_s,
            "distance_km": distance_km,
            "steps": steps,
            "kcal": round(s.kcal),
            "avg_speed_kmh": round(distance_km / (duration_s / 3600), 2) if duration_s else 0.0,
        }
        keep = duration_s >= self.cfg["min_session_s"]
        self.store.finish(s, end_ts, summary, steps_source, discarded=not keep, reason=reason)
        self.last_finished = {**summary, "logged": keep, "reason": reason}
        log.info("Session %s beendet (%s): %s%s", s.id, reason, summary, "" if keep else " -> zu kurz, verworfen")
        if keep:
            task = asyncio.get_running_loop().create_task(self._report_to_health(s.id, summary))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        return self.last_finished

    async def _report_to_health(self, session_id: int, summary: dict):
        """Massgeblich ist die iMessage (loest die Kurzbefehle-Automation fuer Health aus);
        CSV und Erinnerung sind Beiwerk und duerfen scheitern."""
        def run() -> bool:
            for fn in (log_workout_csv, create_health_reminder):
                try:
                    fn(summary)
                except Exception as e:
                    log.warning("%s fehlgeschlagen (nicht kritisch): %s", fn.__name__, e)
            try:
                send_trigger_message(summary)
                return True
            except Exception as e:
                log.warning("send_trigger_message fehlgeschlagen: %s", e)
                return False

        if await asyncio.to_thread(run):
            self.store.mark_health_logged(session_id)
        else:
            self.last_error = "Health-Export fehlgeschlagen: iMessage konnte nicht gesendet werden (siehe Log)"
            self._changed()

    # ---------------------------------------------------------------- Befehle

    def _clamp(self, v: float) -> float:
        return round(min(self.max_speed, max(self.min_speed, v)), 1)

    def _speed_cmd(self, v: float):
        return bytes([SYS_CONTROL, CONTROL_TARGET_OR_RUN, round(v * 10) & 0xFF, 0]), f"speed={v}"

    def _start_sequence(self, v: float):
        now = datetime.now()
        return [
            (bytes([SYS_INFO, INFO_MODEL, now.year - 2000, now.month, now.day, now.hour, now.minute, now.second]),
             "info_model"),
            (bytes([SYS_CONTROL, CONTROL_USER, 1, 0, 110, 30, int(self.cfg["weight_kg"]) & 0xFF]), "init_user"),
            (bytes([SYS_CONTROL, CONTROL_READY_OR_START, 0, 0, 0, 0, 0, 0, 0, 0]), "start"),
            self._speed_cmd(v),
        ]

    def _enqueue(self, *items):
        for item in items:
            self.queue.put_nowait(item)
        self.last_speed_cmd_ts = time.time()

    @property
    def band_moving(self) -> bool:
        return self.device_status in (ST_RUNNING, ST_START)

    def command(self, action: str, params: dict):
        self.last_error = None
        if action == "settings":
            return self.update_settings(params)
        if action == "streak":
            return self.mark_streak_day(params)
        if action in ("start", "resume"):
            if not self.connected:
                raise CommandError("Laufband nicht verbunden", 503)
            if params.get("speed") is not None:
                self.target_speed = self._clamp(float(params["speed"]))
                self.last_speed_cmd_ts = time.time()
            if self.band_moving:
                self._enqueue(self._speed_cmd(self.target_speed))
            else:
                self.ignore_running_until = 0.0
                self.apply_target_on_run = True
                self._enqueue(*self._start_sequence(self.target_speed))
            return None
        if action == "pause":
            if not self.connected:
                raise CommandError("Laufband nicht verbunden", 503)
            if not self.band_moving:
                raise CommandError("Band laeuft gerade nicht")
            self._enqueue((bytes([SYS_CONTROL, CONTROL_STOP]), "pause (stop)"))
            return None
        if action == "stop":
            if self.session is None and not self.band_moving:
                raise CommandError("Laeuft gerade nicht")
            if self.connected and self.band_moving:
                self._enqueue((bytes([SYS_CONTROL, CONTROL_STOP]), "stop"))
                self.ignore_running_until = time.time() + 5
            return self._finalize("stop")
        if action in ("speed", "faster", "slower"):
            if action == "speed":
                if params.get("value") is None:
                    raise CommandError("'value' fehlt", 400)
                v = float(params["value"])
            else:
                step = float(self.cfg["speed_step"])
                v = self.target_speed + (step if action == "faster" else -step)
            self.target_speed = self._clamp(v)
            self.last_speed_cmd_ts = time.time()
            if self.connected and self.device_status == ST_RUNNING:
                self._enqueue(self._speed_cmd(self.target_speed))
            return None
        raise CommandError(f"Unbekannte Aktion '{action}'", 404)

    # ---------------------------------------------------------------- Zustand

    def phase(self) -> str:
        if self.session and self.session.paused:
            return "paused"
        if not self.connected:
            return "offline"
        if self.device_status == ST_START:
            return "countdown"
        if self.device_status == ST_RUNNING:
            return "running"
        if self.device_status in (ST_ERROR, ST_SAFETY):
            return "error"
        return "idle"

    def totals(self, now: float) -> dict:
        """Heute / Woche (ab Montag) / Gesamt inkl. laufendem Training; 10 s zwischengespeichert."""
        if not hasattr(self, "_totals_cache") or now - self._totals_cache[0] > 10:
            today = datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
            week = today - timedelta(days=today.weekday())
            self._totals_cache = (now, self.store.distance_totals(today.timestamp(), week.timestamp()),
                                  today.timestamp(), week.timestamp())
        _, base, day_start, week_start = self._totals_cache
        out = {k: dict(v) for k, v in base.items()}
        s = self.session
        if s is not None:
            live = {"km": s.distance_km, "s": s.active_s, "steps": s.device_steps or estimate_steps(
                s.distance_km, self.cfg["height_cm"], self.cfg["sex"]), "n": 1}
            for key, since in (("today", day_start), ("week", week_start), ("total", 0)):
                if s.start_ts >= since:
                    for field in ("km", "s", "steps", "n"):
                        out[key][field] += live[field]
        for v in out.values():
            v["km"] = round(v["km"], 3)
            v["s"] = int(v["s"])
        return out

    def snapshot(self) -> dict:
        now = time.time()
        s = self.session
        session = None
        if s:
            steps = s.device_steps or estimate_steps(s.distance_km, self.cfg["height_cm"], self.cfg["sex"])
            session = {
                "id": s.id,
                "start": datetime.fromtimestamp(s.start_ts).isoformat(timespec="seconds"),
                "start_ts": s.start_ts,
                "active_s": int(s.active_s),
                "distance_km": round(s.distance_km, 3),
                "kcal": round(s.kcal, 1),
                "steps": steps,
                "steps_source": "device" if s.device_steps else "estimate",
                "max_speed": s.max_speed,
                "paused": s.paused,
                "paused_for_s": int(now - s.pause_since) if s.paused else None,
            }
        return {
            "phase": self.phase(),
            "connected": self.connected,
            "device_status": STATUS_NAMES.get(self.device_status) if self.device_status is not None else None,
            "countdown": self.countdown,
            "speed": self.speed,
            "target_speed": self.target_speed,
            "min_speed": self.min_speed,
            "max_speed": self.max_speed,
            "heart": self.heart or None,
            "session": session,
            "last_finished": self.last_finished,
            "last_error": self.last_error,
            "auto_finish_after_s": self.cfg["auto_finish_pause_s"],
            "daily_step_goal": self.cfg.get("daily_step_goal", 10000),
            "weekly_goal": {
                "km": self.cfg.get("weekly_goal_km", 260),
                "label": self.cfg.get("weekly_goal_label", "1× Bodensee-Runde"),
            },
            "totals": self.totals(now),
            "streak": self.streak(now),
        }

    def update_settings(self, params: dict) -> dict:
        """Ziele aendern und dauerhaft in config.json speichern."""
        changes = {}
        if "weekly_goal_km" in params:
            km = float(params["weekly_goal_km"])
            if not 0.5 <= km <= 5000:
                raise CommandError("Wochenziel muss zwischen 0,5 und 5000 km liegen", 400)
            changes["weekly_goal_km"] = round(km, 1)
            changes["weekly_goal_label"] = str(params.get("weekly_goal_label") or f"{km:g} km")[:60]
        if "daily_step_goal" in params:
            steps = int(params["daily_step_goal"])
            if not 100 <= steps <= 100_000:
                raise CommandError("Tagesziel muss zwischen 100 und 100.000 Schritten liegen", 400)
            changes["daily_step_goal"] = steps
        if not changes:
            raise CommandError("Keine gueltige Einstellung", 400)
        self._persist_config(changes)
        log.info("Einstellungen geaendert: %s", changes)
        return changes

    def _persist_config(self, changes: dict):
        with open(CONFIG_PATH) as f:
            on_disk = json.load(f)
        on_disk.update(changes)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(on_disk, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, CONFIG_PATH)
        self.cfg.update(changes)

    def streak(self, now: float) -> dict:
        cached = getattr(self, "_streak_cache", None)
        if cached is None or now - cached[0] > 5:
            self._streak_cache = (now, self.store.daily_seconds(), self.store.streak_marks())
        _, per_day, marks = self._streak_cache
        per_day = dict(per_day)
        s = self.session
        if s is not None:
            d = datetime.fromtimestamp(s.start_ts).date()
            per_day[d] = per_day.get(d, 0.0) + s.active_s
        return compute_streak(per_day, marks, datetime.fromtimestamp(now).date(),
                              date.fromisoformat(self.cfg["streak_start"]),
                              float(self.cfg.get("streak_min_minutes", 5)) * 60,
                              bool(self.cfg.get("streak_weekdays_only", True)))

    def mark_streak_day(self, params: dict) -> dict:
        day = str(params.get("date") or date.today().isoformat())
        status = str(params.get("status", ""))
        try:
            date.fromisoformat(day)
        except ValueError:
            raise CommandError("Datum bitte als JJJJ-MM-TT", 400)
        if status not in ("excused", "present", "clear"):
            raise CommandError("status muss excused, present oder clear sein", 400)
        self.store.set_streak_mark(day, status)
        self._streak_cache = None
        log.info("Streak-Tag %s: %s", day, status)
        return {"date": day, "status": status}

    def _changed(self):
        if self._broadcast_pending or not self.ws_clients:
            return
        self._broadcast_pending = True
        asyncio.get_running_loop().call_later(0.2, self._broadcast)

    def _broadcast(self):
        self._broadcast_pending = False
        data = json.dumps(self.snapshot())
        for ws in list(self.ws_clients):
            task = asyncio.get_running_loop().create_task(ws.send_str(data))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)


# -------------------------------------------------------------------- HTTP-API

def build_app(d: Daemon) -> web.Application:
    port = d.cfg["port"]
    allowed_origins = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    @web.middleware
    async def reject_foreign_origins(request, handler):
        # verhindert, dass beliebige Webseiten im Browser per fetch() das Band starten
        origin = request.headers.get("Origin")
        if origin is not None and origin not in allowed_origins:
            return web.json_response({"ok": False, "error": "Origin nicht erlaubt"}, status=403)
        return await handler(request)

    async def status(_request):
        return web.json_response(d.snapshot())

    async def sessions(request):
        limit = int(request.query.get("limit", 20))
        return web.json_response(d.store.recent(limit))

    async def samples(request):
        return web.json_response(d.store.samples(int(request.match_info["id"])))

    async def zones(request):
        since = float(request.query.get("since", 0))
        bounds = d.cfg.get("speed_zones_kmh", [3.0, 4.5, 6.0])
        return web.json_response({"bounds_kmh": bounds, "sessions": d.store.zones(since, bounds)})

    async def command(request):
        params = dict(request.query)
        if request.can_read_body:
            try:
                body = await request.json()
                if isinstance(body, dict):
                    params.update(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass
        try:
            result = d.command(request.match_info["action"], params)
        except (CommandError, ValueError) as e:
            http_status = e.http_status if isinstance(e, CommandError) else 400
            d.last_error = str(e)
            d._changed()
            return web.json_response({"ok": False, "error": str(e), "status": d.snapshot()}, status=http_status)
        d._changed()
        return web.json_response({"ok": True, "result": result, "status": d.snapshot()})

    async def websocket(request):
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(request)
        d.ws_clients.add(ws)
        try:
            await ws.send_str(json.dumps(d.snapshot()))
            async for _msg in ws:
                pass
        finally:
            d.ws_clients.discard(ws)
        return ws

    app = web.Application(middlewares=[reject_foreign_origins])
    app.add_routes([
        web.get("/api/status", status),
        web.get("/api/sessions", sessions),
        web.get("/api/sessions/{id:\\d+}/samples", samples),
        web.get("/api/zones", zones),
        web.post("/api/{action}", command),
        web.get("/ws", websocket),
    ])
    return app


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg = load_config()
    d = Daemon(cfg)
    runner = web.AppRunner(build_app(d), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, cfg["host"], cfg["port"]).start()
    log.info("API auf http://%s:%s", cfg["host"], cfg["port"])
    await asyncio.gather(d.ble_loop(), d.housekeeping_loop())


if __name__ == "__main__":
    asyncio.run(main())
