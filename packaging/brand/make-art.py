r"""Generates iPASide's installer artwork from the app's own design tokens.

The PNGs this writes are committed next to it, so building the installer never needs
Python. The script exists so the art can be regenerated when the brand changes,
instead of the installer carrying unreproducible binary blobs.

Sizes come from Inno Setup 6.7's documented image areas:
  backdrop.png   WizardBackImageFile   aspect 497:360, largest area 1630x1148 (250% DPI)
  panel.png      WizardImageFile       aspect 164:314, largest area  534x1022 (250% DPI)
  logo.png       WizardSmallImageFile  square,         largest area  159x159  (250% DPI)
  bar-track.png  stand-in progress track  (see iPASide.iss)
  bar-fill.png   stand-in progress fill

Everything is drawn oversized and downsampled, so it stays sharp at 200%+ DPI.

Run:  .\.venv\Scripts\python packaging\brand\make-art.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# The app's dark palette, verbatim from src/iPASide.Flutter/lib/ui/theme/palette.dart.
# The installer is dark-only because the app's own window is what it hands over to, and
# a light installer opening a near-black app is a jarring seam.
BG = (0x0B, 0x0B, 0x0D)        # bg0, the app canvas
SURFACE = (0x12, 0x12, 0x15)   # bg1, a raised card
INDIGO = (0x66, 0x72, 0xE6)    # accentGradientStops[0]
VIOLET = (0x8C, 0x5C, 0xF0)    # accentGradientStops[1]
TEXT = (0xE9, 0xEA, 0xEE)
MUTED = (0x8B, 0x8B, 0x99)

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MARK = REPO / "src" / "iPASide.Flutter" / "assets" / "brand" / "mark.png"
FONTS = REPO / "src" / "iPASide.Flutter" / "assets" / "fonts"


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    """Inter, the same typeface the app renders in."""
    return ImageFont.truetype(str(FONTS / name), size)


def vertical_gradient(size: tuple[int, int], top: tuple, bottom: tuple) -> Image.Image:
    """Smooth two-stop vertical gradient, built one row tall then stretched."""
    width, height = size
    strip = Image.new("RGB", (1, height))
    pixels = strip.load()
    for y in range(height):
        t = y / max(1, height - 1)
        pixels[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return strip.resize((width, height), Image.BICUBIC)


def horizontal_gradient(size: tuple[int, int], left: tuple, right: tuple) -> Image.Image:
    """Smooth two-stop horizontal gradient, built one column wide then stretched."""
    width, height = size
    strip = Image.new("RGB", (width, 1))
    pixels = strip.load()
    for x in range(width):
        t = x / max(1, width - 1)
        pixels[x, 0] = tuple(round(a + (b - a) * t) for a, b in zip(left, right))
    return strip.resize((width, height), Image.BICUBIC)


def glow(base: Image.Image, center: tuple[int, int], radius: int, color: tuple, peak: int) -> None:
    """A soft radial glow, the way the app's hero card lifts off the canvas.

    The falloff is computed once in a small square and scaled up: faster than plotting
    every pixel, and smoother. BILINEAR rather than BICUBIC on the way up, because cubic
    resampling overshoots at the mask edge and leaves a faint square seam where the glow
    should already have faded to nothing.
    """
    samples = 160
    mask = Image.new("L", (samples, samples), 0)
    pixels = mask.load()
    half = samples / 2
    for y in range(samples):
        dy = (y - half + 0.5) / half
        for x in range(samples):
            dx = (x - half + 0.5) / half
            distance = (dx * dx + dy * dy) ** 0.5
            if distance < 1.0:
                pixels[x, y] = round(peak * (1.0 - distance) ** 2)
    mask = mask.resize((radius * 2, radius * 2), Image.BILINEAR)
    full = Image.new("L", base.size, 0)
    full.paste(mask, (center[0] - radius, center[1] - radius))
    base.paste(Image.new("RGB", base.size, color), (0, 0), full)


def accent_rule(width: int, height: int) -> Image.Image:
    """The indigo -> violet sweep the app uses on its primary button."""
    return horizontal_gradient((width, height), INDIGO, VIOLET).convert("RGBA")


def build_backdrop() -> Image.Image:
    """Background for every wizard page.

    Deliberately quiet: wizard text sits directly on this, so it carries two soft glows
    and nothing else. No texture or motif — the app's own surfaces are flat, and a
    patterned installer opening a flat app would not match.

    Both glows sit right of centre on purpose. On the Welcome and Finished pages the left
    third of this image is covered by panel.png, so anything placed there is never seen.
    """
    size = (1656, 1200)
    img = vertical_gradient(size, BG, (0x10, 0x10, 0x14))
    glow(img, (820, 60), 840, INDIGO, 38)
    glow(img, (1560, 1170), 700, VIOLET, 30)
    return img


def build_panel() -> Image.Image:
    """The tall left column on the Welcome and Finished pages: the brand moment."""
    size = (548, 1050)
    img = vertical_gradient(size, SURFACE, (0x09, 0x09, 0x0B))
    glow(img, (160, 130), 470, INDIGO, 86)
    glow(img, (480, 990), 440, VIOLET, 66)
    img = img.convert("RGBA")

    mark = Image.open(MARK).convert("RGBA").resize((156, 156), Image.LANCZOS)
    img.alpha_composite(mark, (74, 168))

    draw = ImageDraw.Draw(img)
    draw.text((74, 372), "iPASide", font=font("Inter-Bold.ttf", 66), fill=TEXT)
    img.alpha_composite(accent_rule(168, 4), (76, 470))
    draw.text(
        (74, 508),
        "Sideload iOS apps\nfrom Windows",
        font=font("Inter-Medium.ttf", 30),
        fill=MUTED,
        spacing=12,
    )
    draw.text((74, 962), "free & open-source", font=font("Inter-SemiBold.ttf", 30), fill=INDIGO)
    return img.convert("RGB")


def build_logo() -> Image.Image:
    """Square mark for the top-right of the inner pages; alpha is preserved."""
    return Image.open(MARK).convert("RGBA").resize((256, 256), Image.LANCZOS)


# The wizard's progress bar is a native TNewProgressBar, which exposes no colour property
# and is painted the stock green by the style. These two strips are stretched over it
# instead (see the progress-bar block in iPASide.iss): pixels are the one thing a VCL
# style cannot restyle.
def build_bar_fill() -> Image.Image:
    return horizontal_gradient((1200, 24), INDIGO, VIOLET)


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
