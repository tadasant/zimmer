#!/usr/bin/env python3
"""Ask App Store Connect about Zimmer's app record and its builds.

Two questions, both asked by `ios/bin/testflight upload`:

* ``preflight`` — does an app record exist for the bundle id, and does the key work? Asked
  *before* a ten-minute archive, because both answers are otherwise discovered at the very
  end, by the upload failing.
* ``wait`` — has the build just uploaded finished processing? An upload that Xcode reports
  as successful can still fail processing (a missing icon, an invalid binary), and until it
  is ``VALID`` nobody can install it. "The upload step went green" is not the claim this
  pipeline exists to make.

Stdlib only, plus the ``openssl`` binary for the ES256 signature, so it runs on a
GitHub-hosted macOS runner with no ``pip install`` and no third-party code handed the key.

The key is read from the path in ``APP_STORE_CONNECT_API_KEY_PATH``. Nothing this script
writes contains the key, the signed token, or any header.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
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
                body: dict[str, Any] = json.load(response)
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
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
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


def preflight(args: argparse.Namespace) -> None:
    try:
        _app_id(Client(), args.bundle_id)
    except TransientError as error:
        # Nothing has been built yet, so failing here costs a re-run and nothing else.
        raise SystemExit(f"App Store Connect could not be asked: {error}") from None


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
            body = client.get(
                "/v1/builds",
                {
                    "filter[app]": app_id,
                    "filter[version]": args.build,
                    "filter[preReleaseVersion.version]": args.version,
                    "fields[builds]": "version,processingState,uploadedDate,expired",
                    "limit": "1",
                },
            )
        except TransientError as error:
            _say(f"  App Store Connect did not answer, asking again: {error}")
            body = {"transient": True}
        builds = body.get("data", [])
        if body.get("transient"):
            pass
        elif builds:
            state = builds[0]["attributes"].get("processingState")
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

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
