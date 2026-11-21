# SPDX-License-Identifier: MPL-2.0
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_store_screenshots as screenshots  # noqa: E402
import generate_apple_icons as apple_icons  # noqa: E402


def _encode_filtered_rgba_png(width, height, rgba, *, bit_depth=8, extra_chunks=()):
    """Encode an 8-bit or 16-bit RGBA PNG cycling through all 5 PNG filter types (0..4)."""
    if bit_depth == 16:
        expanded = bytearray(len(rgba) * 2)
        expanded[0::2] = rgba
        expanded[1::2] = rgba
        raw_pixels = bytes(expanded)
        bpp = 8
    else:
        raw_pixels = rgba
        bpp = 4

    row_bytes = width * bpp
    scanlines = bytearray()
    prev = bytearray(row_bytes)

    for y in range(height):
        filt = y % 5
        cur = raw_pixels[y * row_bytes : (y + 1) * row_bytes]
        scanlines.append(filt)
        if filt == 0:
            scanlines.extend(cur)
        elif filt == 1:
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                scanlines.append((cur[i] - a) & 0xFF)
        elif filt == 2:
            for i in range(row_bytes):
                scanlines.append((cur[i] - prev[i]) & 0xFF)
        elif filt == 3:
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                scanlines.append((cur[i] - ((a + b) >> 1)) & 0xFF)
        else:
            for i in range(row_bytes):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                scanlines.append((cur[i] - screenshots._paeth(a, b, c)) & 0xFF)
        prev = cur

    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, 6, 0, 0, 0)
    compressed = zlib.compress(bytes(scanlines), level=6)
    chunks = [apple_icons._png_chunk(b"IHDR", ihdr)]
    for ctype, payload in extra_chunks:
        chunks.append(apple_icons._png_chunk(ctype, payload))
    chunks.append(apple_icons._png_chunk(b"IDAT", compressed))
    chunks.append(apple_icons._png_chunk(b"IEND", b""))
    return apple_icons.PNG_SIGNATURE + b"".join(chunks)


def _synthetic_scene_rgba(width, height, variant, *, translucent_top=False):
    buf = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 4
            a = 255
            if 16 <= y < 48 and 16 <= x < 160 + variant * 16:
                r, g, b = (0xD4, 0xAC, 0x45)
            elif 64 + variant * 12 <= y < 120 + variant * 12 and 16 <= x < width - 16:
                r, g, b = (0xE9, 0xEE, 0xF2)
            else:
                r, g, b = (0x20, 0x28, 0x31)
                if translucent_top and y < 4:
                    a = 128
            buf[idx] = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = a
    return bytes(buf)


