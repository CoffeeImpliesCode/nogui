#!/usr/bin/env python3
"""PPM → ASCII visualizer for the nogui render probes.

The standard way to LOOK at a rendered shot: crop a region and render the
per-pixel luma as an ASCII grid, so glyph shapes, gaps, and vertical
alignment are visible in the terminal.

Usage:
  ppm2ascii.py shot.ppm --auto [--margin 6]            # auto-crop the ink
  ppm2ascii.py shot.ppm --crop 60,150,120,190          # explicit region
  ppm2ascii.py shot.ppm --around 45,140 --size 120x48  # center + size
  ppm2ascii.py shot.ppm --auto --hi 230 --lo 140       # custom range

Cells: the luma between --lo and --hi is split into --levels bands
(default 6: " .:-=+*" from faint to solid), ' ' below --lo, '#' = solid
(band top). --step 2 halves the horizontal resolution (wider crops).
"""

import argparse
import sys

# Luminance ramp, faint → solid. The band index selects the character.
# Unicode shaded blocks are the proper per-pixel grayscale; pass
# --ramp " .:-=+*#%@" for a pure-ASCII ramp.
RAMP = " ░▒▓█"


def load(path):
    """Return (width, height, pixel_bytes) for a P6 PPM."""
    data = open(path, "rb").read()
    head, _, rest = data.partition(b"\n")
    if head not in (b"P6", b"P6\n"):
        sys.exit(f"error: {path}: not a P6 PPM (header {head!r})")
    dims = rest.split(b"\n", 1)[0]
    w, h = map(int, dims.split())
    body = rest.split(b"\n", 1)[1]
    return w, h, body


def pixel(px, w, x, y):
    i = (y * w + x) * 3
    return px[i], px[i + 1], px[i + 2]


def luma(px, w, x, y):
    r, g, b = pixel(px, w, x, y)
    return (r + g + b) // 3


def ink_bbox(px, w, h, threshold=150, step=1):
    """Bounding box of the pixels with luma >= threshold (the bright ink)."""
    xs, ys = [], []
    for y in range(0, h, step):
        for x in range(0, w, step):
            if luma(px, w, x, y) >= threshold:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def ascii_crop(px, w, h, x0, y0, x1, y1, hi=200, lo=120, step=1, numbers=True, levels=6, ramp=RAMP):
    """Render the region [x0,x1]×[y0,y1] as an ASCII grid.

    The luma range [lo, hi] is split into `levels` bands (RAMP chars,
    faint → solid); luma below lo is ' '. With levels=3 the bands are
    the old ' ' / '.' / '#'.
    """
    if x0 < 0 or y0 < 0 or x1 >= w or y1 >= h:
        sys.exit(f"error: crop {x0},{y0},{x1},{y1} outside {w}x{h}")
    levels = max(1, min(levels, len(ramp)))
    thresholds = [lo + (hi - lo) * k / (levels - 1) for k in range(levels)]
    num_w = len(str(y1)) if numbers else 0
    rows = []
    for y in range(y0, y1 + 1):
        cells = []
        for x in range(x0, x1 + 1, step):
            v = luma(px, w, x, y)
            band = 0
            for k in range(levels):
                if v >= thresholds[k]:
                    band = k
            cells.append(ramp[band])
        line = "".join(cells)
        if numbers:
            line = f"{y:>{num_w}} {line}"
        rows.append(line)
    if numbers:
        gutter = " " * (num_w + 1)
        ticks = "".join(str((x // 10) % 10) if x % 10 == 0 else " " for x in range(x0, x1 + 1, step))
        rows.insert(0, gutter + ticks)
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path")
    ap.add_argument("--crop", help="x0,y0,x1,y1 explicit region")
    ap.add_argument("--around", help="cx,cy center point")
    ap.add_argument("--size", default="120x64", help="region size (with --around)")
    ap.add_argument("--auto", action="store_true", help="auto-crop the bright ink")
    ap.add_argument("--margin", type=int, default=6, help="margin around the auto-crop")
    ap.add_argument("--hi", type=int, default=200, help="solid-ink threshold (top band)")
    ap.add_argument("--lo", type=int, default=120, help="faint/AA threshold (bottom band)")
    ap.add_argument("--ramp", default=RAMP, help="luminance characters, faint to solid")
    ap.add_argument("--levels", type=int, default=0, help="luminance bands (default: len(ramp))")
    ap.add_argument("--step", type=int, default=1, help="horizontal sampling step")
    ap.add_argument("--no-numbers", action="store_true")
    args = ap.parse_args()

    w, h, px = load(args.path)

    if args.crop:
        x0, y0, x1, y1 = map(int, args.crop.split(","))
    elif args.around:
        cx, cy = map(int, args.around.split(","))
        sw, sh = map(int, args.size.lower().split("x"))
        x0 = max(0, cx - sw // 2)
        y0 = max(0, cy - sh // 2)
        x1 = min(w - 1, x0 + sw - 1)
        y1 = min(h - 1, y0 + sh - 1)
    else:
        # Default: the --size box anchored at the ink's TOP-LEFT — the
        # first text block in the shot (centering on the whole frame's
        # ink lands on empty panel).
        bb = ink_bbox(px, w, h, threshold=args.lo)
        if bb is None:
            sys.exit("no ink found")
        sw, sh = map(int, args.size.lower().split("x"))
        x0 = max(0, bb[0] - args.margin)
        y0 = max(0, bb[1] - args.margin)
        x1 = min(w - 1, x0 + sw - 1)
        y1 = min(h - 1, y0 + sh - 1)

    levels = args.levels if args.levels > 0 else len(args.ramp)
    print(ascii_crop(px, w, h, x0, y0, x1, y1, args.hi, args.lo, args.step, not args.no_numbers, levels, args.ramp))


if __name__ == "__main__":
    main()
