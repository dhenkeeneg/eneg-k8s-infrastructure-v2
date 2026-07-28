#!/usr/bin/env python3
"""Auswertung von CNPG .status.instancesReportedState fuer das Health-Gate.

Aufruf:  hg_cnpg_timeline.py '<instancesReportedState-JSON>' <erwartete_anzahl>
Ausgabe: genau eine Zeile.
           OK        -> alle Instanzen melden dieselbe Timeline, genau ein Primary
           <grund>    -> Beschreibung des Problems (wird vom Gate als WAIT gemeldet)

Exit-Code ist immer 0. Das Gate wertet stdout aus, nicht rc.

Hintergrund: kubectl-jsonpath kann Maps nicht iterieren. Der Feldwert ist ein
Objekt der Form
  {"cnpg-shared-6": {"ip": "...", "isPrimary": true, "timeLineID": 24}, ...}
Eine Timeline-Divergenz zwischen Instanzen ist der Vorbote genau des Schadens,
der am 23.07.2026 cnpg-shared-3 in DEV gestrandet hat: readyInstances zaehlt
eine Replica als gesund, die noch auf der alten Timeline nachspielt.
"""
import json
import sys


def main() -> None:
    if len(sys.argv) != 3:
        print("interner Aufruffehler in hg_cnpg_timeline.py")
        return

    raw, expected_raw = sys.argv[1], sys.argv[2]

    try:
        state = json.loads(raw)
    except (ValueError, TypeError) as exc:
        print(f"instancesReportedState nicht parsebar ({exc})")
        return
    if not isinstance(state, dict):
        print("instancesReportedState hat unerwarteten Typ")
        return

    try:
        expected = int(expected_raw)
    except ValueError:
        print(f"erwartete Instanzzahl unlesbar ('{expected_raw}')")
        return

    if len(state) != expected:
        melden = ", ".join(sorted(state)) or "keine"
        print(f"nur {len(state)} von {expected} Instanzen melden Status ({melden})")
        return

    primaries = sorted(k for k, v in state.items()
                       if isinstance(v, dict) and v.get("isPrimary"))
    if len(primaries) != 1:
        print(f"{len(primaries)} Primaries gemeldet ({', '.join(primaries) or 'keiner'})")
        return

    timelines = {}
    for name, info in sorted(state.items()):
        tl = info.get("timeLineID") if isinstance(info, dict) else None
        timelines.setdefault(tl, []).append(name)

    if len(timelines) != 1:
        gruppen = [
            f"TL{tl if tl is not None else '?'}={','.join(members)}"
            for tl, members in sorted(
                timelines.items(), key=lambda kv: (kv[0] is None, kv[0])
            )
        ]
        print("Timeline-Divergenz zwischen Instanzen -> " + " ".join(gruppen))
        return

    if next(iter(timelines)) is None:
        print("keine Instanz meldet eine timeLineID")
        return

    print("OK")


if __name__ == "__main__":
    main()
