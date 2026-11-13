# SPDX-License-Identifier: MPL-2.0
"""Verify deterministic Apple icon generation, RGB/RGBA constraints, and .icns structure."""

from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as icons  # noqa: E402


class AppleIconGeneratorTests(unittest.TestCase):
    def test_committed_assets_pass_check_and_pixel_landmarks(self):
        icons.check()

        w, h, ctype, rgb = icons.decode_png(icons.IOS_ICON_PNG.read_bytes())
        self.assertEqual((w, h, ctype), (1024, 1024, 2))

        def rgb_at(x, y):
            idx = (y * 1024 + x) * 3
            return (rgb[idx], rgb[idx + 1], rgb[idx + 2])

        self.assertEqual(rgb_at(5, 5), icons.BG_SLATE)
        self.assertEqual(rgb_at(200, 512), icons.BADGE_SLATE)
        self.assertEqual(rgb_at(512, 380), icons.GOLD_MIC)
        self.assertEqual(rgb_at(512, 720), icons.SILVER_STAND)

        entries = icons.decode_icns(icons.MACOS_ICON_ICNS.read_bytes())
        self.assertEqual([e[0] for e in entries], [spec[0] for spec in icons.ICNS_SPECS])
        ic10_png = dict(entries)[b"ic10"]
        mw, mh, mctype, rgba = icons.decode_png(ic10_png)
        self.assertEqual((mw, mh, mctype), (1024, 1024, 6))
        # Outer canvas corner is fully transparent per macOS HIG.
        self.assertEqual(rgba[3], 0)
        # Center of microphone capsule is fully opaque gold.
        center_idx = (380 * 1024 + 512) * 4
        self.assertEqual(
            (rgba[center_idx], rgba[center_idx + 1], rgba[center_idx + 2], rgba[center_idx + 3]),
            (*icons.GOLD_MIC, 255),
        )

    def test_rejects_rgba_ios_icon_or_tampered_icns(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            xc = base / "Assets.xcassets" / "AppIcon.appiconset"
            xc.mkdir(parents=True)
            shutil.copyfile(icons.IOS_XCASSETS_DIR / "Contents.json", xc.parent / "Contents.json")
            shutil.copyfile(icons.IOS_APPICONSET_DIR / "Contents.json", xc / "Contents.json")
            ios_png = xc / "AppIcon.png"
            icns_path = base / "AppIcon.icns"
            shutil.copyfile(icons.MACOS_ICON_ICNS, icns_path)

            # RGBA iOS icon must be rejected (App Store Connect ITMS-90717).
            rgba_png = icons.encode_png(64, 64, bytes(64 * 64 * 4), rgba=True)
            ios_png.write_bytes(rgba_png)
            with self.assertRaisesRegex(ValueError, "1024x1024 24-bit RGB"):
                icons.check(ios_png_path=ios_png, macos_icns_path=icns_path)

            # Wrong pixel color in 1024x1024 RGB iOS icon must be rejected.
            shutil.copyfile(icons.IOS_ICON_PNG, ios_png)
            w, h, _, good_rgb = icons.decode_png(ios_png.read_bytes())
            tampered = bytearray(good_rgb)
            tampered[0] ^= 0xFF
            ios_png.write_bytes(icons.encode_png(w, h, bytes(tampered), rgba=False))
            with self.assertRaisesRegex(ValueError, "differ from canonical"):
                icons.check(ios_png_path=ios_png, macos_icns_path=icns_path)

            # Truncated .icns must be rejected.
            shutil.copyfile(icons.IOS_ICON_PNG, ios_png)
            icns_path.write_bytes(b"icns\x00\x00\x00\x10bad")
            with self.assertRaisesRegex(ValueError, "icns"):
                icons.check(ios_png_path=ios_png, macos_icns_path=icns_path)


if __name__ == "__main__":
    unittest.main()
