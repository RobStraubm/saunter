"""Tages- und Wochen-Streak (compute_streak) – ohne Geraet, nur mit Daten."""
from datetime import date, timedelta

from saunter_daemon import compute_streak

MIN = 300  # 5 min in Sekunden
START = date(2026, 9, 28)  # ein Montag


def walked(*days, seconds=MIN):
    return {d: seconds for d in days}


def streak(per_day, marks=None, today=date(2026, 10, 23)):
    return compute_streak(per_day, marks or {}, today, START, MIN, True)


def week_days(monday, *offsets):
    return [monday + timedelta(days=o) for o in offsets]


# ---------------------------------------------------------------- Tages-Streak

def test_tages_streak_zaehlt_aufeinanderfolgende_werktage():
    today = date(2026, 10, 23)  # Freitag
    s = streak(walked(*week_days(date(2026, 10, 19), 0, 1, 2, 3, 4)), today=today)
    assert s["current"] == 5
    assert s["today"]["state"] == "done"


def test_wochenende_bricht_tages_streak_nicht():
    today = date(2026, 10, 19)  # Montag
    s = streak(walked(date(2026, 10, 16), date(2026, 10, 19)), today=today)
    assert s["current"] == 2


def test_nicht_im_buero_bricht_tages_streak_nicht():
    today = date(2026, 10, 23)
    marks = {date(2026, 10, 22): "excused"}
    s = streak(walked(date(2026, 10, 21), date(2026, 10, 23)), marks, today)
    assert s["current"] == 2


def test_unbeantworteter_tag_ist_offene_frage():
    today = date(2026, 10, 23)
    s = streak(walked(date(2026, 10, 21), date(2026, 10, 23)), today=today)
    assert "2026-10-22" in s["pending"]


def test_war_im_buero_ohne_laufen_bricht_tages_streak():
    today = date(2026, 10, 23)
    marks = {date(2026, 10, 22): "present"}
    s = streak(walked(date(2026, 10, 21), date(2026, 10, 23)), marks, today)
    assert s["current"] == 1


def test_zu_kurz_gelaufen_zaehlt_nicht():
    today = date(2026, 10, 23)
    s = streak(walked(today, seconds=MIN - 1), today=today)
    assert s["today"]["state"] == "open"
    assert s["at_risk"] is True


def test_recent_liefert_vier_wochen_bis_heute():
    today = date(2026, 10, 23)
    s = streak({}, today=today)
    assert len(s["recent"]) == 28
    assert s["recent"][-1]["date"] == today.isoformat()


# ---------------------------------------------------------------- Wochen-Streak

def test_volle_buerowoche_braucht_vier_lauftage():
    monday = date(2026, 10, 19)
    s = streak(walked(*week_days(monday, 0, 1, 2)), today=monday + timedelta(days=4))
    w = s["week_streak"]
    assert (w["office_days"], w["required_days"], w["walk_days"]) == (5, 4, 3)
    assert w["state"] == "open"


def test_wochenende_zaehlt_als_lauftag():
    monday = date(2026, 10, 19)
    s = streak(walked(*week_days(monday, 0, 1, 2, 5)), today=monday + timedelta(days=6))
    assert s["week_streak"]["state"] == "reached"


def test_weniger_buerotage_senken_das_ziel():
    monday = date(2026, 10, 19)
    marks = {d: "excused" for d in week_days(monday, 3, 4)}
    s = streak(walked(*week_days(monday, 0, 1)), marks, monday + timedelta(days=4))
    w = s["week_streak"]
    assert (w["office_days"], w["required_days"], w["state"]) == (3, 2, "reached")


def test_urlaubswoche_ist_neutral():
    monday = date(2026, 10, 12)
    per_day = walked(*week_days(date(2026, 10, 5), 0, 1, 2, 3), *week_days(date(2026, 10, 19), 0, 1, 2, 3))
    marks = {d: "excused" for d in week_days(monday, 0, 1, 2, 3, 4)}
    s = streak(per_day, marks, date(2026, 10, 25))
    w = s["week_streak"]
    assert w["current"] == 2  # Woche vom 5.10. + 19.10., die Urlaubswoche dazwischen zaehlt nicht


def test_verpasste_woche_bricht_wochen_streak():
    per_day = walked(*week_days(date(2026, 10, 5), 0, 1, 2, 3), *week_days(date(2026, 10, 19), 0, 1, 2, 3))
    s = streak(per_day, today=date(2026, 10, 25))
    w = s["week_streak"]
    assert w["current"] == 1
    assert w["best"] == 1
    assert w["weeks_reached"] == 2


def test_laufende_woche_bricht_die_serie_nicht():
    per_day = walked(*week_days(date(2026, 10, 12), 0, 1, 2, 3))
    s = streak(per_day, today=date(2026, 10, 20))  # Dienstag der Folgewoche, noch nichts gelaufen
    assert s["week_streak"]["current"] == 1
    assert s["week_streak"]["state"] == "open"


def test_mehr_cheat_days_senken_das_ziel():
    monday = date(2026, 10, 19)
    s = compute_streak(walked(monday), {}, monday + timedelta(days=4), START, MIN, True, cheat_days=4)
    assert s["week_streak"]["required_days"] == 1
    assert s["week_streak"]["state"] == "reached"
