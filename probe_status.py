#!/usr/bin/env python3
"""Status-Test: verbindet, fragt Geraete-Info und SYS_STATUS ab. Ohne --run
bewegt sich das Band nicht; mit --run laeuft es mit 1.0 km/h und stoppt danach."""
import asyncio
import json
import os
import sys
from datetime import datetime

from bleak import BleakClient

from walk_session import (
    CONTROL_READY_OR_START,
    CONTROL_STOP,
    CONTROL_TARGET_OR_RUN,
    CONTROL_USER,
    SYS_CONTROL,
    INFO_DATE,
    INFO_INCLINE,
    INFO_MODEL,
    INFO_SPEED,
    INFO_TOTAL,
    SYS_INFO,
    SYS_STATUS,
    build_packet,
    find_characteristics,
    parse_status_packet,
)


# Geraete-Adresse steht lokal in config.json ("address", wird von install.sh gesetzt),
# nicht im Code.
def _address() -> str:
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")) as f:
            return str(json.load(f).get("address", ""))
    except (OSError, ValueError):
        return ""


ADDRESS = _address()
STATUS_NAMES = {0: "NORMAL", 1: "END", 2: "START/COUNTDOWN", 3: "RUNNING", 4: "STOP",
                5: "ERROR", 6: "SAFETY", 7: "STUDY", 10: "PAUSED"}


async def main(seconds: float, run: bool):
    status_count = 0

    def on_notify(_s, data):
        nonlocal status_count
        raw = bytes(data)
        tag = ""
        if len(raw) > 2 and raw[1] == SYS_STATUS:
            status_count += 1
            tag = f"STATUS {STATUS_NAMES.get(raw[2], raw[2])}"
            parsed = parse_status_packet(raw)
            if parsed:
                tag += f" {parsed}"
        elif len(raw) > 1 and raw[1] == SYS_INFO:
            tag = "INFO"
        print(f"<- {raw.hex(' ')}   {tag}")

    async with BleakClient(ADDRESS, timeout=20) as client:
        write_char, notify_char = find_characteristics(client)
        print(f"write={write_char.uuid if write_char else None} notify={notify_char.uuid if notify_char else None}")
        if not write_char or not notify_char:
            return
        await client.start_notify(notify_char, on_notify)

        async def send(payload: bytes, label: str):
            print(f"-> {build_packet(payload).hex(' ')}  {label}")
            await client.write_gatt_char(write_char, build_packet(payload), response=False)
            await asyncio.sleep(0.3)

        now = datetime.now()
        await send(bytes([SYS_INFO, INFO_MODEL, now.year - 2000, now.month, now.day,
                          now.hour, now.minute, now.second]), "info_model")
        for info in (INFO_SPEED, INFO_INCLINE, INFO_TOTAL, INFO_DATE):
            await send(bytes([SYS_INFO, info]), f"info_{info}")

        if run:
            await send(bytes([SYS_CONTROL, CONTROL_USER, 1, 0, 110, 30, 75]), "init_user")
            await send(bytes([SYS_CONTROL, CONTROL_READY_OR_START, 0, 0, 0, 0, 0, 0, 0, 0]), "start")
            await send(bytes([SYS_CONTROL, CONTROL_TARGET_OR_RUN, 10, 0]), "speed=1.0")

        print(f"--- poll SYS_STATUS fuer {seconds:.0f}s ---")
        end = asyncio.get_event_loop().time() + seconds
        try:
            while asyncio.get_event_loop().time() < end:
                await client.write_gatt_char(write_char, build_packet(bytes([SYS_STATUS])), response=False)
                await asyncio.sleep(0.5)
        finally:
            if run:
                await send(bytes([SYS_CONTROL, CONTROL_STOP]), "stop")
                for _ in range(6):
                    await client.write_gatt_char(write_char, build_packet(bytes([SYS_STATUS])), response=False)
                    await asyncio.sleep(0.5)

    print(f"\nSTATUS-Antworten empfangen: {status_count}")


if __name__ == "__main__":
    if not ADDRESS:
        sys.exit('Keine Geraete-Adresse: bitte "address" in config.json eintragen (Vorlage: config.example.json).')
    args = [a for a in sys.argv[1:] if a != "--run"]
    asyncio.run(main(float(args[0]) if args else 8, "--run" in sys.argv))