class AppStoreScreenshotsTest(unittest.TestCase):
    def test_decode_all_five_filters_with_ancillary_chunks_and_normalize_rgb(self):
        w, h = 240, 480
        rgba = _synthetic_scene_rgba(w, h, 0, translucent_top=True)
        ancillary = (
            (b"sRGB", b"\x00"),
            (b"pHYs", struct.pack(">IIB", 11811, 11811, 1)),
        )
        filtered_png = _encode_filtered_rgba_png(w, h, rgba, extra_chunks=ancillary)

        dw, dh, ctype, decoded = screenshots.decode_png_full(filtered_png)
        self.assertEqual((dw, dh, ctype), (w, h, 6))
        self.assertEqual(decoded, rgba)

        rgb_png = screenshots.normalize_png_to_app_store_rgb(filtered_png)
        nw, nh, nctype, npixels = screenshots.decode_png_full(rgb_png)
        self.assertEqual((nw, nh, nctype), (w, h, 2))
        self.assertEqual(len(npixels), w * h * 3)

    def test_decode_16bit_rgba_downsamples_to_24bit_rgb(self):
        w, h = 64, 96
        rgba = _synthetic_scene_rgba(w, h, 1)
        png16 = _encode_filtered_rgba_png(w, h, rgba, bit_depth=16)

        rgb_png = screenshots.normalize_png_to_app_store_rgb(png16)
        nw, nh, nctype, npixels = screenshots.decode_png_full(rgb_png)
        self.assertEqual((nw, nh, nctype), (w, h, 2))
        self.assertEqual(len(npixels), w * h * 3)

    def test_normalize_and_check_enforces_app_store_contracts(self):
        w, h = 240, 480
        with tempfile.TemporaryDirectory() as tmp:
            raw_dir = Path(tmp) / "raw"
            out_dir = Path(tmp) / "iphone-6.3"
            raw_dir.mkdir()
            for idx, name in enumerate(screenshots.EXPECTED_SCREENSHOTS):
                png = _encode_filtered_rgba_png(w, h, _synthetic_scene_rgba(w, h, idx))
                (raw_dir / name).write_bytes(png)

            entries = screenshots.normalize_directory(
                raw_dir,
                out_dir,
                display_class="iphone-6.3",
                accepted_sizes=((w, h),),
            )
            self.assertEqual(len(entries), 4)
            self.assertTrue(all(e["width"] == w and e["height"] == h for e in entries))

            # Reject wrong display-class dimensions when using real App Store dimensions.
            with self.assertRaisesRegex(ValueError, "not valid for iphone-6.3"):
                screenshots.check(out_dir, display_class="iphone-6.3")

            # Reject RGBA PNGs (alpha channel forbidden by App Store Connect).
            (out_dir / screenshots.EXPECTED_SCREENSHOTS[0]).write_bytes(
                (raw_dir / screenshots.EXPECTED_SCREENSHOTS[0]).read_bytes()
            )
            with self.assertRaisesRegex(ValueError, "24-bit RGB"):
                screenshots.check(
                    out_dir,
                    display_class="iphone-6.3",
                    accepted_sizes=((w, h),),
                )

            # Reject duplicate scenes.
            (out_dir / screenshots.EXPECTED_SCREENSHOTS[0]).write_bytes(
                (out_dir / screenshots.EXPECTED_SCREENSHOTS[1]).read_bytes()
            )
            with self.assertRaisesRegex(ValueError, "Duplicate screenshot"):
                screenshots.check(
                    out_dir,
                    display_class="iphone-6.3",
                    accepted_sizes=((w, h),),
                )

    def test_check_rejects_mixed_dimensions_within_display_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "iphone-6.3"
            out_dir.mkdir()
            for idx, name in enumerate(screenshots.EXPECTED_SCREENSHOTS):
                w, h = (240, 480) if idx < 3 else (256, 512)
                png = _encode_filtered_rgba_png(w, h, _synthetic_scene_rgba(w, h, idx))
                (out_dir / name).write_bytes(screenshots.normalize_png_to_app_store_rgb(png))

            with self.assertRaisesRegex(ValueError, "do not match other iphone-6.3"):
                screenshots.check(
                    out_dir,
                    display_class="iphone-6.3",
                    accepted_sizes=((240, 480), (256, 512)),
                )

    def test_select_simulators_prefers_newest_runtime_and_excludes_non_dynamic_island(self):
        simctl_payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
                    {"name": "iPhone 16", "udid": "OLD-16", "isAvailable": True},
                    {"name": "iPhone 16 Pro Max", "udid": "OLD-16PM", "isAvailable": True},
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    {"name": "iPhone 16e", "udid": "SKIP-16E", "isAvailable": True},
                    {"name": "iPhone 17", "udid": "SIM-17", "isAvailable": True},
                    {"name": "iPhone 17 Pro", "udid": "SIM-17P", "isAvailable": True},
                    {"name": "iPhone 17 Pro Max", "udid": "SIM-17PM", "isAvailable": True},
                    {"name": "iPhone 18 Pro", "udid": "UNAVAIL-18P", "isAvailable": False},
                ],
            }
        }
        selected = screenshots.select_simulators(simctl_payload)
        self.assertEqual(
            [(s["display_class"], s["name"], s["udid"], s["runtime"]) for s in selected],
            [
                ("iphone-6.3", "iPhone 17", "SIM-17", "26.5"),
                ("iphone-6.9", "iPhone 17 Pro Max", "SIM-17PM", "26.5"),
            ],
        )

    def test_select_simulators_falls_back_to_iphone_air_and_rejects_missing(self):
        simctl_payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                    {"name": "iPhone 16e", "udid": "SIM-16E", "isAvailable": True},
                    {"name": "iPhone Air", "udid": "SIM-AIR", "isAvailable": True},
                ]
            }
        }
        selected_large = screenshots.select_simulators(simctl_payload, display_classes=("iphone-6.9",))
        self.assertEqual(selected_large[0]["name"], "iPhone Air")
        self.assertEqual(selected_large[0]["udid"], "SIM-AIR")

        with self.assertRaisesRegex(ValueError, "No available iOS simulator found for iphone-6.3"):
            screenshots.select_simulators(simctl_payload, display_classes=("iphone-6.3",))

    def test_summary_markdown_formats_table_and_rejects_empty_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, "No App Store screenshot directories"):
                screenshots.format_summary_markdown(root)

            # Use real 1206x2622 dimensions on a fast small-stride check via normalize_directory.
            # Test the real format_summary_markdown path with valid 1206x2622 synthetic scenes.
            w, h = 1206, 2622
            out_dir = root / "iphone-6.3"
            out_dir.mkdir()
            row_slate = bytes([0x20, 0x28, 0x31]) * w
            row_gold = bytes([0xD4, 0xAC, 0x45]) * w
            row_light = bytes([0xE9, 0xEE, 0xF2]) * w
            for idx, name in enumerate(screenshots.EXPECTED_SCREENSHOTS):
                rows = [row_slate] * h
                for y in range(16 + idx * 16, 48 + idx * 16):
                    rows[y] = row_gold
                for y in range(120 + idx * 16, 160 + idx * 16):
                    rows[y] = row_light
                png = apple_icons.encode_png(w, h, b"".join(rows), rgba=False)
                (out_dir / name).write_bytes(png)

            md = screenshots.format_summary_markdown(root, display_classes=("iphone-6.3",))
            self.assertIn("`iphone-6.3`", md)
            self.assertIn("`1206x2622`", md)
            self.assertIn("`01-connection-setup.png`", md)
            self.assertIn("`04-diagnostics-local-test.png`", md)


if __name__ == "__main__":
    unittest.main()
