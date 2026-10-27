#!/usr/bin/env python3
"""Ask App Store Connect about Zimmer's app record and its builds.

Three jobs, all done for `ios/bin/testflight upload`:

* ``preflight`` — does an app record exist for the bundle id, and does the key work? Asked
  *before* a ten-minute archive, because both answers are otherwise discovered at the very
  end, by the upload failing.
* ``wait`` — has the build just uploaded finished processing? An upload that Xcode reports
  as successful can still fail processing (a missing icon, an invalid binary), and until it
  is ``VALID`` nobody can install it. "The upload step went green" is not the claim this
  pipeline exists to make.
* ``export`` — run ``xcodebuild -exportArchive`` (the command after ``--``), and run it again,
  a bounded number of times with backoff, only when it failed with an error App Store Connect
  is known to give transiently. Before every retry it asks App Store Connect whether the build
  is already there, so a retry never uploads one build number twice.

Stdlib only, plus the ``openssl`` binary for the ES256 signature, so it runs on a
GitHub-hosted macOS runner with no ``pip install`` and no third-party code handed the key.

The key is read from the path in ``APP_STORE_CONNECT_API_KEY_PATH``. Nothing this script
writes contains the key, the signed token, or any header.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import http.client
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API = "https://api.appstoreconnect.apple.com"
TOKEN_LIFETIME_SECONDS = 15 * 60  # Apple refuses anything over 20 minutes.
POLL_SECONDS = 30
# App Store Connect occasionally times out a single read, so the pre-archive check is asked
# this many times, sleeping PREFLIGHT_BACKOFF_SECONDS, then twice that, between attempts:
# 105 seconds of sleeping, about four minutes in all with each attempt's request timeout.
PREFLIGHT_ATTEMPTS = 4
PREFLIGHT_BACKOFF_SECONDS = 15
# `xcodebuild -exportArchive` is run at most this many times, sleeping EXPORT_BACKOFF_SECONDS,
# then twice that, between attempts, and only after an error in EXPORT_TRANSIENT_ERRORS.
EXPORT_ATTEMPTS = 3
EXPORT_BACKOFF_SECONDS = 30
# Matched against xcodebuild's `error:` lines only. Each is App Store Connect or the network failing
# to answer, never a verdict on the build or the key: a refused key, an unsigned agreement or a
# signing error reads differently and fails on the first attempt. Run 40583015112 is the
# worked example of the first: "error: exportArchive Error Downloading App Information", gone
# on a re-run. A cause that is not transient after all still fails, EXPORT_ATTEMPTS later.
EXPORT_TRANSIENT_ERRORS = (
    "Error Downloading App Information",
    "The request timed out.",
    "The network connection was lost.",
    "Could not connect to the server.",
)
# What the upload service answers, in an `error:` line, when the build number is already
# there: the altool wording, then the App Store Connect API wording newer Xcodes print. After a
# transient failure it can mean the failed attempt had in fact been accepted; on a first
# attempt it is a genuine build-number collision.
REDUNDANT_UPLOAD = (
    "Redundant Binary Upload",
    "ITMS-4238",
    "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
)
# A build App Store Connect lists that was uploaded more than this long before `export` began
# is not this run's: it is an earlier upload that used the same build number. The slack is
# for the runner's clock against Apple's.
CLOCK_SLACK = datetime.timedelta(minutes=2)


class TransientError(Exception):
    """A failure worth asking again about: the network, a timeout, a 429 or a 5xx."""


def _say(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw_signature(der: bytes) -> bytes:
    """OpenSSL emits an ECDSA signature as DER; a JWS wants r || s, 32 bytes each."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("unexpected signature encoding")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("unexpected signature encoding")
        length = der[index + 1]
        value = der[index + 2 : index + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("unexpected signature length")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


def _token(key_id: str, issuer_id: str, key_path: str) -> str:
    now = int(time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = _b64url(
        json.dumps(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + TOKEN_LIFETIME_SECONDS,
                "aud": "appstoreconnect-v1",
            }
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode()
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        # openssl's stderr names the file and the parse error, never the key material.
        reason = result.stderr.decode().strip()
        raise SystemExit(f"could not sign with the App Store Connect key: {reason}")
    return f"{header}.{claims}.{_b64url(_der_to_raw_signature(result.stdout))}"


class Client:
    def __init__(self) -> None:
        names = (
            "APP_STORE_CONNECT_API_KEY_ID",
            "APP_STORE_CONNECT_API_ISSUER_ID",
            "APP_STORE_CONNECT_API_KEY_PATH",
        )
        missing = [name for name in names if not os.environ.get(name)]
        if missing:
            raise SystemExit(f"missing environment: {', '.join(missing)}")
        self._key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
        self._issuer_id = os.environ["APP_STORE_CONNECT_API_ISSUER_ID"]
        self._key_path = os.environ["APP_STORE_CONNECT_API_KEY_PATH"]

    def get(self, path: str, query: dict[str, str]) -> dict[str, Any]:
        url = f"{API}{path}?{urllib.parse.urlencode(query)}"
        token = _token(self._key_id, self._issuer_id, self._key_path)
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                try:
                    body: dict[str, Any] = json.load(response)
                except json.JSONDecodeError as error:
                    # A 200 whose body was cut off, or an edge's HTML page.
                    raise TransientError(f"{path}: unreadable answer ({error})") from None
                return body
        except urllib.error.HTTPError as error:
            detail = _error_detail(error)
            if error.code == 429 or error.code >= 500:
                raise TransientError(f"{error.code} for {path}. {detail}") from None
            if error.code == 401:
                raise SystemExit(
                    "App Store Connect refused the key (401). Check that "
                    "APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID belong to "
                    "the .p8 in APP_STORE_CONNECT_API_KEY_P8, and that the key has not been "
                    f"revoked. {detail}"
                ) from None
            if error.code == 403:
                raise SystemExit(
                    "App Store Connect answered 403: the key works but may not do this, or an "
                    f"agreement is waiting in App Store Connect → Business. {detail}"
                ) from None
            raise SystemExit(
                f"App Store Connect answered {error.code} for {path}. {detail}"
            ) from None
        except (OSError, http.client.HTTPException) as error:
            # After HTTPError, which is itself an OSError. OSError covers URLError, a timeout
            # on any Python 3 (socket.timeout before 3.10), a reset and an SSL EOF;
            # HTTPException covers an IncompleteRead or a BadStatusLine.
            raise TransientError(f"{path}: {error}") from None


def _error_detail(error: urllib.error.HTTPError) -> str:
    try:
        body = json.load(error)
        return "; ".join(
            f"{e.get('title', '')}: {e.get('detail', '')}" for e in body.get("errors", [])
        )
    except Exception:  # noqa: BLE001 — a body we cannot read is not worth a second failure.
        return ""


def _app_id(client: Client, bundle_id: str) -> str:
    # `filter[bundleId]` also matches ids the value is a prefix of, so compare exactly.
    body = client.get(
        "/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name", "limit": "200"}
    )
    for app in body.get("data", []):
        if app.get("attributes", {}).get("bundleId") == bundle_id:
            name = app["attributes"].get("name", "")
            _say(f"app record: {name!r} ({bundle_id}, id {app['id']})")
            return str(app["id"])
    raise SystemExit(
        f"no App Store Connect app record for {bundle_id}. Create it first: App Store Connect "
        f"→ Apps → + → New App, with bundle id {bundle_id} (ios/README.md, 'Distribution')."
    )


def _build(client: Client, app_id: str, version: str, build: str) -> dict[str, Any] | None:
    body = client.get(
        "/v1/builds",
        {
            "filter[app]": app_id,
            "filter[version]": build,
            "filter[preReleaseVersion.version]": version,
            "fields[builds]": "version,processingState,uploadedDate,expired",
            "limit": "1",
        },
    )
    builds = body.get("data", [])
    return builds[0] if builds else None


def _asked(question: Any, what: str) -> Any:
    """``question()``, asked again after a TransientError with the preflight's backoff. A
    SystemExit (a refused key, a missing record) is raised from the first attempt."""
    delay = PREFLIGHT_BACKOFF_SECONDS
    for attempt in range(1, PREFLIGHT_ATTEMPTS + 1):
        try:
            return question()
        except TransientError as error:
            if attempt == PREFLIGHT_ATTEMPTS:
                raise SystemExit(
                    f"App Store Connect could not be asked {what} ({attempt} attempts): {error}"
                ) from None
            _say(
                f"  App Store Connect did not answer (attempt {attempt} of "
                f"{PREFLIGHT_ATTEMPTS}), asking again in {delay}s: {error}"
            )
            time.sleep(delay)
            delay *= 2
    raise AssertionError("unreachable")


def preflight(args: argparse.Namespace) -> None:
    """Only a TransientError (a timeout, a dropped connection, a 429 or a 5xx) is asked
    again. A refused key, a missing app record or any other 4xx is a SystemExit from the
    first attempt, because asking again cannot change the answer."""
    client = Client()
    # Nothing has been built yet, so failing here costs a re-run and nothing else.
    _asked(lambda: _app_id(client, args.bundle_id), "about the app record")


def wait(args: argparse.Namespace) -> None:
    """Poll until processed. The upload has already happened by the time this runs, so a
    network blip or an Apple 5xx is retried until the deadline rather than turning a
    successful upload into a red run whose re-run would upload a second build."""
    client = Client()
    label = f"{args.version} ({args.build})"
    deadline = time.monotonic() + args.timeout_minutes * 60
    app_id = ""
    seen = False
    while True:
        try:
            app_id = app_id or _app_id(client, args.bundle_id)
            found = _build(client, app_id, args.version, args.build)
            transient = False
        except TransientError as error:
            _say(f"  App Store Connect did not answer, asking again: {error}")
            found, transient = None, True
        if transient:
            pass
        elif found:
            state = found["attributes"].get("processingState")
            if not seen:
                _say(f"build {label} has reached App Store Connect")
                seen = True
            if state == "VALID":
                _say(f"build {label} processed: VALID — installable from TestFlight")
                _summary(f"TestFlight build **{label}** processed and is installable.")
                return
            if state in ("FAILED", "INVALID"):
                _summary(f"TestFlight build {label} failed processing: `{state}`.")
                raise SystemExit(
                    f"build {label} failed processing: {state}. Apple emails the account holder "
                    "the reason; App Store Connect → TestFlight shows it too."
                )
            _say(f"  processing state: {state}")
        else:
            _say("  not visible in App Store Connect yet")
        if time.monotonic() > deadline:
            raise SystemExit(
                f"build {label} did not finish processing within {args.timeout_minutes} minutes. "
                "The upload itself succeeded; check App Store Connect → TestFlight before "
                "re-running, because a re-run uploads a second build."
            )
        time.sleep(POLL_SECONDS)


def _error_lines(output: str) -> list[str]:
    return [line for line in output.splitlines() if "error:" in line.lower()]


def _transient(output: str) -> str | None:
    """The known-transient error xcodebuild failed with, or None for any other failure."""
    for line in _error_lines(output):
        for marker in EXPORT_TRANSIENT_ERRORS:
            if marker in line:
                return marker
    return None


def _redundant(output: str) -> bool:
    return any(marker in line for line in _error_lines(output) for marker in REDUNDANT_UPLOAD)


def _uploaded(build: dict[str, Any]) -> datetime.datetime | None:
    value = build.get("attributes", {}).get("uploadedDate") or ""
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _exit_code(code: int) -> int:
    # A negative code is a signal; report it the way a shell would.
    return 128 - code if code < 0 else code


def _run(command: list[str]) -> tuple[int, str]:
    """Run ``command``, echoing its output as it arrives, and return its code and output."""
    lines = []
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
    ) as process:
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
    return process.returncode, "".join(lines)


def export(args: argparse.Namespace) -> None:
    """Exit 0 once the build is uploaded; otherwise exit with xcodebuild's own code.

    Only an error in EXPORT_TRANSIENT_ERRORS is retried. Every other failure — a signing
    error, a refused key, an agreement, a build-number collision — exits on its first
    attempt, so the run goes red and pages exactly as it did before there was a retry."""
    command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not command:
        raise SystemExit("export: no command after --")
    # Cleared before each attempt, so the summary checked afterwards is this attempt's.
    export_path = command[command.index("-exportPath") + 1] if "-exportPath" in command else ""
    label = f"{args.version} ({args.build})"
    started = datetime.datetime.now(datetime.timezone.utc)
    client: Client | None = None
    app_id = ""

    def listed() -> dict[str, Any] | None:
        """The build if App Store Connect lists it, failing on one this run did not upload."""
        nonlocal client, app_id
        client = client or Client()
        app_id = app_id or _asked(lambda: _app_id(client, args.bundle_id), "about the app")
        found = _asked(
            lambda: _build(client, app_id, args.version, args.build),
            f"whether it already has build {label}; not uploading it again blind",
        )
        if found:
            uploaded = _uploaded(found)
            if uploaded is None or uploaded < started - CLOCK_SLACK:
                raise SystemExit(
                    f"build {label} is already in App Store Connect, uploaded "
                    f"{found.get('attributes', {}).get('uploadedDate')!r}, before this export "
                    f"began at {started.isoformat()}: the build number was used before. "
                    "Re-upload with a fresh dispatch."
                )
        return found

    delay = EXPORT_BACKOFF_SECONDS
    for attempt in range(1, EXPORT_ATTEMPTS + 1):
        if attempt > 1 and listed():
            # A failed attempt can still have reached Apple, and App Store Connect refuses a
            # build number it already has, so this is asked before every upload but the first.
            _say(
                f"::warning title=TestFlight export not repeated::build {label} reached App "
                "Store Connect from a failed attempt, so it is not uploaded again; export left "
                "no summary of what it signed in"
            )
            return
        if export_path:
            shutil.rmtree(export_path, ignore_errors=True)
        code, output = _run(command)
        if code == 0:
            return
        if attempt > 1 and _redundant(output):
            # The previous attempt was accepted after all, and App Store Connect did not list
            # it yet when asked above. Asked again so that a build number used by an earlier
            # run still fails; `wait` confirms this one processes.
            listed()
            _say(
                f"::warning title=TestFlight export not repeated::build {label} was uploaded "
                "by an earlier attempt; export left no summary of what it signed in"
            )
            return
        marker = _transient(output)
        if marker is None:
            sys.exit(_exit_code(code))
        if attempt == EXPORT_ATTEMPTS:
            _say(
                f"::error title=TestFlight export failed {attempt} times::"
                f"'{marker}' persisted across {attempt} attempts, so it is not transient"
            )
            sys.exit(_exit_code(code))
        _say(
            f"::warning title=TestFlight export retried::attempt {attempt} of {EXPORT_ATTEMPTS} "
            f"failed with '{marker}', which App Store Connect gives transiently; "
            f"trying again in {delay}s"
        )
        time.sleep(delay)
        delay *= 2


def _summary(line: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Ask App Store Connect about Zimmer's builds.")
    commands = parser.add_subparsers(dest="command", required=True)

    pre = commands.add_parser("preflight", help="check the key and that the app record exists")
    pre.add_argument("--bundle-id", required=True)
    pre.set_defaults(func=preflight)

    waiting = commands.add_parser("wait", help="block until an uploaded build has processed")
    waiting.add_argument("--bundle-id", required=True)
    waiting.add_argument("--version", required=True, help="CFBundleShortVersionString")
    waiting.add_argument("--build", required=True, help="CFBundleVersion")
    waiting.add_argument("--timeout-minutes", type=int, default=45)
    waiting.set_defaults(func=wait)

    exporting = commands.add_parser(
        "export", help="run xcodebuild -exportArchive, retrying known-transient failures"
    )
    exporting.add_argument("--bundle-id", required=True)
    exporting.add_argument("--version", required=True, help="CFBundleShortVersionString")
    exporting.add_argument("--build", required=True, help="CFBundleVersion")
    exporting.add_argument("argv", nargs=argparse.REMAINDER, help="-- xcodebuild ...")
    exporting.set_defaults(func=export)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
