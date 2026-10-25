#!/usr/bin/env python3
# Generates the environment map at shaders/sky.ppm from a sky and ground gradient.
# Copyright (c) 2026 Janis Gertulla
# SPDX-License-Identifier: MIT

from pathlib import Path

WIDTH = 512
HEIGHT = 256
MAXVAL = 255


def main() -> None:
    output = Path(__file__).resolve().parents[1] / "shaders" / "sky.ppm"
    with output.open("wb") as image:
        image.write(f"P6\n{WIDTH} {HEIGHT}\n{MAXVAL}\n".encode("ascii"))
        for y in range(HEIGHT):
            if y < HEIGHT // 2:
                start, end = (32, 80, 160), (180, 210, 235)
                step = y
            else:
                start, end = (65, 60, 50), (15, 20, 25)
                step = y - HEIGHT // 2
            span = HEIGHT // 2 - 1
            pixel = bytes(
                (a * (span - step) + b * step + span // 2) // span
                for a, b in zip(start, end)
            )
            image.write(pixel * WIDTH)
    print(f"{output}: {output.stat().st_size} bytes (P6, {WIDTH}x{HEIGHT}, {MAXVAL})")


if __name__ == "__main__":
    main()
