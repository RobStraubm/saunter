#!/bin/zsh
# Laufband ueber den Saunter-Daemon steuern.
#
#   saunter start [tempo]        -> Start (Standard: letztes Zieltempo)
#   saunter faster | slower      -> +/- 0.5 km/h
#   saunter setspeed 4.5
#   saunter pause | resume | stop
#   saunter status [--watch]     -> Live-Werte
#   saunter sessions [anzahl]    -> letzte Trainings
#   saunter log                  -> Daemon-Log live mitlesen
#   saunter übersicht            -> Übersichts-Fenster der Menüleisten-App öffnen

DIR="$(cd "$(dirname "$0")" && pwd)"

case "$1" in
  log)
    exec tail -n 50 -f "$HOME/Library/Logs/saunter_daemon.log"
    ;;
  übersicht|uebersicht|dashboard)
    exec "$DIR/venv/bin/python" -c 'from Foundation import NSDistributedNotificationCenter as C; C.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_("de.straubmueller.saunter.openDashboard", None, None, True)'
    ;;
esac

exec "$DIR/venv/bin/python" "$DIR/live_control.py" "$@"
