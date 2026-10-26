import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseMetadataTests(unittest.TestCase):
    def test_tag_must_match_bundle_version(self):
        self.assertEqual(release.validate_tag("0.2.3", ""), "v0.2.3")
        self.assertEqual(release.validate_tag("0.2.3", "v0.2.3"), "v0.2.3")
        self.assertEqual(release.validate_tag("1.0.0", "v1.0.0-beta.1"), "v1.0.0-beta.1")
        for tag in ["v0.2.4", "0.2.3", "../v0.2.3", "v0.2.3-01", "v0.2.3;echo bad", "v00.2.3"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag("0.2.3", tag)

    def test_changelog_extracts_only_requested_version(self):
        text = "# Updates\n\n## [1.0.0] - 2026-10-26\n\nNew release.\n\n## [0.2.3]\n\nPrevious release.\n"
        self.assertEqual(release.changelog_section(text, "1.0.0"), "New release.")
        self.assertEqual(release.changelog_section(text, "0.2.3"), "Previous release.")
        with self.assertRaises(ValueError):
            release.changelog_section(text, "0.2.4")
        with self.assertRaises(ValueError):
            release.changelog_section("## [0.2.3]\n\n## [0.2.2]\nOld", "0.2.3")


if __name__ == "__main__":
    unittest.main()
