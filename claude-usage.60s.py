#!/usr/bin/env python3
# <bitbar.title>Claude Usage</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>Nahuel Burdisso</bitbar.author>
# <bitbar.desc>Uso del bloque de 5h de Claude Code y gasto por skill.</bitbar.desc>
# <bitbar.dependencies>python3</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
"""SwiftBar menu bar plugin: renders the summary that usage.py computes."""

import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
USAGE = HERE / "usage.py"
MONO = "font=Menlo size=12"
DIM = f"{MONO} color=#888888"


def money(value):
    return f"${value:,.2f}"


def tokens(value):
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.1f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.0f}k"
    return str(value)


def gauge(load):
    """A five-step dial for how this block compares to the user's heavy blocks."""
    if load is None:
        return "○"
    return "○◔◑◕●"[min(4, int(load * 4))]


def line(text, *params):
    print(text + (" | " + " ".join(params) if params else ""))


def main():
    try:
        result = subprocess.run(
            [sys.executable, str(USAGE)],
            capture_output=True, text=True, timeout=120, check=True,
        )
        data = json.loads(result.stdout)
    except subprocess.CalledProcessError as error:
        line("Claude ⚠️")
        line("---")
        line("usage.py falló", DIM)
        for row in (error.stderr or "sin stderr").strip().splitlines()[-6:]:
            line(row.replace("|", "¦"), DIM)
        return
    except Exception as error:  # timeout, bad JSON, missing file
        line("Claude ⚠️")
        line("---")
        line(f"{type(error).__name__}: {error}".replace("|", "¦"), DIM)
        return

    block, week = data["block"], data["week"]
    load = block["load"]

    # The title has to be tiny: on a notched Mac the status area only spans from
    # the notch to the clock, and macOS silently drops items that no longer fit
    # rather than shrinking them. Dial plus whole dollars, nothing else.
    line(f"{gauge(load)}${block['cost']:.0f}", MONO)
    line("---")

    # --- rolling 5h block -------------------------------------------------- #
    line("Bloque de 5 h (ventana rodante)", DIM)
    line(f"  {money(block['cost'])}   {tokens(block['billable'])} facturables", MONO)
    line(f"  + {tokens(block['cache_read'])} leídos de caché", DIM)
    if block["expires_at"]:
        when = datetime.fromtimestamp(block["expires_at"]).strftime("%H:%M")
        minutes = max(0, int((block["expires_at"] - time.time()) / 60))
        line(f"  libera a las {when} (en {minutes} min)", DIM)
    if load is not None:
        line(f"  {load:.0%} de un bloque cargado tuyo ({money(block['reference_p95'])})", DIM)
        line("--Heurística: no hay límite de plan legible en", DIM)
        line("--esta máquina, así que el 100% es el percentil 95", DIM)
        line("--de tus propios bloques de 5 h de los últimos 8 días.", DIM)

    line("---")
    line("Últimos 7 días", DIM)
    line(f"  {money(week['cost'])}   {tokens(week['billable'])} facturables", MONO)
    line(f"  + {tokens(week['cache_read'])} leídos de caché", DIM)

    # --- per-skill --------------------------------------------------------- #
    line("---")
    line("Gasto por skill (7 días)", DIM)
    if not data["skills"]:
        line("  sin skills invocadas", DIM)
    width = max((len(row["skill"]) for row in data["skills"]), default=0)
    for row in data["skills"]:
        line(f"  {row['skill']:<{width}}  {money(row['cost']):>8}  {tokens(row['tokens']):>6}", MONO)

    other = data.get("unattributed")
    if other:
        line(f"  {'(sin skill)':<{width}}  {money(other['cost']):>8}  {tokens(other['tokens']):>6}", DIM)

    line("--Se cobra a una skill todo lo que el modelo hace", DIM)
    line("--desde que la invoca hasta tu siguiente mensaje.", DIM)

    line("---")
    line("Refrescar | refresh=true")
    line(f"Abrir carpeta | bash=/usr/bin/open param1={HERE} terminal=false")


if __name__ == "__main__":
    main()
