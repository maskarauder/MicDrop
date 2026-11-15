# SPDX-License-Identifier: MPL-2.0
"""Generate and verify Google Play Store listing graphics for MicDrop.

Committed outputs under apps/android/play-store/:
- icon-512.png: 512x512 32-bit RGBA PNG (full-bleed opaque alpha=255 per Play icon spec)
- feature-graphic-1024x500.png: 1024x500 24-bit RGB PNG (no alpha channel per Play spec)
- feature-graphic-1024x500.svg: editable vector source for the feature graphic

`check` uses only the Python standard library so CI can verify committed assets on
Linux, macOS, and Windows without external rendering dependencies.
"""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as apple_icons  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PLAY_STORE_DIR = ROOT / "apps" / "android" / "play-store"
ICON_512_PNG = PLAY_STORE_DIR / "icon-512.png"
FEATURE_SVG = PLAY_STORE_DIR / "feature-graphic-1024x500.svg"
FEATURE_PNG = PLAY_STORE_DIR / "feature-graphic-1024x500.png"

MAX_ICON_BYTES = 1024 * 1024
MAX_FEATURE_BYTES = 15 * 1024 * 1024


def render_play_icon_rgba_512():
    """Render canonical 512x512 32-bit RGBA Play Store icon via 2x supersampling from 1024x1024."""
    rgb_1024 = apple_icons.render_ios_rgb_1024(1024)
    out = bytearray(512 * 512 * 4)
    src_stride = 1024 * 3
    dst_stride = 512 * 4

    for y in range(512):
        r0 = (2 * y) * src_stride
        r1 = r0 + src_stride
        dst_row = y * dst_stride
        for x in range(512):
            c0 = (2 * x) * 3
            c1 = c0 + 3
            r = (rgb_1024[r0 + c0] + rgb_1024[r0 + c1] + rgb_1024[r1 + c0] + rgb_1024[r1 + c1] + 2) // 4
            g = (rgb_1024[r0 + c0 + 1] + rgb_1024[r0 + c1 + 1] + rgb_1024[r1 + c0 + 1] + rgb_1024[r1 + c1 + 1] + 2) // 4
            b = (rgb_1024[r0 + c0 + 2] + rgb_1024[r0 + c1 + 2] + rgb_1024[r1 + c0 + 2] + rgb_1024[r1 + c1 + 2] + 2) // 4
            di = dst_row + x * 4
            out[di] = r
            out[di + 1] = g
            out[di + 2] = b
            out[di + 3] = 255
    return bytes(out)


def render_feature_png_from_svg(svg_path=FEATURE_SVG):
    """Rasterize the 1024x500 SVG at 4x via rsvg-convert and Lanczos-downsample to 24-bit RGB."""
    from PIL import Image

    svg_path = Path(svg_path)
    if not svg_path.is_file():
        raise ValueError(f"Missing feature graphic SVG: {svg_path}")

    with tempfile.TemporaryDirectory() as tmp:
        hi_png = Path(tmp) / "feature-4x.png"
        subprocess.run(
            [
                "rsvg-convert",
                "-w",
                "4096",
                "-h",
                "2000",
                "-o",
                str(hi_png),
                str(svg_path),
            ],
            check=True,
        )
        with Image.open(hi_png) as img:
            rgb_img = img.convert("RGB").resize((1024, 500), Image.Resampling.LANCZOS)
            rgb_bytes = rgb_img.tobytes()

    return apple_icons.encode_png(1024, 500, rgb_bytes, rgba=False)


def generate(icon_path=ICON_512_PNG, svg_path=FEATURE_SVG, feature_png_path=FEATURE_PNG):
    icon_path = Path(icon_path)
    icon_path.parent.mkdir(parents=True, exist_ok=True)
    icon_rgba = render_play_icon_rgba_512()
    icon_path.write_bytes(apple_icons.encode_png(512, 512, icon_rgba, rgba=True))

    feature_png_path = Path(feature_png_path)
    feature_png_path.parent.mkdir(parents=True, exist_ok=True)
    feature_png_path.write_bytes(render_feature_png_from_svg(svg_path))


