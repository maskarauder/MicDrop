# SPDX-License-Identifier: MPL-2.0
"""Verify Play Store 512x512 icon and 1024x500 feature graphic constraints."""

from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_apple_icons as apple_icons  # noqa: E402
import play_store_graphics as psg  # noqa: E402


class PlayStoreGraphicsTests(unittest.TestCase):
    def test_committed_assets_pass_check_and_landmarks(self):
        psg.check()

        iw, ih, ictype, ipixels = apple_icons.decode_png(psg.ICON_512_PNG.read_bytes())
        self.assertEqual((iw, ih, ictype), (512, 512, 6))

        def icon_rgba(x, y):
            idx = (y * 512 + x) * 4
            return (ipixels[idx], ipixels[idx + 1], ipixels[idx + 2], ipixels[idx + 3])

        self.assertEqual(icon_rgba(4, 4), (*apple_icons.BG_SLATE, 255))
        self.assertEqual(icon_rgba(100, 256), (*apple_icons.BADGE_SLATE, 255))
        self.assertEqual(icon_rgba(256, 190), (*apple_icons.GOLD_MIC, 255))
        self.assertEqual(icon_rgba(256, 360), (*apple_icons.SILVER_STAND, 255))

        fw, fh, fctype, _ = apple_icons.decode_png(psg.FEATURE_PNG.read_bytes())
        self.assertEqual((fw, fh, fctype), (1024, 500, 2))

    def test_rejects_transparent_icon_or_rgba_feature_graphic(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            icon_png = base / "icon-512.png"
            feat_svg = base / "feature-graphic-1024x500.svg"
            feat_png = base / "feature-graphic-1024x500.png"
            shutil.copyfile(psg.ICON_512_PNG, icon_png)
            shutil.copyfile(psg.FEATURE_SVG, feat_svg)
            shutil.copyfile(psg.FEATURE_PNG, feat_png)

            # Non-opaque pixel in 512x512 icon must be rejected.
            _, _, _, good_rgba = apple_icons.decode_png(icon_png.read_bytes())
            bad_rgba = bytearray(good_rgba)
            bad_rgba[3] = 0
            icon_png.write_bytes(apple_icons.encode_png(512, 512, bytes(bad_rgba), rgba=True))
            with self.assertRaisesRegex(ValueError, "full-bleed opaque"):
                psg.check(icon_path=icon_png, svg_path=feat_svg, feature_png_path=feat_png)

            # RGBA feature graphic must be rejected (Play Console forbids alpha on feature graphic).
            shutil.copyfile(psg.ICON_512_PNG, icon_png)
            rgba_feat = apple_icons.encode_png(1024, 500, bytes([255] * (1024 * 500 * 4)), rgba=True)
            feat_png.write_bytes(rgba_feat)
            with self.assertRaisesRegex(ValueError, "1024x500 24-bit RGB"):
                psg.check(icon_path=icon_png, svg_path=feat_svg, feature_png_path=feat_png)


if __name__ == "__main__":
    unittest.main()
