import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from subprocess import CompletedProcess

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseMetadataTests(unittest.TestCase):
    def test_ticket_verification_retries_transient_failure_without_accepting_missing_ticket(self):
        failed = CompletedProcess([], 65, stdout="Ticket lookup failed", stderr="")
        accepted = CompletedProcess([], 0, stdout="The validate action worked!", stderr="")
        with patch.object(release.subprocess, 'run', side_effect=[failed, accepted]) as command, patch.object(release.time, 'sleep'):
            self.assertTrue(release.validate_ticket(Path('/tmp/Example.app')))
            self.assertEqual(command.call_count, 2)
        with patch.object(release.subprocess, 'run', return_value=failed) as command, patch.object(release.time, 'sleep'), patch('builtins.print'):
            self.assertFalse(release.validate_ticket(Path('/tmp/Example.app')))
            self.assertEqual(command.call_count, 3)

    def test_distribution_requires_actual_signature_ticket_and_expected_team(self):
        signed = {"signing": "developer-id", "team_id": "N8384H66R9", "notarized": True}
        release.require_distribution(signed, "N8384H66R9")
        for key, value in [("signing", "ad-hoc"), ("team_id", "OTHERTEAM1"), ("notarized", False)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.require_distribution({**signed, key: value}, "N8384H66R9")
        with self.assertRaises(ValueError):
            release.require_distribution(signed, "")

    def test_signature_inspection_rejects_incomplete_developer_id_signatures(self):
        adhoc = "Signature=adhoc\nTeamIdentifier=not set\n"
        self.assertEqual(release.signature_info(adhoc), {"signing": "ad-hoc", "team_id": None})
        signed = "Authority=Developer ID Application: Example\nTeamIdentifier=N8384H66R9\nflags=0x10000(runtime)\nTimestamp=26 Oct 2026\n"
        self.assertEqual(release.signature_info(signed), {"signing": "developer-id", "team_id": "N8384H66R9"})
        for part in ["Authority=Developer ID Application: Example\n", "TeamIdentifier=N8384H66R9\n", "(runtime)", "Timestamp=26 Oct 2026\n"]:
            with self.subTest(part=part), self.assertRaises(ValueError):
                release.signature_info(signed.replace(part, ""))

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
