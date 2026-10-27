"""Build the iPASide icon set from the approved brand artwork.

The artwork is used exactly as approved: the tile is cropped out of the source
render and given clean alpha via a rounded-rectangle mask matched to its own
corner radius. The mask is supersampled and inset a hair so none of the source's
dark backdrop survives in the antialiased edge, which would otherwise show as a
grey fringe on light surfaces.

It also cuts the app's UI artwork at the exact sizes the UI draws, one set per
logical size and per device pixel ratio. That matters: handing Flutter the 512px
master and asking it to shrink it at run time produced visibly stair-stepped
corners on the 96px hero mark, because the image decoder's scaler is cruder than
Lanczos. Scaling here instead means Flutter only ever draws these 1:1.

Usage:
    python packaging/make-icon.py <source.png> <out.ico> [<master.png>] [<ui-dir>]
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# Icon sizes Windows picks between (taskbar, alt-tab, explorer, tiles).
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

BACKDROP_MAX = 45      # the source sits on a near-black backdrop
BACKDROP_SPREAD = 14   # ...which is neutral, unlike the blue-violet tile
EDGE_INSET = 2.0       # trims the source's antialiased edge
MASK_SUPERSAMPLE = 4


def _tile_bounds(img: Image.Image) -> tuple[int, int, int, int]:
    """Bounding box of the artwork tile within its backdrop."""
    px = img.convert("RGB").load()
    width, height = img.size

    def is_backdrop(c: tuple[int, int, int]) -> bool:
        return max(c) < BACKDROP_MAX and abs(c[0] - c[2]) < BACKDROP_SPREAD

    left, right, top, bottom = width, 0, height, 0
    for y in range(height):
        for x in range(width):
            if not is_backdrop(px[x, y]):
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
    return left, top, right, bottom


def _corner_radius(img: Image.Image, bounds: tuple[int, int, int, int]) -> float:
    """Corner radius, read off the straight run along the tile's top edge."""
    left, top, right, _ = bounds
    px = img.convert("RGB").load()

    def is_backdrop(c: tuple[int, int, int]) -> bool:
        return max(c) < BACKDROP_MAX and abs(c[0] - c[2]) < BACKDROP_SPREAD

    row = [x for x in range(left, right + 1) if not is_backdrop(px[x, top])]
    if not row:
        return (right - left) * 0.21
    return ((row[0] - left) + (right - row[-1])) / 2


def extract_master(source: Path) -> Image.Image:
    """Crop the tile and give it clean, fringe-free alpha."""
    img = Image.open(source).convert("RGB")
    left, top, right, bottom = _tile_bounds(img)
    radius = _corner_radius(img, (left, top, right, bottom))

    tile = img.crop((left, top, right + 1, bottom + 1))
    size = tile.size[0]

    scale = MASK_SUPERSAMPLE
    mask = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [
            EDGE_INSET * scale,
            EDGE_INSET * scale,
            (size - EDGE_INSET) * scale - 1,
            (size - EDGE_INSET) * scale - 1,
        ],
        radius=(radius - EDGE_INSET) * scale,
        fill=255,
    )
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)

    master = tile.convert("RGBA")
    master.putalpha(mask)
    return master


def write_ui_variants(master: Image.Image, out_dir: Path) -> None:
    """Cuts the mark at each logical size the UI uses, for each pixel ratio.

    Flutter finds `2.0x/name.png` beside `name.png` on its own and picks by device
    pixel ratio, so the widget never scales anything: it draws the variant 1:1. The
    1.5x set is included because 125% and 150% Windows scaling are commonplace, and
    without it those machines would fall back to the 2x art and shrink it.
    """
    # Keep in step with LogoMark's `_variants` map.
    LOGICAL = {"mark": 26, "mark-hero": 96}
    RATIOS = {"": 1.0, "1.5x": 1.5, "2.0x": 2.0, "3.0x": 3.0}

    for name, logical in LOGICAL.items():
        for folder, ratio in RATIOS.items():
            pixels = round(logical * ratio)
            target = out_dir / folder / f"{name}.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
                target, format="PNG", optimize=True
            )
            size_kb = target.stat().st_size / 1024
            label = f"{folder}/{name}.png" if folder else f"{name}.png"
            print(f"wrote {label:24s} {pixels}x{pixels}  {size_kb:5.1f} KB")


def main() -> int:
    source = Path(sys.argv[1])
    ico_path = Path(sys.argv[2])
    master_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    ui_dir = Path(sys.argv[4]) if len(sys.argv) > 4 else None

    master = extract_master(source)
    frames = [master.resize((n, n), Image.Resampling.LANCZOS) for n in SIZES]
    frames[-1].save(
        ico_path,
        format="ICO",
        sizes=[(n, n) for n in SIZES],
        append_images=frames[:-1],
    )
    print(f"wrote {ico_path} from {source.name} ({master.size[0]}px master)")

    if master_path is not None:
        master.resize((512, 512), Image.Resampling.LANCZOS).save(master_path, format="PNG")
        print(f"wrote {master_path} (512x512)")

    if ui_dir is not None:
        write_ui_variants(master, ui_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