def _check_svg(svg_path):
    svg_path = Path(svg_path)
    if not svg_path.is_file():
        raise ValueError(f"Missing Play Store feature SVG: {svg_path}")
    try:
        root = ET.fromstring(svg_path.read_text(encoding="utf-8"))
    except ET.ParseError as exc:
        raise ValueError(f"Invalid XML in {svg_path}: {exc}") from exc
    if root.attrib.get("width") != "1024" or root.attrib.get("height") != "500":
        raise ValueError("Feature SVG must declare width='1024' and height='500'")
    if root.attrib.get("viewBox") != "0 0 1024 500":
        raise ValueError("Feature SVG must declare viewBox='0 0 1024 500'")


def check(icon_path=ICON_512_PNG, svg_path=FEATURE_SVG, feature_png_path=FEATURE_PNG):
    icon_path = Path(icon_path)
    feature_png_path = Path(feature_png_path)

    if not icon_path.is_file():
        raise ValueError(f"Missing Play Store icon PNG: {icon_path}")
    icon_bytes = icon_path.read_bytes()
    if len(icon_bytes) > MAX_ICON_BYTES:
        raise ValueError(f"Play Store icon exceeds 1 MiB limit: {len(icon_bytes)} bytes")

    iw, ih, ictype, ipixels = apple_icons.decode_png(icon_bytes)
    if (iw, ih, ictype) != (512, 512, 6):
        raise ValueError(
            f"Play Store icon must be 512x512 32-bit RGBA (color_type=6), got {iw}x{ih} color_type={ictype}"
        )
    if any(ipixels[i] != 255 for i in range(3, len(ipixels), 4)):
        raise ValueError("Play Store icon must be full-bleed opaque (all alpha bytes == 255)")
    expected_icon = render_play_icon_rgba_512()
    if ipixels != expected_icon:
        raise ValueError("Play Store icon-512.png pixels differ from canonical generator output")

    _check_svg(svg_path)

    if not feature_png_path.is_file():
        raise ValueError(f"Missing Play Store feature graphic PNG: {feature_png_path}")
    feat_bytes = feature_png_path.read_bytes()
    if len(feat_bytes) > MAX_FEATURE_BYTES:
        raise ValueError(f"Play Store feature graphic exceeds 15 MiB limit: {len(feat_bytes)} bytes")

    fw, fh, fctype, fpixels = apple_icons.decode_png(feat_bytes)
    if (fw, fh, fctype) != (1024, 500, 2):
        raise ValueError(
            f"Play Store feature graphic must be 1024x500 24-bit RGB (color_type=2), got {fw}x{fh} color_type={fctype}"
        )

    def feat_rgb(x, y):
        idx = (y * 1024 + x) * 3
        return (fpixels[idx], fpixels[idx + 1], fpixels[idx + 2])

    # Top-left corner sits in the dark slate background.
    cr, cg, cb = feat_rgb(8, 8)
    if not (20 <= cr <= 42 and 28 <= cg <= 52 and 36 <= cb <= 62):
        raise ValueError(f"Unexpected feature graphic corner color: {(cr, cg, cb)}")

    # Center emblem capsule (786, 236) is MicDrop gold (#D4AC45).
    mr, mg, mb = feat_rgb(786, 236)
    if not (abs(mr - 0xD4) <= 6 and abs(mg - 0xAC) <= 6 and abs(mb - 0x45) <= 6):
        raise ValueError(f"Expected gold capsule at (786, 236), got {(mr, mg, mb)}")

    # Center emblem stem (786, 272) is MicDrop silver (#E9EEF2).
    sr, sg, sb = feat_rgb(786, 272)
    if not (abs(sr - 0xE9) <= 8 and abs(sg - 0xEE) <= 8 and abs(sb - 0xF2) <= 8):
        raise ValueError(f"Expected silver stand at (786, 272), got {(sr, sg, sb)}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate", help="Render Play Store 512x512 icon and 1024x500 feature graphic")
    sub.add_parser("check", help="Verify committed Play Store graphics meet spec and canonical geometry")
    args = parser.parse_args(argv)
    try:
        if args.command == "generate":
            generate()
            print(
                f"Generated {ICON_512_PNG.relative_to(ROOT)} and {FEATURE_PNG.relative_to(ROOT)}"
            )
        else:
            check()
            print(
                "Verified Play Store icon-512.png (512x512 RGBA) and feature-graphic-1024x500.png (1024x500 RGB)"
            )
    except (ValueError, OSError, subprocess.SubprocessError, zlib.error) as exc:
        sys.stderr.write(f"Play Store graphics check failed: {exc}\n")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
