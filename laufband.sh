#!/bin/zsh
# Laufband ueber den Laufband-Daemon steuern.
#
#   laufband start [tempo]        -> Start (Standard: letztes Zieltempo)
#   laufband faster | slower      -> +/- 0.5 km/h
#   laufband setspeed 4.5
#   laufband pause | resume | stop
#   laufband status [--watch]     -> Live-Werte
#   laufband sessions [anzahl]    -> letzte Trainings
#   laufband log                  -> Daemon-Log live mitlesen
#   laufband übersicht            -> Übersichts-Fenster der Menüleisten-App öffnen

DIR="$(cd "$(dirname "$0")" && pwd)"

case "$1" in
  log)
    exec tail -n 50 -f "$HOME/Library/Logs/laufband_daemon.log"
    ;;
  übersicht|uebersicht|dashboard)
    exec "$DIR/venv/bin/python" -c 'from Foundation import NSDistributedNotificationCenter as C; C.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_("de.straubmueller.laufband.openDashboard", None, None, True)'
    ;;
esac

exec "$DIR/venv/bin/python" "$DIR/live_control.py" "$@"
