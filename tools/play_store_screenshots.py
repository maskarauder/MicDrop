# SPDX-License-Identifier: MPL-2.0
"""Normalize and verify Google Play Store phone screenshots for MicDrop.

Committed outputs under apps/android/play-store/screenshots/:
- 01-connection-setup.png
- 02-connected-audio-output.png
- 03-microphone-controls.png
- 04-diagnostics-local-test.png

Google Play Console phone screenshot requirements enforced here:
- PNG format, 24-bit RGB (color_type=2, no alpha channel)
- <= 8 MiB per image
- 9:16 portrait aspect ratio at 1080x1920 (each side within 320..3840 px)
- Non-blank rendered MicDrop slate/gold/light-text UI with distinct scenes
"""

import argparse
from pathlib import Path
import struct
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as apple_icons  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOTS_DIR = ROOT / "apps" / "android" / "play-store" / "screenshots"

EXPECTED_SCREENSHOTS = (
    "01-connection-setup.png",
    "02-connected-audio-output.png",
    "03-microphone-controls.png",
    "04-diagnostics-local-test.png",
)

EXPECTED_WIDTH = 1080
EXPECTED_HEIGHT = 1920
MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024
BG_SLATE = apple_icons.BG_SLATE


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png_full(data):
    """Pure-stdlib PNG decoder supporting 8-bit RGB (2) and RGBA (6) across PNG filters 0..4."""
    if not data.startswith(apple_icons.PNG_SIGNATURE):
        raise ValueError("Invalid PNG signature")
    offset = len(apple_icons.PNG_SIGNATURE)
    width = height = color_type = None
    idat_parts = []

    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Truncated PNG chunk header")
        length, chunk_type = struct.unpack(">I4s", data[offset : offset + 8])
        offset += 8
        if offset + length + 4 > len(data):
            raise ValueError(f"Truncated PNG chunk {chunk_type!r}")
        payload = data[offset : offset + length]
        expected_crc = struct.unpack(">I", data[offset + length : offset + length + 4])[0]
        actual_crc = zlib.crc32(payload, zlib.crc32(chunk_type)) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(f"CRC mismatch in PNG chunk {chunk_type!r}")
        offset += length + 4

        if chunk_type == b"IHDR":
            if length != 13:
                raise ValueError("Invalid IHDR length")
            width, height, bit_depth, color_type, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if bit_depth != 8 or comp != 0 or filt != 0 or interlace != 0:
                raise ValueError(
                    f"Unsupported PNG format: bit_depth={bit_depth} interlace={interlace}"
                )
            if color_type not in (2, 6):
                raise ValueError(f"Unsupported PNG color_type={color_type}")
        elif chunk_type == b"IDAT":
            idat_parts.append(payload)
        elif chunk_type == b"IEND":
            break

    if width is None or height is None or width <= 0 or height <= 0:
        raise ValueError("Missing or invalid IHDR chunk")

    bpp = 4 if color_type == 6 else 3
    row_bytes = width * bpp
    raw = zlib.decompress(b"".join(idat_parts))
    expected_raw_len = height * (1 + row_bytes)
    if len(raw) != expected_raw_len:
        raise ValueError(
            f"Decompressed PNG length {len(raw)} != expected {expected_raw_len}"
        )

    out = bytearray(height * row_bytes)
    prev = bytearray(row_bytes)

    for y in range(height):
        row_start = y * (1 + row_bytes)
        filt_type = raw[row_start]
        raw_row = memoryview(raw)[row_start + 1 : row_start + 1 + row_bytes]
        dst_start = y * row_bytes

        if filt_type == 0:
            cur = bytearray(raw_row)
        elif filt_type == 1:
            cur = bytearray(row_bytes)
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                cur[i] = (raw_row[i] + a) & 0xFF
        elif filt_type == 2:
            cur = bytearray((r + b) & 0xFF for r, b in zip(raw_row, prev))
        elif filt_type == 3:
            cur = bytearray(row_bytes)
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                cur[i] = (raw_row[i] + ((a + b) >> 1)) & 0xFF
        elif filt_type == 4:
            cur = bytearray(row_bytes)
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                cur[i] = (raw_row[i] + _paeth(a, b, c)) & 0xFF
        else:
            raise ValueError(f"Unsupported PNG scanline filter {filt_type} at row {y}")

        out[dst_start : dst_start + row_bytes] = cur
        prev = cur

    return width, height, color_type, bytes(out)


