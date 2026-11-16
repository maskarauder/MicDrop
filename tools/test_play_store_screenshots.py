# SPDX-License-Identifier: MPL-2.0
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as apple_icons  # noqa: E402
import play_store_screenshots as screenshots  # noqa: E402


def _encode_filtered_rgba_png(width, height, rgba):
    """Encode an 8-bit RGBA PNG cycling through all 5 PNG filter types (0..4)."""
    bpp = 4
    row_bytes = width * bpp
    scanlines = bytearray()
    prev = bytearray(row_bytes)

    for y in range(height):
        filt = y % 5
        cur = rgba[y * row_bytes : (y + 1) * row_bytes]
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

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    compressed = zlib.compress(bytes(scanlines), level=6)
    return (
        apple_icons.PNG_SIGNATURE
        + apple_icons._png_chunk(b"IHDR", ihdr)
        + apple_icons._png_chunk(b"IDAT", compressed)
        + apple_icons._png_chunk(b"IEND", b"")
    )


def _synthetic_scene_rgba(width, height, variant):
    buf = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 4
            if 16 <= y < 48 and 16 <= x < 160 + variant * 16:
                r, g, b = (0xD4, 0xAC, 0x45)
            elif 64 + variant * 12 <= y < 120 + variant * 12 and 16 <= x < width - 16:
                r, g, b = (0xE9, 0xEE, 0xF2)
            else:
                r, g, b = (0x20, 0x28, 0x31)
            buf[idx] = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = 255
    return bytes(buf)


class PlayStoreScreenshotsTest(unittest.TestCase):
    def test_decode_all_five_png_filters_and_normalize_to_rgb(self):
        w, h = 360, 640
        rgba = _synthetic_scene_rgba(w, h, 0)
        filtered_png = _encode_filtered_rgba_png(w, h, rgba)

        dw, dh, ctype, decoded = screenshots.decode_png_full(filtered_png)
        self.assertEqual((dw, dh, ctype), (w, h, 6))
        self.assertEqual(decoded, rgba)

        rgb_png = screenshots.normalize_png_to_play_rgb(filtered_png)
        nw, nh, nctype, npixels = screenshots.decode_png_full(rgb_png)
        self.assertEqual((nw, nh, nctype), (w, h, 2))
        self.assertEqual(len(npixels), w * h * 3)

    def test_normalize_directory_and_check_enforces_play_rules(self):
        w, h = 360, 640
        with tempfile.TemporaryDirectory() as tmp:
            raw_dir = Path(tmp) / "raw"
            out_dir = Path(tmp) / "out"
            raw_dir.mkdir()
            for idx, name in enumerate(screenshots.EXPECTED_SCREENSHOTS):
                png = _encode_filtered_rgba_png(w, h, _synthetic_scene_rgba(w, h, idx))
                (raw_dir / name).write_bytes(png)
                screenshots_out = screenshots.normalize_png_to_play_rgb(png)
                out_dir.mkdir(exist_ok=True)
                (out_dir / name).write_bytes(screenshots_out)

            screenshots.check(out_dir, expected_size=(w, h))

            # Reject RGBA (alpha channel) PNGs.
            (out_dir / screenshots.EXPECTED_SCREENSHOTS[0]).write_bytes(
                (raw_dir / screenshots.EXPECTED_SCREENSHOTS[0]).read_bytes()
            )
            with self.assertRaisesRegex(ValueError, "24-bit RGB"):
                screenshots.check(out_dir, expected_size=(w, h))

            # Restore normalized PNG, then verify duplicate detection.
            (out_dir / screenshots.EXPECTED_SCREENSHOTS[0]).write_bytes(
                (out_dir / screenshots.EXPECTED_SCREENSHOTS[1]).read_bytes()
            )
            with self.assertRaisesRegex(ValueError, "Duplicate screenshot"):
                screenshots.check(out_dir, expected_size=(w, h))


if __name__ == "__main__":
    unittest.main()
