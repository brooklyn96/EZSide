r"""Generates EZSide's installer artwork from the app's own design tokens.

The PNGs this writes are committed next to it, so building the installer never needs
Python. The script exists so the art can be regenerated when the brand changes,
instead of the installer carrying unreproducible binary blobs.

Sizes come from Inno Setup 6.7's documented image areas:
  backdrop.png   WizardBackImageFile   aspect 497:360, largest area 1630x1148 (250% DPI)
  panel.png      WizardImageFile       aspect 164:314, largest area  534x1022 (250% DPI)
  logo.png       WizardSmallImageFile  square,         largest area  159x159  (250% DPI)
  bar-track.png  stand-in progress track  (see EZSide.iss)
  bar-fill.png   stand-in progress fill

Everything is drawn at the largest size Inno shows, so it stays sharp at 200%+ DPI.

Run:  .\.venv\Scripts\python packaging\brand\make-art.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# The wizard itself stays dark (WizardStyle=modern dark in EZSide.iss), so the backdrop
# it draws its text on is the app canvas, bg0 in src/iPASide.Flutter/lib/ui/theme/palette.dart.
# The brand panel carries the mark's own palette (packaging/brand/mark-source.svg).
# Flat colours only: no gradients, no glows.
BG = (0x0B, 0x0B, 0x0D)        # bg0, the app canvas
GROUND = (0xFF, 0xFF, 0xFF)    # white, so the mark's #E6F0FF tile still reads as a tile
NAVY = (0x0B, 0x2A, 0x5B)      # the mark's body, the wordmark
ACCENT = (0x2F, 0x7B, 0xFF)    # the mark's accent and the app's accent
LINK = (0x1F, 0x5F, 0xD6)      # accent darkened to read as small text on GROUND
MUTED = (0x4A, 0x5D, 0x7E)     # NAVY softened for the tagline

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
# The 512px master (cut from mark-source.png by packaging/make-icon.py). assets/brand/mark.png
# is only the 26px in-app copy and goes soft when scaled up to the installer art.
MARK = REPO / "docs" / "brand" / "icon.png"
FONTS = REPO / "src" / "iPASide.Flutter" / "assets" / "fonts"


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    """Inter, the same typeface the app renders in."""
    return ImageFont.truetype(str(FONTS / name), size)


def build_backdrop() -> Image.Image:
    """Background for every wizard page: the app canvas, flat.

    Wizard text sits directly on this in the dark style's light colours, so it stays
    dark and carries nothing at all.
    """
    return Image.new("RGB", (1656, 1200), BG)


def build_panel() -> Image.Image:
    """The tall left column on the Welcome and Finished pages: the brand moment."""
    img = Image.new("RGBA", (548, 1050), GROUND + (255,))

    mark = Image.open(MARK).convert("RGBA").resize((156, 156), Image.LANCZOS)
    img.alpha_composite(mark, (74, 168))

    draw = ImageDraw.Draw(img)
    draw.text((74, 372), "EZSide", font=font("Inter-Bold.ttf", 66), fill=NAVY)
    draw.rectangle((76, 470, 76 + 168 - 1, 470 + 4 - 1), fill=ACCENT)
    draw.text(
        (74, 508),
        "Sideload iOS apps\nfrom Windows",
        font=font("Inter-Medium.ttf", 30),
        fill=MUTED,
        spacing=12,
    )
    draw.text((74, 962), "free & open-source", font=font("Inter-SemiBold.ttf", 30), fill=LINK)
    return img.convert("RGB")


def build_logo() -> Image.Image:
    """Square mark for the top-right of the inner pages; alpha is preserved."""
    return Image.open(MARK).convert("RGBA").resize((256, 256), Image.LANCZOS)


# The wizard's progress bar is a native TNewProgressBar, which exposes no colour property
# and is painted the stock green by the style. These two strips are stretched over it
# instead (see the progress-bar block in EZSide.iss): pixels are the one thing a VCL
# style cannot restyle.
def build_bar_fill() -> Image.Image:
    return Image.new("RGB", (1200, 24), ACCENT)


def build_bar_track() -> Image.Image:
    return Image.new("RGB", (1200, 24), (0x1E, 0x1E, 0x24))


def main() -> None:
    for name, image in (
        ("backdrop.png", build_backdrop()),
        ("panel.png", build_panel()),
        ("logo.png", build_logo()),
        ("bar-fill.png", build_bar_fill()),
        ("bar-track.png", build_bar_track()),
    ):
        out = HERE / name
        image.save(out, "PNG", optimize=True)
        print(f"  {name:14} {image.size[0]}x{image.size[1]:<5} {out.stat().st_size / 1024:7.1f} KB")


if __name__ == "__main__":
    main()
