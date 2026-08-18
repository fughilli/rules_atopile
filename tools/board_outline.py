#!/usr/bin/env python3
"""Make an auto-placed .kicad_pcb presentable: give it a board outline + a page
that frames it, so exports aren't a near-blank A4 sheet.

atopile auto-places components at the origin and generates no board outline, so a
trivial board (e.g. examples/blinky) has (a) no Edge.Cuts edge and (b) its parts
sit at pcb (0,0) — which plots at the *top-left corner* of the default A4 sheet.
The result: `kicad-cli … export pdf` is a blank-looking page. This script, in one
pass over the KiCad S-expression:

  1. Computes the bounding box of every footprint placement.
  2. Translates all footprints (and the outline) so the board sits `margin_mm`
     inside the origin (positive coords).
  3. Sets the sheet to a tight custom `(paper "User" W H)` sized to the board.
  4. Draws an Edge.Cuts rectangle at the board edge.

`kicad-cli pcb export pdf/gerber` then frames the board on a page it fills — no
SVG round-trip or extra tools. It's a convenience for code-only boards with no
hand-drawn outline; opt in via `outline_margin_mm` on `atopile_project` (0 =
off). For a real board you'd draw your own outline in KiCad and freeze the layout.

Usage: board_outline.py <pcb_path> <margin_mm>

Idempotent: re-running removes the outline it previously added (marked with a
UUID sentinel) and re-translates from the current placement, so it's safe to run
on an already-processed board.
"""

import re
import sys

# Fixed UUID prefix marking our lines, so re-runs replace (not stack) the outline.
SENTINEL = "a70117e0-0000-4000-8000"


def _footprint_at_spans(text: str):
    """For each footprint, the (start, end, x, y, rest) of its placement `(at
    …)` — the first `(at …)` after `(footprint`. `rest` preserves an optional
    rotation so we only rewrite the x/y."""
    spans = []
    for m in re.finditer(r"\(footprint\b", text):
        at = re.search(r"\(at\s+(-?[\d.]+)\s+(-?[\d.]+)([^\)]*)\)",
                       text[m.end():m.end() + 4000])
        if at:
            s = m.end() + at.start()
            e = m.end() + at.end()
            spans.append((s, e, float(at.group(1)), float(at.group(2)), at.group(3)))
    return spans


def _outline_block(x0, y0, x1, y1) -> str:
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]
    segs = []
    for i, ((sx, sy), (ex, ey)) in enumerate(zip(pts, pts[1:])):
        segs.append(
            f'  (gr_line (start {sx:.3f} {sy:.3f}) (end {ex:.3f} {ey:.3f})\n'
            f'    (stroke (width 0.15) (type solid)) (layer "Edge.Cuts")\n'
            f'    (uuid "{SENTINEL}-00000000000{i}")\n'
            f'  )'
        )
    return "\n".join(segs)


def main() -> int:
    pcb_path, margin = sys.argv[1], float(sys.argv[2])
    text = open(pcb_path, encoding="utf-8").read()

    # Drop any outline we added before (idempotent re-runs): each of our gr_line
    # blocks is a `(gr_line … (uuid "<SENTINEL>-…") )`.
    text = re.sub(
        r"\n\s*\(gr_line\b(?:[^()]|\([^()]*\))*?" + re.escape(SENTINEL) +
        r"[^)]*\"\)\s*\)",
        "",
        text,
    )

    spans = _footprint_at_spans(text)
    if not spans:
        return 0  # nothing placed; leave the board as-is
    xs = [x for _, _, x, _, _ in spans]
    ys = [y for _, _, _, y, _ in spans]
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    dx, dy = margin - min(xs), margin - min(ys)  # move bbox min -> (margin, margin)
    W, H = bw + 2 * margin, bh + 2 * margin

    # Rewrite footprint placements back-to-front so earlier spans stay valid.
    for s, e, x, y, rest in sorted(spans, key=lambda t: t[0], reverse=True):
        text = text[:s] + f"(at {x + dx:.4f} {y + dy:.4f}{rest})" + text[e:]

    # Tight custom sheet sized to the board.
    text, n = re.subn(r'\(paper\s+"[^"]*"(?:\s+[\d.]+\s+[\d.]+)?\)',
                      f'(paper "User" {W:.3f} {H:.3f})', text, count=1)

    # Edge.Cuts rectangle just inside the sheet edge.
    inset = min(margin / 2, 0.5)
    block = _outline_block(inset, inset, W - inset, H - inset)
    idx = text.rstrip().rfind(")")  # the final closing paren of (kicad_pcb …)
    text = text[:idx] + block + "\n" + text[idx:]

    open(pcb_path, "w", encoding="utf-8").write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