def rgba_to_opaque_rgb(width, height, pixels, bg=BG_SLATE):
    """Convert 8-bit RGBA pixels to 24-bit RGB, compositing any translucent pixels over bg."""
    expected = width * height * 4
    if len(pixels) != expected:
        raise ValueError(f"Expected {expected} RGBA bytes, got {len(pixels)}")

    rgb = bytearray(width * height * 3)
    alphas = pixels[3::4]
    if all(a == 255 for a in alphas):
        rgb[0::3] = pixels[0::4]
        rgb[1::3] = pixels[1::4]
        rgb[2::3] = pixels[2::4]
        return bytes(rgb)

    bg_r, bg_g, bg_b = bg
    for idx in range(width * height):
        si = idx * 4
        di = idx * 3
        a = pixels[si + 3]
        if a == 255:
            rgb[di] = pixels[si]
            rgb[di + 1] = pixels[si + 1]
            rgb[di + 2] = pixels[si + 2]
        elif a == 0:
            rgb[di] = bg_r
            rgb[di + 1] = bg_g
            rgb[di + 2] = bg_b
        else:
            inv = 255 - a
            rgb[di] = (pixels[si] * a + bg_r * inv + 127) // 255
            rgb[di + 1] = (pixels[si + 1] * a + bg_g * inv + 127) // 255
            rgb[di + 2] = (pixels[si + 2] * a + bg_b * inv + 127) // 255
    return bytes(rgb)


def normalize_png_to_play_rgb(png_bytes):
    """Decode an RGB or RGBA PNG (any filter 0..4) and re-encode as canonical 24-bit RGB PNG."""
    width, height, color_type, pixels = decode_png_full(png_bytes)
    if color_type == 6:
        rgb_pixels = rgba_to_opaque_rgb(width, height, pixels)
    else:
        rgb_pixels = pixels
    return apple_icons.encode_png(width, height, rgb_pixels, rgba=False)


def normalize_directory(raw_dir, out_dir=SCREENSHOTS_DIR, names=EXPECTED_SCREENSHOTS):
    raw_dir = Path(raw_dir)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for name in names:
        src = raw_dir / name
        if not src.is_file():
            raise ValueError(f"Missing raw emulator screenshot: {src}")
        normalized = normalize_png_to_play_rgb(src.read_bytes())
        (out_dir / name).write_bytes(normalized)

    check(out_dir, names=names)


def _check_ui_palette(name, width, height, rgb_pixels):
    stride = 8
    total = 0
    slate_count = 0
    gold_count = 0
    light_text_count = 0

    row_stride = width * 3
    for y in range(0, height, stride):
        row = y * row_stride
        for x in range(0, width, stride):
            idx = row + x * 3
            r = rgb_pixels[idx]
            g = rgb_pixels[idx + 1]
            b = rgb_pixels[idx + 2]
            total += 1
            if 20 <= r <= 56 and 28 <= g <= 68 and 36 <= b <= 82:
                slate_count += 1
            if abs(r - 0xD4) <= 28 and abs(g - 0xAC) <= 28 and abs(b - 0x45) <= 28:
                gold_count += 1
            if r >= 170 and g >= 175 and b >= 180:
                light_text_count += 1

    if slate_count < total * 0.30:
        raise ValueError(
            f"{name}: expected MicDrop dark slate background (>=30% sampled pixels), got {slate_count}/{total}"
        )
    if gold_count < 15:
        raise ValueError(
            f"{name}: expected MicDrop gold accent controls/headers, found only {gold_count} sampled pixels"
        )
    if light_text_count < 30:
        raise ValueError(
            f"{name}: expected readable light UI text, found only {light_text_count} sampled pixels"
        )


