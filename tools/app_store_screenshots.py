# SPDX-License-Identifier: MPL-2.0
"""Select iOS Simulators, normalize, and verify Apple App Store iPhone screenshots for MicDrop.

Scenes captured per iPhone display class:
- 01-connection-setup.png
- 02-connected-audio-output.png
- 03-microphone-controls.png
- 04-diagnostics-local-test.png

Apple App Store Connect iPhone screenshot requirements enforced here:
- PNG format, strict 24-bit RGB (color_type=2, 8-bit, non-interlaced, NO alpha channel)
- <= 10 MiB per image (1..10 screenshots per display set)
- Accepted portrait pixel dimensions for each iPhone display class:
  - iphone-6.3 (iPhone with Dynamic Island, medium display — required by App Store Connect):
    1206x2622 (iPhone 17 / 17 Pro / 16 Pro) or 1179x2556 (iPhone 16 / 15 Pro / 15 / 14 Pro)
  - iphone-6.9 (iPhone with Dynamic Island, large display):
    1320x2868 (iPhone 17 Pro Max / 16 Pro Max), 1290x2796, or 1260x2736
  - iphone-6.5 (iPhone with Face ID, large display):
    1284x2778 or 1242x2688
- Non-blank rendered MicDrop dark-slate/gold/light-text UI with distinct scenes
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as apple_icons  # noqa: E402

EXPECTED_SCREENSHOTS = (
    "01-connection-setup.png",
    "02-connected-audio-output.png",
    "03-microphone-controls.png",
    "04-diagnostics-local-test.png",
)

BG_SLATE = apple_icons.BG_SLATE
MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024  # App Store Connect 10 MiB ceiling

DEFAULT_DISPLAY_CLASSES = ("iphone-6.3", "iphone-6.9")

# Official App Store Connect portrait pixel specs per iPhone display class.
DISPLAY_CLASSES = {
    "iphone-6.3": {
        "label": "iPhone with Dynamic Island (medium display, 6.3\")",
        "required": True,
        "accepted_sizes": (
            (1206, 2622),
            (1179, 2556),
        ),
        "preferred_simulators": (
            "iPhone 18 Pro",
            "iPhone 18",
            "iPhone 17",
            "iPhone 17 Pro",
            "iPhone 16 Pro",
            "iPhone 16",
            "iPhone 15 Pro",
            "iPhone 15",
            "iPhone 14 Pro",
        ),
    },
    "iphone-6.9": {
        "label": "iPhone with Dynamic Island (large display, 6.9\")",
        "required": False,
        "accepted_sizes": (
            (1320, 2868),
            (1290, 2796),
            (1260, 2736),
        ),
        "preferred_simulators": (
            "iPhone 18 Pro Max",
            "iPhone 17 Pro Max",
            "iPhone 16 Pro Max",
            "iPhone 16 Plus",
            "iPhone 15 Pro Max",
            "iPhone 15 Plus",
            "iPhone 14 Pro Max",
            "iPhone Air",
        ),
    },
    "iphone-6.5": {
        "label": "iPhone with Face ID (large display, 6.5\")",
        "required": False,
        "accepted_sizes": (
            (1284, 2778),
            (1242, 2688),
        ),
        "preferred_simulators": (
            "iPhone 14 Plus",
            "iPhone 13 Pro Max",
            "iPhone 12 Pro Max",
            "iPhone 11 Pro Max",
            "iPhone Xs Max",
        ),
    },
}

_RUNTIME_IOS_RE = re.compile(r"iOS-(\d+)-(\d+)(?:-(\d+))?")


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
    """Decode any non-interlaced 8-bit or 16-bit RGB (2) or RGBA (6) PNG (filter types 0..4).

    16-bit channels are downsampled to 8-bit by taking the high byte so App Store normalization
    handles extended-range captures uniformly. Returns (width, height, color_type, 8-bit pixels).
    """
    if not data.startswith(apple_icons.PNG_SIGNATURE):
        raise ValueError("Invalid PNG signature")

    offset = len(apple_icons.PNG_SIGNATURE)
    width = height = bit_depth = color_type = None
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
            raise ValueError(f"CRC mismatch in PNG chunk {chunk_type!r}")
        offset += length + 4

        if chunk_type == b"IHDR":
            if length != 13 or width is not None:
                raise ValueError("Invalid IHDR chunk")
            width, height, bit_depth, color_type, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if bit_depth not in (8, 16) or comp != 0 or filt != 0 or interlace != 0:
                raise ValueError(
                    f"Unsupported PNG format: bit_depth={bit_depth} comp={comp} filt={filt} interlace={interlace}"
                )
            if color_type not in (2, 6):
                raise ValueError(f"Unsupported PNG color_type={color_type}")
        elif chunk_type == b"IDAT":
            idat_parts.append(payload)
        elif chunk_type == b"IEND":
            saw_iend = True
            break

    if width is None or height is None or not saw_iend or width <= 0 or height <= 0:
        raise ValueError("Missing or invalid PNG IHDR/IEND chunk")

    channels = 4 if color_type == 6 else 3
    bytes_per_sample = bit_depth // 8
    bpp = channels * bytes_per_sample
    row_bytes = width * bpp
    raw = zlib.decompress(b"".join(idat_parts))
    expected_raw_len = height * (1 + row_bytes)
    if len(raw) != expected_raw_len:
        raise ValueError(
            f"Decompressed PNG length {len(raw)} != expected {expected_raw_len}"
        )

    out = bytearray(height * row_bytes)
    prev = bytearray(row_bytes)
    raw_view = memoryview(raw)

    for y in range(height):
        row_start = y * (1 + row_bytes)
        filt_type = raw[row_start]
        raw_row = raw_view[row_start + 1 : row_start + 1 + row_bytes]
        dst_start = y * row_bytes

        if filt_type == 0:
            cur = bytearray(raw_row)
        elif filt_type == 1:
            cur = bytearray(raw_row)
            for i in range(bpp, row_bytes):
                cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
        elif filt_type == 2:
            cur = bytearray((r + b) & 0xFF for r, b in zip(raw_row, prev))
        elif filt_type == 3:
            cur = bytearray(row_bytes)
            for i in range(bpp):
                cur[i] = (raw_row[i] + (prev[i] >> 1)) & 0xFF
            for i in range(bpp, row_bytes):
                cur[i] = (raw_row[i] + ((cur[i - bpp] + prev[i]) >> 1)) & 0xFF
        elif filt_type == 4:
            cur = bytearray(row_bytes)
            for i in range(bpp):
                cur[i] = (raw_row[i] + prev[i]) & 0xFF
            for i in range(bpp, row_bytes):
                a = cur[i - bpp]
                b = prev[i]
                c = prev[i - bpp]
                p = a + b - c
                pa = p - a if p >= a else a - p
                pb = p - b if p >= b else b - p
                pc = p - c if p >= c else c - p
                if pa <= pb and pa <= pc:
                    pred = a
                elif pb <= pc:
                    pred = b
                else:
                    pred = c
                cur[i] = (raw_row[i] + pred) & 0xFF
        else:
            raise ValueError(f"Unsupported PNG scanline filter {filt_type} at row {y}")

        out[dst_start : dst_start + row_bytes] = cur
        prev = cur

    if bit_depth == 16:
        return width, height, color_type, bytes(out[0::2])
    return width, height, color_type, bytes(out)


def rgba_to_opaque_rgb(width, height, pixels, bg=BG_SLATE):
    """Convert 8-bit RGBA pixels to 24-bit RGB, compositing any translucent pixels over bg."""
    pixel_count = width * height
    expected = pixel_count * 4
    if len(pixels) != expected:
        raise ValueError(f"Expected {expected} RGBA bytes, got {len(pixels)}")

    rgb = bytearray(pixel_count * 3)
    alphas = pixels[3::4]
    if alphas == b"\xff" * pixel_count:
        rgb[0::3] = pixels[0::4]
        rgb[1::3] = pixels[1::4]
        rgb[2::3] = pixels[2::4]
        return bytes(rgb)

    bg_r, bg_g, bg_b = bg
    for idx in range(pixel_count):
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


def normalize_png_to_app_store_rgb(png_bytes):
    """Decode a simulator RGB/RGBA PNG and re-encode as canonical 24-bit RGB PNG (no alpha)."""
    width, height, color_type, pixels = decode_png_full(png_bytes)
    if color_type == 6:
        rgb_pixels = rgba_to_opaque_rgb(width, height, pixels)
    else:
        rgb_pixels = pixels
    return apple_icons.encode_png(width, height, rgb_pixels, rgba=False)


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
    screenshots_dir,
    *,
    display_class,
    names=EXPECTED_SCREENSHOTS,
    accepted_sizes=None,
):
    """Verify a directory of App Store iPhone screenshots for one display class.

    Returns metadata dicts for each verified screenshot.
    """
    screenshots_dir = Path(screenshots_dir)
    if display_class not in DISPLAY_CLASSES:
        raise ValueError(
            f"Unknown display class {display_class!r}; expected one of {sorted(DISPLAY_CLASSES)}"
        )
    if not (1 <= len(names) <= 10):
        raise ValueError("App Store Connect requires between 1 and 10 screenshots per display size")

    allowed = (
        tuple(accepted_sizes)
        if accepted_sizes is not None
        else DISPLAY_CLASSES[display_class]["accepted_sizes"]
    )
    decoded_buffers = []
    seen_size = None
    results = []

    for name in names:
        path = screenshots_dir / name
        if not path.is_file():
            raise ValueError(f"Missing App Store screenshot: {path}")
        raw_bytes = path.read_bytes()
        if len(raw_bytes) > MAX_SCREENSHOT_BYTES:
            raise ValueError(
                f"{name} exceeds App Store Connect 10 MiB limit: {len(raw_bytes)} bytes"
            )
        w, h, color_type, pixels = decode_png_full(raw_bytes)
        if color_type != 2:
            raise ValueError(
                f"{name} must be 24-bit RGB PNG (color_type=2, no alpha), got color_type={color_type}"
            )
        if (w, h) not in allowed:
            formatted = ", ".join(f"{aw}x{ah}" for aw, ah in allowed)
            raise ValueError(
                f"{name} dimensions {w}x{h} are not valid for {display_class} (expected {formatted})"
            )
        if seen_size is None:
            seen_size = (w, h)
        elif (w, h) != seen_size:
            raise ValueError(
                f"{name} dimensions {w}x{h} do not match other {display_class} screenshots ({seen_size[0]}x{seen_size[1]})"
            )

        _check_ui_palette(name, w, h, pixels)
        decoded_buffers.append((name, pixels))
        results.append(
            {
                "display_class": display_class,
                "name": name,
                "width": w,
                "height": h,
                "bytes": len(raw_bytes),
                "sha256": hashlib.sha256(raw_bytes).hexdigest(),
            }
        )

    for i in range(len(decoded_buffers)):
        for j in range(i + 1, len(decoded_buffers)):
            if decoded_buffers[i][1] == decoded_buffers[j][1]:
                raise ValueError(
                    f"Duplicate screenshot content between {decoded_buffers[i][0]} and {decoded_buffers[j][0]}"
                )

    return results


def normalize_directory(
    raw_dir,
    out_dir,
    *,
    display_class,
    names=EXPECTED_SCREENSHOTS,
    accepted_sizes=None,
):
    """Normalize raw simulator PNGs into strict 24-bit RGB PNGs and validate App Store rules."""
    raw_dir = Path(raw_dir)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for name in names:
        src = raw_dir / name
        if not src.is_file():
            raise ValueError(f"Missing raw simulator screenshot: {src}")
        normalized = normalize_png_to_app_store_rgb(src.read_bytes())
        (out_dir / name).write_bytes(normalized)

    return check(
        out_dir,
        display_class=display_class,
        names=names,
        accepted_sizes=accepted_sizes,
    )


def select_simulators(simctl_json, display_classes=DEFAULT_DISPLAY_CLASSES):
    """Pick the best available iOS Simulator for each requested App Store display class.

    Prefers the newest installed iOS runtime, then the priority order in DISPLAY_CLASSES.
    """
    devices_by_runtime = simctl_json.get("devices", {})
    available_by_name = {}

    for runtime, devices in devices_by_runtime.items():
        match = _RUNTIME_IOS_RE.search(runtime)
        if not match:
            continue
        ver = (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))
        runtime_str = f"{ver[0]}.{ver[1]}" + (f".{ver[2]}" if ver[2] else "")
        for dev in devices:
            if not dev.get("isAvailable"):
                continue
            name = dev.get("name", "")
            udid = dev.get("udid", "")
            if not name or not udid:
                continue
            entry = (ver, runtime_str, name, udid)
            prev = available_by_name.get(name)
            if prev is None or ver > prev[0]:
                available_by_name[name] = entry

    selected = []
    for display_class in display_classes:
        if display_class not in DISPLAY_CLASSES:
            raise ValueError(
                f"Unknown display class {display_class!r}; expected one of {sorted(DISPLAY_CLASSES)}"
            )
        preferred = DISPLAY_CLASSES[display_class]["preferred_simulators"]
        candidates = []
        for rank, sim_name in enumerate(preferred):
            entry = available_by_name.get(sim_name)
            if entry is not None:
                ver, runtime_str, name, udid = entry
                candidates.append((ver, -rank, runtime_str, name, udid))
        if not candidates:
            available_names = sorted(n for n in available_by_name if n.startswith("iPhone"))
            raise ValueError(
                f"No available iOS simulator found for {display_class} "
                f"(wanted one of {', '.join(preferred)}; found {', '.join(available_names) or 'none'})"
            )
        candidates.sort(reverse=True)
        _, _, runtime_str, name, udid = candidates[0]
        selected.append(
            {
                "display_class": display_class,
                "label": DISPLAY_CLASSES[display_class]["label"],
                "name": name,
                "runtime": runtime_str,
                "udid": udid,
            }
        )
    return selected


def format_summary_markdown(root_dir, display_classes=DEFAULT_DISPLAY_CLASSES, names=EXPECTED_SCREENSHOTS):
    """Build a GitHub Step Summary Markdown table from verified screenshot directories."""
    root_dir = Path(root_dir)
    lines = [
        "### iPhone App Store Screenshots (24-bit RGB PNG, no alpha)",
        "",
        "| Display Class | App Store Slot | File | Dimensions | Size | SHA-256 |",
        "| :--- | :--- | :--- | :--- | ---: | :--- |",
    ]
    found_any = False
    for display_class in display_classes:
        subdir = root_dir / display_class
        if not subdir.is_dir():
            continue
        found_any = True
        entries = check(subdir, display_class=display_class, names=names)
        slot = DISPLAY_CLASSES[display_class]["label"]
        for entry in entries:
            size_kib = f"{entry['bytes'] / 1024:.1f} KiB"
            short_sha = entry["sha256"][:12]
            lines.append(
                f"| `{display_class}` | {slot} | `{entry['name']}` "
                f"| `{entry['width']}x{entry['height']}` | {size_kib} | `{short_sha}` |"
            )
    if not found_any:
        raise ValueError(f"No App Store screenshot directories found under {root_dir}")
    return "\n".join(lines) + "\n"


def _parse_display_classes(value):
    if value == "all":
        return list(DEFAULT_DISPLAY_CLASSES)
    parts = [part.strip() for part in value.replace(",", " ").split() if part.strip()]
    if not parts:
        raise ValueError("At least one display class is required")
    for part in parts:
        if part not in DISPLAY_CLASSES:
            raise ValueError(
                f"Unknown display class {part!r}; expected 'all' or one of {sorted(DISPLAY_CLASSES)}"
            )
    return parts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    norm_parser = sub.add_parser(
        "normalize",
        help="Convert raw simulator PNGs into verified 24-bit RGB App Store PNGs",
    )
    norm_parser.add_argument("raw_dir", type=Path, help="Directory containing raw simulator PNGs")
    norm_parser.add_argument("out_dir", type=Path, help="Destination directory for normalized 24-bit RGB PNGs")
    norm_parser.add_argument(
        "--display-class",
        required=True,
        choices=sorted(DISPLAY_CLASSES),
        help="Target App Store iPhone display class",
    )

    check_parser = sub.add_parser(
        "check",
        help="Verify App Store iPhone screenshots meet Apple format, size, and UI contracts",
    )
    check_parser.add_argument("screenshots_dir", type=Path, help="Directory containing normalized PNGs")
    check_parser.add_argument(
        "--display-class",
        required=True,
        choices=sorted(DISPLAY_CLASSES),
        help="Target App Store iPhone display class",
    )

    select_parser = sub.add_parser(
        "select-simulators",
        help="Select available iOS Simulators from `xcrun simctl list devices available -j` on stdin",
    )
    select_parser.add_argument(
        "--display-classes",
        default="all",
        help="Comma/space-separated display classes or 'all' (default: iphone-6.3, iphone-6.9)",
    )
    select_parser.add_argument(
        "--format",
        choices=("tsv", "json"),
        default="tsv",
        help="Output format (default: tsv: display_class<TAB>udid<TAB>name<TAB>runtime)",
    )

    summary_parser = sub.add_parser(
        "summary",
        help="Emit a Markdown summary table of verified App Store screenshots under root_dir",
    )
    summary_parser.add_argument("root_dir", type=Path, help="Directory containing <display-class> subdirectories")
    summary_parser.add_argument(
        "--display-classes",
        default="all",
        help="Comma/space-separated display classes or 'all'",
    )

    args = parser.parse_args(argv)
    try:
        if args.command == "normalize":
            entries = normalize_directory(args.raw_dir, args.out_dir, display_class=args.display_class)
            dims = f"{entries[0]['width']}x{entries[0]['height']}"
            print(
                f"Normalized and verified {len(entries)} App Store {args.display_class} screenshots "
                f"({dims}, 24-bit RGB) in {args.out_dir}"
            )
        elif args.command == "check":
            entries = check(args.screenshots_dir, display_class=args.display_class)
            dims = f"{entries[0]['width']}x{entries[0]['height']}"
            print(
                f"Verified {len(entries)} App Store {args.display_class} 24-bit RGB screenshots ({dims})"
            )
        elif args.command == "select-simulators":
            classes = _parse_display_classes(args.display_classes)
            selected = select_simulators(json.load(sys.stdin), display_classes=classes)
            if args.format == "json":
                print(json.dumps(selected, indent=2))
            else:
                for item in selected:
                    print(f"{item['display_class']}\t{item['udid']}\t{item['name']}\t{item['runtime']}")
        elif args.command == "summary":
            classes = _parse_display_classes(args.display_classes)
            sys.stdout.write(format_summary_markdown(args.root_dir, display_classes=classes))
    except (ValueError, OSError, zlib.error, json.JSONDecodeError) as exc:
        sys.stderr.write(f"App Store screenshots failed: {exc}\n")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
