#!/usr/bin/env python3
"""Headlessly autoroute a .kicad_pcb, for a no-human-in-the-loop flow.

KiCad has no CLI autorouter — its "autorouter" is the external **FreeRouting**,
and DSN/SES only move through KiCad via the GUI or the **pcbnew Python API**. So
this must run under a pcbnew-capable Python (KiCad's own interpreter, e.g.
`/Applications/KiCad/KiCad.app/…/bin/python3` on macOS, or a full nixpkgs `kicad`
on Linux — `kicad-small` and `kicad-cli` have no bindings).

Pipeline:
  1. pcbnew `ExportSpecctraDSN`  -> board.dsn
  2. FreeRouting (headless CLI)  -> board.ses
  3. pcbnew `ImportSpecctraSES`  -> traces back into the board, then Save.

Usage: <kicad-python> autoroute.py <pcb_path> <freerouting_cmd>
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile


def main() -> int:
    pcb, freerouting = sys.argv[1], sys.argv[2]
    import pcbnew  # provided by KiCad's Python

    board = pcbnew.LoadBoard(pcb)
    work = tempfile.mkdtemp(prefix="autoroute.")
    dsn = os.path.join(work, "board.dsn")
    ses = os.path.join(work, "board.ses")

    if not pcbnew.ExportSpecctraDSN(board, dsn):
        sys.exit("autoroute: Specctra DSN export failed")

    # FreeRouting headless: -de <input.dsn> -do <output.ses>, GUI disabled,
    # single-threaded (`-mt 1`): FreeRouting warns its multi-threaded optimizer
    # is broken and can hang. The board must already have an Edge.Cuts boundary
    # (freerouting 2.1 scores NaN / routes nothing without one) — the outline
    # step runs before this. Quiet unless it fails; the java log is verbose.
    proc = subprocess.run(
        [freerouting, "-de", dsn, "-do", ses, "-gui.enabled", "false", "-mt", "1"],
        capture_output=True, text=True,
    )
    if not (os.path.exists(ses) and os.path.getsize(ses) > 0):
        sys.stderr.write(proc.stdout + proc.stderr)
        sys.exit("autoroute: FreeRouting produced no session (unroutable / failed)")

    before = len(board.GetTracks())
    if not pcbnew.ImportSpecctraSES(board, ses):
        sys.exit("autoroute: Specctra SES import failed")
    board.Save(pcb)
    print("autoroute: %s tracks -> %s after routing" % (before, len(board.GetTracks())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
