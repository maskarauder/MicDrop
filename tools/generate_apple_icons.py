# SPDX-License-Identifier: MPL-2.0
"""Generate and verify deterministic iOS and macOS app icons from the MicDrop mark.

Matches the slate-and-gold microphone geometry in
apps/android/app/src/main/res/drawable/ic_launcher_{background,foreground}.xml:
- Outer slate background: #202831
- Inner badge circle: #2A3541 (radius 30 in 72x72 visible viewport)
- Gold capsule: #D4AC45 (pill from (12, 5) to (12, 11), radius 3 in 24x24 Material grid)
- Silver stand: #E9EEF2 (lower half-ring r in [5, 7] around (12, 11) + stem [11..13]x[17..21])
"""

import argparse
import json
import math
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]

IOS_XCASSETS_DIR = ROOT / "apps" / "ios" / "MicDrop" / "Assets.xcassets"
IOS_APPICONSET_DIR = IOS_XCASSETS_DIR / "AppIcon.appiconset"
IOS_ICON_PNG = IOS_APPICONSET_DIR / "AppIcon.png"
MACOS_ICON_ICNS = ROOT / "apps" / "windows-host" / "resources" / "AppIcon.icns"

BG_SLATE = (0x20, 0x28, 0x31)
BADGE_SLATE = (0x2A, 0x35, 0x41)
GOLD_MIC = (0xD4, 0xAC, 0x45)
SILVER_STAND = (0xE9, 0xEE, 0xF2)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Standard macOS .icns PNG chunk types in ascending size order.
ICNS_SPECS = (
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
)

XCASSETS_ROOT_JSON = (
    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
)

APPICONSET_JSON = (
    json.dumps(
        {
            "images": [
                {
                    "filename": "AppIcon.png",
                    "idiom": "universal",
                    "platform": "ios",
                    "size": "1024x1024",
                }
            ],
            "info": {"author": "xcode", "version": 1},
        },
        indent=2,
    )
    + "\n"
)


def _smooth_coverage(signed_distance_px):
    if signed_distance_px <= -0.5:
        return 1.0
    if signed_distance_px >= 0.5:
        return 0.0
    t = 0.5 - signed_distance_px
    return t * t * (3.0 - 2.0 * t)


def _blend_rgb(dst, src, cov):
    inv = 1.0 - cov
    return (
        dst[0] * inv + src[0] * cov,
        dst[1] * inv + src[1] * cov,
        dst[2] * inv + src[2] * cov,
    )


def _mic_art_rgb(vx, vy, px_per_vp):
    """Evaluate the anti-aliased RGB color at Android 108x108 viewport point (vx, vy)."""
    color = (float(BG_SLATE[0]), float(BG_SLATE[1]), float(BG_SLATE[2]))

    # Inner badge circle centered at (54, 54), radius 30 in viewport units.
    sd_circle_px = (math.hypot(vx - 54.0, vy - 54.0) - 30.0) * px_per_vp
    cov_circle = _smooth_coverage(sd_circle_px)
    if cov_circle <= 0.0:
        return (BG_SLATE[0], BG_SLATE[1], BG_SLATE[2])
    if cov_circle >= 1.0:
        color = (float(BADGE_SLATE[0]), float(BADGE_SLATE[1]), float(BADGE_SLATE[2]))
    else:
        color = _blend_rgb(color, BADGE_SLATE, cov_circle)

    # Foreground group: translate(30, 30) scale(2.0) of 24x24 Material grid.
    mx = (vx - 30.0) * 0.5
    my = (vy - 30.0) * 0.5
    px_per_mat = px_per_vp * 2.0
    dx = abs(mx - 12.0)

    # Gold capsule: vertical pill from (12, 5) to (12, 11), radius 3.0.
    if dx <= 3.6 and 1.4 <= my <= 14.6:
        cy = 5.0 if my < 5.0 else (11.0 if my > 11.0 else my)
        sd_cap_px = (math.hypot(dx, my - cy) - 3.0) * px_per_mat
        cov_cap = _smooth_coverage(sd_cap_px)
        if cov_cap > 0.0:
            color = _blend_rgb(color, GOLD_MIC, cov_cap)

    # Silver stand: union of lower half-ring (center (12, 11), r in [5, 7], y >= 11)
    # and stem box (x in [11, 13], y in [16.5, 21]).
    if dx <= 7.6 and 10.4 <= my <= 21.6:
        dy = my - 11.0
        if dy < 0.0:
            clamped_x = 5.0 if dx < 5.0 else (7.0 if dx > 7.0 else dx)
            sd_ring = math.hypot(dx - clamped_x, dy)
        else:
            r = math.hypot(dx, dy)
            sd_ring = max(abs(r - 6.0) - 1.0, -dy)

        bx = dx - 1.0
        by = abs(my - 18.75) - 2.25
        sd_stem = math.hypot(max(bx, 0.0), max(by, 0.0)) + min(max(bx, by), 0.0)

        sd_stand_px = min(sd_ring, sd_stem) * px_per_mat
        cov_stand = _smooth_coverage(sd_stand_px)
        if cov_stand > 0.0:
            color = _blend_rgb(color, SILVER_STAND, cov_stand)

    return (
        int(color[0] + 0.5),
        int(color[1] + 0.5),
        int(color[2] + 0.5),
    )


