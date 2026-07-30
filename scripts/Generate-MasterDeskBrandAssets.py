#!/usr/bin/env python3
"""Generate the MasterDesk runtime branding assets from the approved source PNG."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = PROJECT_ROOT / "res" / "masterdesk-source.png"

ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
TRAY_SIZES = (16, 20, 24, 32, 48, 64)


def remove_connected_black_background(source: Image.Image) -> Image.Image:
    """Remove only the dark background connected to the image edges."""

    rgb = source.convert("RGB")
    flood = rgb.copy()
    marker = (255, 0, 255)
    draw = ImageDraw.Draw(flood)
    corners = (
        (0, 0),
        (rgb.width - 1, 0),
        (0, rgb.height - 1),
        (rgb.width - 1, rgb.height - 1),
    )
    for corner in corners:
        ImageDraw.floodfill(flood, corner, marker, thresh=64)

    pixels = flood.load()
    alpha = Image.new("L", rgb.size, 255)
    alpha_pixels = alpha.load()
    for y in range(rgb.height):
        for x in range(rgb.width):
            if pixels[x, y] == marker:
                alpha_pixels[x, y] = 0

    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("The source image contains no foreground after background removal.")

    left, top, right, bottom = bbox
    content_size = max(right - left, bottom - top)
    padding = max(8, round(content_size * 0.025))
    side = content_size + padding * 2
    center_x = (left + right) / 2
    center_y = (top + bottom) / 2
    crop = (
        round(center_x - side / 2),
        round(center_y - side / 2),
        round(center_x + side / 2),
        round(center_y + side / 2),
    )

    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    source_crop = rgba.crop(
        (
            max(0, crop[0]),
            max(0, crop[1]),
            min(rgba.width, crop[2]),
            min(rgba.height, crop[3]),
        )
    )
    destination = (max(0, -crop[0]), max(0, -crop[1]))
    canvas.alpha_composite(source_crop, destination)
    return canvas


def save_png(icon: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    icon.resize((size, size), Image.Resampling.LANCZOS).save(
        path, format="PNG", optimize=True
    )


def save_ico(icon: Image.Image, path: Path, sizes: tuple[int, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    icon.resize((max(sizes), max(sizes)), Image.Resampling.LANCZOS).save(
        path,
        format="ICO",
        sizes=[(size, size) for size in sizes],
        bitmap_format="png",
    )


def load_brand_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = (
        Path(r"C:\Windows\Fonts\seguisb.ttf"),
        Path(r"C:\Windows\Fonts\segoeuib.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-SemiBold.ttf"),
    )
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


def save_wordmark(icon: Image.Image, path: Path, text_color: tuple[int, int, int]) -> None:
    scale = 2
    width, height = 600 * scale, 120 * scale
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    icon_size = 104 * scale
    icon_image = icon.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
    canvas.alpha_composite(icon_image, (8 * scale, 8 * scale))

    draw = ImageDraw.Draw(canvas)
    font = load_brand_font(60 * scale)
    text = "MasterDesk"
    text_x = 128 * scale
    text_bbox = draw.textbbox((0, 0), text, font=font)
    text_y = round((height - (text_bbox[3] - text_bbox[1])) / 2 - text_bbox[1])
    draw.text((text_x, text_y), text, font=font, fill=(*text_color, 255))

    canvas.resize((600, 120), Image.Resampling.LANCZOS).save(
        path, format="PNG", optimize=True
    )


def generate(source_path: Path) -> None:
    source = Image.open(source_path)
    icon = remove_connected_black_background(source)

    save_png(icon, PROJECT_ROOT / "res" / "icon.png", 1024)
    save_png(icon, PROJECT_ROOT / "res" / "mac-icon.png", 1024)
    save_png(icon, PROJECT_ROOT / "res" / "32x32.png", 32)
    save_png(icon, PROJECT_ROOT / "res" / "64x64.png", 64)
    save_png(icon, PROJECT_ROOT / "res" / "128x128.png", 128)
    save_png(icon, PROJECT_ROOT / "res" / "128x128@2x.png", 256)

    save_ico(icon, PROJECT_ROOT / "res" / "icon.ico", ICON_SIZES)
    save_ico(icon, PROJECT_ROOT / "res" / "tray-icon.ico", TRAY_SIZES)
    save_ico(
        icon,
        PROJECT_ROOT / "flutter" / "windows" / "runner" / "resources" / "app_icon.ico",
        ICON_SIZES,
    )

    flutter_assets = PROJECT_ROOT / "flutter" / "assets"
    save_png(icon, flutter_assets / "icon.png", 512)
    save_wordmark(icon, flutter_assets / "logo.png", (8, 31, 76))
    save_wordmark(icon, flutter_assets / "logo_light.png", (8, 31, 76))
    save_wordmark(icon, flutter_assets / "logo_dark.png", (239, 245, 255))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help="Approved square MasterDesk source PNG.",
    )
    args = parser.parse_args()
    generate(args.source.resolve())


if __name__ == "__main__":
    main()
