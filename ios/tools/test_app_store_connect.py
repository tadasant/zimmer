"""Tests for `app_store_connect.py export`: what is retried, and what never is.

    python3 -m unittest discover -s ios/tools

The command under test is a stand-in for `xcodebuild -exportArchive`: a Python one-liner
that prints what xcodebuild printed in a given run and exits with its code. App Store
Connect is stubbed at `_app_id` / `_build`, so nothing here needs a key or the network.
"""

from __future__ import annotations

import datetime
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import app_store_connect as asc  # noqa: E402

# What run 40583015112 printed, and its exit code.
DOWNLOAD_ERROR = "error: exportArchive Error Downloading App Information\n** EXPORT FAILED **"
SIGNING_ERROR = (
    "error: exportArchive No signing certificate \"iOS Distribution\" found\n** EXPORT FAILED **"
)
REDUNDANT = (
    "error: exportArchive ERROR ITMS-4238: \"Redundant Binary Upload. You've already uploaded "
    "a build with build number '71.1' for version number '0.1.0'.\"\n** EXPORT FAILED **"
)


class ExportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.mkdtemp()
        self.counter = os.path.join(self.dir, "attempts")
        self.export_path = os.path.join(self.dir, "export")
        for name, value in (("EXPORT_BACKOFF_SECONDS", 0), ("PREFLIGHT_BACKOFF_SECONDS", 0)):
            patcher = mock.patch.object(asc, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = mock.patch.object(asc, "Client", return_value=object())
        self.client.start()
        self.addCleanup(self.client.stop)
        self.app_id = mock.patch.object(asc, "_app_id", return_value="123")
        self.app_id.start()
        self.addCleanup(self.app_id.stop)
        self.in_asc: list[object] = []
        self.lookups = 0

        def build(_client: object, app_id: str, version: str, build: str) -> object:
            self.assertEqual((app_id, version, build), ("123", "0.1.0", "71.1"))
            self.lookups += 1
            answer = self.in_asc.pop(0) if self.in_asc else None
            if isinstance(answer, Exception):
                raise answer
            return answer

        patcher = mock.patch.object(asc, "_build", side_effect=build)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_xcodebuild(self, *results: tuple[int, str]) -> list[str]:
        """A command whose Nth run prints results[N]'s output and exits with its code."""
        script = (
            "import os, sys\n"
            f"results = {list(results)!r}\n"
            f"path = {self.counter!r}\n"
            "n = int(open(path).read()) if os.path.exists(path) else 0\n"
            "open(path, 'w').write(str(n + 1))\n"
            f"os.makedirs({self.export_path!r}, exist_ok=True)\n"
            "code, output = results[min(n, len(results) - 1)]\n"
            "print(output)\n"
            "sys.exit(code)\n"
        )
        return ["--", sys.executable, "-c", script, "-exportPath", self.export_path]

    def attempts(self) -> int:
        with open(self.counter) as handle:
            return int(handle.read())

    def run_export(self, command: list[str]) -> tuple[int, str]:
        args = SimpleNamespace(
            bundle_id="com.tadasant.zimmer",
            version="0.1.0",
            build="71.1",
            argv=command,
        )
        out = io.StringIO()
        code = 0
        with redirect_stdout(out), mock.patch.object(asc.time, "sleep"):
            try:
                asc.export(args)
            except SystemExit as error:
                code = error.code if isinstance(error.code, int) else 1
                if not isinstance(error.code, int):
                    out.write(str(error.code))
        return code, out.getvalue()

    def test_success_runs_once_and_never_asks_app_store_connect(self) -> None:
        code, _ = self.run_export(self.fake_xcodebuild((0, "** EXPORT SUCCEEDED **")))
        self.assertEqual((code, self.attempts(), self.lookups), (0, 1, 0))

    def test_the_run_40583015112_error_is_retried_and_then_succeeds(self) -> None:
        code, out = self.run_export(
            self.fake_xcodebuild((70, DOWNLOAD_ERROR), (0, "** EXPORT SUCCEEDED **"))
        )
        self.assertEqual((code, self.attempts(), self.lookups), (0, 2, 1))
        self.assertIn("::warning title=TestFlight export retried::", out)

    def test_a_signing_error_fails_on_the_first_attempt_with_xcodebuilds_code(self) -> None:
        code, out = self.run_export(self.fake_xcodebuild((70, SIGNING_ERROR), (0, "")))
        self.assertEqual((code, self.attempts(), self.lookups), (70, 1, 0))
        self.assertNotIn("retried", out)

    def test_a_transient_error_that_persists_fails_after_the_bound(self) -> None:
        code, out = self.run_export(self.fake_xcodebuild((70, DOWNLOAD_ERROR)))
        self.assertEqual((code, self.attempts()), (70, asc.EXPORT_ATTEMPTS))
        self.assertIn("::error title=TestFlight export failed 3 times::", out)

    def test_a_build_app_store_connect_already_has_is_not_uploaded_again(self) -> None:
        self.in_asc = [just_uploaded()]
        code, out = self.run_export(self.fake_xcodebuild((70, DOWNLOAD_ERROR), (0, "")))
        self.assertEqual((code, self.attempts()), (0, 1))
        self.assertIn("not uploaded again", out)

    def test_a_build_number_an_earlier_run_used_fails_even_after_a_transient_error(self) -> None:
        self.in_asc = [uploaded_minutes_ago(30)]
        code, out = self.run_export(self.fake_xcodebuild((70, DOWNLOAD_ERROR), (0, "")))
        self.assertEqual((code, self.attempts()), (1, 1))
        self.assertIn("the build number was used before", out)

    def test_redundant_upload_on_a_retry_of_an_old_build_number_fails(self) -> None:
        self.in_asc = [None, uploaded_minutes_ago(30)]
        code, out = self.run_export(self.fake_xcodebuild((70, DOWNLOAD_ERROR), (70, REDUNDANT)))
        self.assertEqual((code, self.attempts()), (1, 2))
        self.assertIn("the build number was used before", out)

    def test_a_signing_error_after_a_transient_one_fails_without_a_third_attempt(self) -> None:
        code, _ = self.run_export(
            self.fake_xcodebuild((70, DOWNLOAD_ERROR), (70, SIGNING_ERROR), (0, ""))
        )
        self.assertEqual((code, self.attempts()), (70, 2))

    def test_the_lookup_before_the_third_attempt_finds_the_build(self) -> None:
        self.in_asc = [None, just_uploaded()]
        code, _ = self.run_export(
            self.fake_xcodebuild((70, DOWNLOAD_ERROR), (70, DOWNLOAD_ERROR), (0, ""))
        )
        self.assertEqual((code, self.attempts(), self.lookups), (0, 2, 2))

    def test_a_signal_is_reported_the_way_a_shell_would(self) -> None:
        kill = "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
        command = ["--", sys.executable, "-c", kill]
        code, _ = self.run_export(command)
        self.assertEqual(code, 128 + 15)

    def test_redundant_upload_on_a_retry_means_the_earlier_attempt_landed(self) -> None:
        code, out = self.run_export(
            self.fake_xcodebuild((70, DOWNLOAD_ERROR), (70, REDUNDANT))
        )
        self.assertEqual((code, self.attempts()), (0, 2))
        self.assertIn("was uploaded by an earlier attempt", out)

    def test_redundant_upload_on_the_first_attempt_is_a_real_collision(self) -> None:
        code, _ = self.run_export(self.fake_xcodebuild((70, REDUNDANT)))
        self.assertEqual((code, self.attempts(), self.lookups), (70, 1, 0))

    def test_a_lookup_app_store_connect_cannot_answer_fails_rather_than_upload_blind(self) -> None:
        self.in_asc = [asc.TransientError("503")] * asc.PREFLIGHT_ATTEMPTS
        code, out = self.run_export(self.fake_xcodebuild((70, DOWNLOAD_ERROR), (0, "")))
        self.assertEqual((code, self.attempts()), (1, 1))
        self.assertIn("not uploading it again blind", out)

    def test_a_transient_phrase_outside_an_error_line_is_not_retried(self) -> None:
        output = "note: The request timed out. once, then recovered\n** EXPORT FAILED **"
        code, _ = self.run_export(self.fake_xcodebuild((70, output)))
        self.assertEqual((code, self.attempts()), (70, 1))

    def test_the_export_path_is_cleared_before_each_attempt(self) -> None:
        os.makedirs(self.export_path)
        stale = os.path.join(self.export_path, "DistributionSummary.plist")
        open(stale, "w").close()
        self.run_export(self.fake_xcodebuild((0, "")))
        self.assertFalse(os.path.exists(stale))


class CommandLineTest(unittest.TestCase):
    """The path `ios/bin/testflight` takes: argparse, the `--`, and the process exit code."""

    def export(self, *command: str) -> subprocess.CompletedProcess[str]:
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app_store_connect.py")
        return subprocess.run(
            [sys.executable, script, "export", "--bundle-id", "b", "--version", "0.1.0",
             "--build", "1", "--", *command],
            capture_output=True, text=True, check=False,
        )

    def test_success_and_its_output_pass_through(self) -> None:
        result = self.export(sys.executable, "-c", "print('** EXPORT SUCCEEDED **')")
        self.assertEqual(result.returncode, 0)
        self.assertIn("** EXPORT SUCCEEDED **", result.stdout)

    def test_a_signing_error_keeps_xcodebuilds_exit_code(self) -> None:
        fail = f"import sys; print({SIGNING_ERROR!r}, file=sys.stderr); sys.exit(70)"
        result = self.export(sys.executable, "-c", fail)
        self.assertEqual(result.returncode, 70)
        self.assertIn("No signing certificate", result.stdout)

    def test_no_command_is_refused(self) -> None:
        self.assertNotEqual(self.export().returncode, 0)


def just_uploaded() -> dict[str, object]:
    return uploaded_minutes_ago(0)


def uploaded_minutes_ago(minutes: int) -> dict[str, object]:
    when = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)
    stamp = when.strftime("%Y-%m-%dT%H:%M:%S.000-00:00")
    return {"attributes": {"processingState": "PROCESSING", "uploadedDate": stamp}}


if __name__ == "__main__":
    unittest.main()