def render_ios_rgb_1024(size=1024):
    """Render an opaque 24-bit RGB icon mapping the 72x72 visible viewport onto size x size."""
    if size <= 0 or size % 2 != 0:
        raise ValueError("size must be a positive even integer")
    half = size // 2
    px_per_vp = size / 72.0
    inv_scale = 72.0 / size

    out = bytearray(size * size * 3)
    row_stride = size * 3

    for y in range(size):
        vy = 18.0 + (y + 0.5) * inv_scale
        row_offset = y * row_stride
        for x in range(half):
            vx = 18.0 + (x + 0.5) * inv_scale
            r, g, b = _mic_art_rgb(vx, vy, px_per_vp)
            left = row_offset + x * 3
            right = row_offset + (size - 1 - x) * 3
            out[left] = r
            out[left + 1] = g
            out[left + 2] = b
            out[right] = r
            out[right + 1] = g
            out[right + 2] = b
    return bytes(out)


def render_macos_rgba_1024(size=1024):
    """Render a macOS 1024x1024 RGBA icon: 824x824 rounded rect on a transparent canvas."""
    if size <= 0 or size % 2 != 0:
        raise ValueError("size must be a positive even integer")
    half = size // 2
    body_size = size * (824.0 / 1024.0)
    half_body = body_size * 0.5
    corner_radius = body_size * (185.4 / 824.0)
    inner_half = half_body - corner_radius
    margin = (size - body_size) * 0.5

    px_per_vp = body_size / 72.0
    inv_scale = 72.0 / body_size

    out = bytearray(size * size * 4)
    row_stride = size * 4
    center = size * 0.5

    for y in range(size):
        ay = abs((y + 0.5) - center)
        if ay >= half_body + 1.0:
            continue
        vy = 18.0 + ((y + 0.5) - margin) * inv_scale
        qy = ay - inner_half
        row_offset = y * row_stride
        for x in range(half):
            ax = abs((x + 0.5) - center)
            if ax >= half_body + 1.0:
                continue
            qx = ax - inner_half
            sd_mask = (
                math.hypot(max(qx, 0.0), max(qy, 0.0))
                + min(max(qx, qy), 0.0)
                - corner_radius
            )
            alpha_cov = _smooth_coverage(sd_mask)
            if alpha_cov <= 0.0:
                continue
            vx = 18.0 + ((x + 0.5) - margin) * inv_scale
            r, g, b = _mic_art_rgb(vx, vy, px_per_vp)
            a = int(alpha_cov * 255.0 + 0.5)
            if a <= 0:
                continue
            left = row_offset + x * 4
            right = row_offset + (size - 1 - x) * 4
            out[left] = r
            out[left + 1] = g
            out[left + 2] = b
            out[left + 3] = a
            out[right] = r
            out[right + 1] = g
            out[right + 2] = b
            out[right + 3] = a
    return bytes(out)