def check(
    screenshots_dir=SCREENSHOTS_DIR,
    *,
    names=EXPECTED_SCREENSHOTS,
    expected_size=(EXPECTED_WIDTH, EXPECTED_HEIGHT),
):
    screenshots_dir = Path(screenshots_dir)
    if len(names) < 2 or len(names) > 8:
        raise ValueError("Google Play requires between 2 and 8 phone screenshots")

    exp_w, exp_h = expected_size
    decoded_buffers = []

    for name in names:
        path = screenshots_dir / name
        if not path.is_file():
            raise ValueError(f"Missing Play Store phone screenshot: {path}")
        raw_bytes = path.read_bytes()
        if len(raw_bytes) > MAX_SCREENSHOT_BYTES:
            raise ValueError(
                f"{name} exceeds Google Play 8 MiB limit: {len(raw_bytes)} bytes"
            )
        w, h, color_type, pixels = decode_png_full(raw_bytes)
        if color_type != 2:
            raise ValueError(
                f"{name} must be 24-bit RGB PNG (color_type=2, no alpha), got color_type={color_type}"
            )
        if (w, h) != (exp_w, exp_h):
            raise ValueError(f"{name} must be {exp_w}x{exp_h}, got {w}x{h}")
        if min(w, h) < 320 or max(w, h) > 3840:
            raise ValueError(f"{name} dimensions {w}x{h} outside Play Store 320..3840 px bounds")
        if max(w, h) > 2 * min(w, h):
            raise ValueError(f"{name} aspect ratio {w}x{h} exceeds Play Store 2:1 limit")

        _check_ui_palette(name, w, h, pixels)
        decoded_buffers.append((name, pixels))

    for i in range(len(decoded_buffers)):
        for j in range(i + 1, len(decoded_buffers)):
            if decoded_buffers[i][1] == decoded_buffers[j][1]:
                raise ValueError(
                    f"Duplicate screenshot content between {decoded_buffers[i][0]} and {decoded_buffers[j][0]}"
                )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    norm_parser = sub.add_parser(
        "normalize",
        help="Convert raw RGBA emulator screencap PNGs into verified 24-bit RGB Play Store PNGs",
    )
    norm_parser.add_argument("raw_dir", type=Path, help="Directory containing raw screencap PNGs")
    norm_parser.add_argument(
        "out_dir",
        type=Path,
        nargs="?",
        default=SCREENSHOTS_DIR,
        help="Destination directory for normalized 24-bit RGB PNGs",
    )

    check_parser = sub.add_parser(
        "check",
        help="Verify Play Store phone screenshots meet Google Play format, size, and UI contracts",
    )
    check_parser.add_argument(
        "screenshots_dir",
        type=Path,
        nargs="?",
        default=SCREENSHOTS_DIR,
        help="Directory containing Play Store phone screenshots",
    )

    args = parser.parse_args(argv)
    try:
        if args.command == "normalize":
            normalize_directory(args.raw_dir, args.out_dir)
            print(f"Normalized and verified {len(EXPECTED_SCREENSHOTS)} Play Store screenshots in {args.out_dir}")
        else:
            check(args.screenshots_dir)
            print(
                f"Verified {len(EXPECTED_SCREENSHOTS)} Play Store 24-bit RGB phone screenshots ({EXPECTED_WIDTH}x{EXPECTED_HEIGHT})"
            )
    except (ValueError, OSError, zlib.error) as exc:
        sys.stderr.write(f"Play Store screenshots check failed: {exc}\n")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
