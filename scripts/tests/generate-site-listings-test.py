#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

scripts_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(scripts_dir))

spec = importlib.util.spec_from_file_location(
    "generate_site_listings", scripts_dir / "generate-site-listings.py"
)
generate_site_listings = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = generate_site_listings
spec.loader.exec_module(generate_site_listings)


class SiteListingFormatTests(unittest.TestCase):
    def test_file_sizes_scale_and_localize_units(self):
        self.assertEqual(
            generate_site_listings.fmt_size(1023),
            '<span data-zh="1023 字节" data-en="1023 B">1023 字节</span>',
        )
        self.assertEqual(
            generate_site_listings.fmt_size(1024),
            '<span data-zh="1.0 千字节" data-en="1.0 KiB">1.0 千字节</span>',
        )
        self.assertEqual(
            generate_site_listings.fmt_size(1024**2),
            '<span data-zh="1.0 兆字节" data-en="1.0 MiB">1.0 兆字节</span>',
        )

    def test_dates_use_localized_formats_and_keep_local_time(self):
        local_time = SimpleNamespace(
            tm_year=2026,
            tm_mon=10,
            tm_mday=11,
            tm_hour=19,
            tm_min=7,
            tm_sec=24,
            tm_wday=6,
        )
        with patch("generate_site_listings.time.localtime", return_value=local_time):
            self.assertEqual(
                generate_site_listings.fmt_date(0),
                '<span data-zh="2026年10月11日 19:07:24" '
                'data-en="Sun, Oct 11, 2026, 7:07:24 PM">'
                "2026年10月11日 19:07:24</span>",
            )

    def test_generated_listing_includes_bilingual_size_and_date(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            public_dir = Path(temp_dir)
            file_path = public_dir / "firmware.bin"
            file_path.write_bytes(b"x" * 2048)
            os.utime(file_path, (1791745644, 1791745644))

            generate_site_listings.generate_tree(
                public_dir,
                dry_run=False,
                quiet=True,
                skip_paths=(),
                landing_paths=(),
            )
            generated_html = (public_dir / "index.html").read_text(encoding="utf-8")

            self.assertIn(generate_site_listings.fmt_size(2048), generated_html)
            self.assertIn(
                generate_site_listings.fmt_date(file_path.stat().st_mtime),
                generated_html,
            )

    def test_nested_readmes_generate_their_own_listing_pages_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            public_dir = Path(temp_dir)
            readmes = {
                "assets/manual": "Manual directory README",
                "assets/site": "Site assets README",
            }
            for relative_dir, content in readmes.items():
                readme_path = public_dir / relative_dir / "README.md"
                readme_path.parent.mkdir(parents=True)
                readme_path.write_text(content, encoding="utf-8")

            generate_site_listings.generate_tree(
                public_dir,
                dry_run=False,
                quiet=True,
                skip_paths=generate_site_listings.DEFAULT_SKIP_PATHS,
                landing_paths=(),
            )

            for relative_dir, content in readmes.items():
                generated_html = (
                    public_dir / relative_dir / "index.html"
                ).read_text(encoding="utf-8")
                self.assertIn('data-readme-src="./README.md"', generated_html)
                self.assertIn(content, generated_html)


if __name__ == "__main__":
    unittest.main()