def downsample_rgba_2x(rgba, size):
    """Downsample a size x size straight-RGBA buffer by 2x using premultiplied box filtering."""
    if size < 2 or size % 2 != 0:
        raise ValueError("size must be an even integer >= 2")
    half = size // 2
    out = bytearray(half * half * 4)
    src_stride = size * 4
    dst_stride = half * 4

    for y in range(half):
        r0 = (2 * y) * src_stride
        r1 = r0 + src_stride
        dst_row = y * dst_stride
        for x in range(half):
            c0 = (2 * x) * 4
            c1 = c0 + 4

            a00 = rgba[r0 + c0 + 3]
            a01 = rgba[r0 + c1 + 3]
            a10 = rgba[r1 + c0 + 3]
            a11 = rgba[r1 + c1 + 3]
            a_sum = a00 + a01 + a10 + a11
            if a_sum == 0:
                continue

            pr = (
                rgba[r0 + c0] * a00
                + rgba[r0 + c1] * a01
                + rgba[r1 + c0] * a10
                + rgba[r1 + c1] * a11
            )
            pg = (
                rgba[r0 + c0 + 1] * a00
                + rgba[r0 + c1 + 1] * a01
                + rgba[r1 + c0 + 1] * a10
                + rgba[r1 + c1 + 1] * a11
            )
            pb = (
                rgba[r0 + c0 + 2] * a00
                + rgba[r0 + c1 + 2] * a01
                + rgba[r1 + c0 + 2] * a10
                + rgba[r1 + c1 + 2] * a11
            )

            di = dst_row + x * 4
            out[di] = min(255, (pr + (a_sum // 2)) // a_sum)
            out[di + 1] = min(255, (pg + (a_sum // 2)) // a_sum)
            out[di + 2] = min(255, (pb + (a_sum // 2)) // a_sum)
            out[di + 3] = (a_sum + 2) // 4
    return bytes(out)


def _png_chunk(chunk_type, payload):
    crc = zlib.crc32(chunk_type)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", crc)


def encode_png(width, height, pixels, *, rgba):
    channels = 4 if rgba else 3
    color_type = 6 if rgba else 2
    row_bytes = width * channels
    if len(pixels) != height * row_bytes:
        raise ValueError("Pixel buffer size does not match dimensions")

    scanlines = bytearray(height * (1 + row_bytes))
    for y in range(height):
        dst = y * (1 + row_bytes)
        src = y * row_bytes
        scanlines[dst] = 0  # Filter type 0 (None)
        scanlines[dst + 1 : dst + 1 + row_bytes] = pixels[src : src + row_bytes]

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    compressed = zlib.compress(bytes(scanlines), level=9)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def decode_png(data):
    """Minimal pure-stdlib PNG decoder supporting filter-0 8-bit RGB (2) and RGBA (6) PNGs."""
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Invalid PNG signature")
    offset = len(PNG_SIGNATURE)
    ihdr = None
    idat_parts = []
    saw_iend = False

    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Truncated PNG chunk header")
        length, chunk_type = struct.unpack_from(">I4s", data, offset)
        offset += 8
        if offset + length + 4 > len(data):
            raise ValueError(f"Truncated PNG chunk {chunk_type!r}")
        payload = data[offset : offset + length]
        expected_crc = struct.unpack_from(">I", data, offset + length)[0]
        actual_crc = zlib.crc32(payload, zlib.crc32(chunk_type)) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(f"PNG CRC mismatch in {chunk_type!r}")
        offset += length + 4

        if chunk_type == b"IHDR":
            if length != 13 or ihdr is not None:
                raise ValueError("Malformed PNG IHDR")
            ihdr = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            idat_parts.append(payload)
        elif chunk_type == b"IEND":
            saw_iend = True
            break

    if ihdr is None or not saw_iend or offset != len(data):
        raise ValueError("Incomplete or trailing PNG data")
    width, height, bit_depth, color_type, comp, filt, interlace = ihdr
    if bit_depth != 8 or color_type not in (2, 6) or comp != 0 or filt != 0 or interlace != 0:
        raise ValueError(f"Unsupported PNG format: depth={bit_depth}, color_type={color_type}")

    channels = 4 if color_type == 6 else 3
    row_bytes = width * channels
    raw = zlib.decompress(b"".join(idat_parts))
    if len(raw) != height * (1 + row_bytes):
        raise ValueError("Decompressed PNG scanline length mismatch")

    pixels = bytearray(height * row_bytes)
    for y in range(height):
        src = y * (1 + row_bytes)
        if raw[src] != 0:
            raise ValueError(f"Unsupported PNG row filter {raw[src]} at row {y}")
        dst = y * row_bytes
        pixels[dst : dst + row_bytes] = raw[src + 1 : src + 1 + row_bytes]
    return width, height, color_type, bytes(pixels)


def build_macos_icns_frames():
    rgba_1024 = render_macos_rgba_1024(1024)
    by_size = {1024: rgba_1024}
    current = rgba_1024
    for sz in (512, 256, 128, 64, 32):
        current = downsample_rgba_2x(current, sz * 2)
        by_size[sz] = current
    return by_size


def encode_icns(frames_by_size):
    chunks = []
    for ostype, sz in ICNS_SPECS:
        png = encode_png(sz, sz, frames_by_size[sz], rgba=True)
        chunks.append(ostype + struct.pack(">I", 8 + len(png)) + png)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def decode_icns(data):
    if len(data) < 8 or data[:4] != b"icns":
        raise ValueError("Invalid .icns header")
    total_len = struct.unpack_from(">I", data, 4)[0]
    if total_len != len(data):
        raise ValueError(f".icns length header {total_len} != actual {len(data)}")
    offset = 8
    entries = []
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Truncated .icns element header")
        ostype = data[offset : offset + 4]
        elem_len = struct.unpack_from(">I", data, offset + 4)[0]
        if elem_len < 8 or offset + elem_len > len(data):
            raise ValueError(f"Malformed .icns element {ostype!r}")
        entries.append((ostype, data[offset + 8 : offset + elem_len]))
        offset += elem_len
    return entries


def generate(ios_png_path=IOS_ICON_PNG, macos_icns_path=MACOS_ICON_ICNS, write_xcassets=True):
    ios_rgb = render_ios_rgb_1024(1024)
    ios_png = encode_png(1024, 1024, ios_rgb, rgba=False)

    ios_png_path = Path(ios_png_path)
    ios_png_path.parent.mkdir(parents=True, exist_ok=True)
    ios_png_path.write_bytes(ios_png)

    if write_xcassets:
        xcassets_root = ios_png_path.parent.parent
        (xcassets_root / "Contents.json").write_text(XCASSETS_ROOT_JSON, encoding="utf-8")
        (ios_png_path.parent / "Contents.json").write_text(APPICONSET_JSON, encoding="utf-8")

    macos_frames = build_macos_icns_frames()
    icns_bytes = encode_icns(macos_frames)
    macos_icns_path = Path(macos_icns_path)
    macos_icns_path.parent.mkdir(parents=True, exist_ok=True)
    macos_icns_path.write_bytes(icns_bytes)


def check(ios_png_path=IOS_ICON_PNG, macos_icns_path=MACOS_ICON_ICNS, check_xcassets=True):
    ios_png_path = Path(ios_png_path)
    macos_icns_path = Path(macos_icns_path)
    if not ios_png_path.is_file():
        raise ValueError(f"Missing iOS AppIcon PNG: {ios_png_path}")
    if not macos_icns_path.is_file():
        raise ValueError(f"Missing macOS AppIcon.icns: {macos_icns_path}")

    if check_xcassets:
        xcassets_root = ios_png_path.parent.parent
        root_contents = xcassets_root / "Contents.json"
        set_contents = ios_png_path.parent / "Contents.json"
        if not root_contents.is_file() or root_contents.read_text(encoding="utf-8") != XCASSETS_ROOT_JSON:
            raise ValueError(f"{root_contents} does not match expected Assets.xcassets Contents.json")
        if not set_contents.is_file() or set_contents.read_text(encoding="utf-8") != APPICONSET_JSON:
            raise ValueError(f"{set_contents} does not match expected AppIcon.appiconset Contents.json")

    w, h, ctype, ios_pixels = decode_png(ios_png_path.read_bytes())
    if (w, h, ctype) != (1024, 1024, 2):
        raise ValueError(
            f"iOS AppIcon.png must be 1024x1024 24-bit RGB (color_type=2), got {w}x{h} color_type={ctype}"
        )
    expected_ios = render_ios_rgb_1024(1024)
    if ios_pixels != expected_ios:
        raise ValueError("iOS AppIcon.png pixels differ from canonical generator output")

    entries = decode_icns(macos_icns_path.read_bytes())
    expected_types = [spec[0] for spec in ICNS_SPECS]
    actual_types = [entry[0] for entry in entries]
    if actual_types != expected_types:
        raise ValueError(f"AppIcon.icns chunk types {actual_types} != expected {expected_types}")

    expected_frames = build_macos_icns_frames()
    for (ostype, png_bytes), (_, expected_sz) in zip(entries, ICNS_SPECS):
        fw, fh, fctype, fpixels = decode_png(png_bytes)
        if (fw, fh, fctype) != (expected_sz, expected_sz, 6):
            raise ValueError(
                f"AppIcon.icns {ostype.decode()} must be {expected_sz}x{expected_sz} RGBA, got {fw}x{fh} type={fctype}"
            )
        if fpixels != expected_frames[expected_sz]:
            raise ValueError(f"AppIcon.icns {ostype.decode()} pixels differ from canonical generator output")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate", help="Write committed iOS Assets.xcassets and macOS AppIcon.icns")
    sub.add_parser("check", help="Verify committed iOS and macOS icon assets match the canonical mark")
    args = parser.parse_args(argv)
    try:
        if args.command == "generate":
            generate()
            print(f"Generated {IOS_ICON_PNG.relative_to(ROOT)} and {MACOS_ICON_ICNS.relative_to(ROOT)}")
        else:
            check()
            print("Verified iOS AppIcon.png (1024x1024 RGB) and macOS AppIcon.icns")
    except (ValueError, OSError, zlib.error) as exc:
        sys.stderr.write(f"Apple icon check failed: {exc}\n")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
