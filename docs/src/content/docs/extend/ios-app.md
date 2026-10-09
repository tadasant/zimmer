---
title: The iOS app
description: Zimmer on an iPhone — the session list, signing in through Zimmer's own OAuth server, how it is built and shipped to TestFlight, and what has not been proven on a device yet.
sidebar:
  order: 7
---

Zimmer's iOS app puts the sessions that need you on your phone. It lives in
[`ios/`](https://github.com/tadasant/zimmer/tree/main/ios) in this repo. It is set up the same way as
the Motet iOS app (`tadasant/motet`, `ios/`): a checked-in Xcode project, a Swift package whose
logic is tested on Linux, every check a script under `ios/bin/`, and a TestFlight upload on every
merge. [`ios/README.md`](https://github.com/tadasant/zimmer/blob/main/ios/README.md) is the
engineering design doc. This page covers what the app does and how it reaches Zimmer.

:::caution[Not yet usable against a deployment behind an access proxy]
Tadas's production Zimmer sits behind Cloudflare Access. Access answers the app's token exchange
and API calls with its own 401 before Rails sees them, so a phone cannot use it yet. The app
treats that refusal as its own error ("this server's network edge refused the phone") rather than as
a sign-out. Its networking has one place, `EdgeCredential`, for whatever credential the edge
decides a phone must carry. Choosing that design belongs to the deployment's infrastructure, not to
this repo. See [Known limitations](/limitations/#the-ios-app-cannot-reach-a-deployment-behind-cloudflare-access-yet).
:::

## What it does

- **Lists sessions**, filtered by status. *Needs input* is the default filter and sorts above
  everything else. The other filters are *Active* (everything not archived), *Running*, *Failed*
  and *Archived*. Pull to refresh.
- **Says which deployment a build is for.** A Staging or development build shows a strip at the top,
  and Settings prints `env=… host=… source=…`.

## Signing in

The app is a public OAuth client of [Zimmer's authorization server](/auth/mcp-authorization-server/),
under the built-in `zimmer-ios` client:

1. You type your Zimmer's https address, unless the build already carries one.
2. The system sign-in sheet opens `/oauth/authorize` with a PKCE challenge. Zimmer's
   [web sign-in](/auth/web-sign-in/) does the rest, as it does in a browser: Google, restricted to
   the deployment's domain, then the second factor. Zimmer then shows a consent screen for
   "Zimmer for iOS".
3. Approving sends the sheet to `com.tadasant.zimmer:/oauth/callback` with a 60-second code. The app
   redeems it at `/oauth/token` with the verifier only it holds.
4. The access and refresh tokens go into the Keychain (`AfterFirstUnlockThisDeviceOnly`). The app
   refreshes the access token before it expires and calls
   [the REST API](/extend/rest-api/#the-ios-apps-bearer-token) with it.

No Google credential and no API key ever reaches the phone. The connection is listed on
**Settings → API keys** with every other OAuth connection, and revoking it there signs the phone out
on its next request. Signing out in the app revokes it too.

## How it is built and shipped

| Check | Where it runs | What it proves |
| --- | --- | --- |
| `ios/bin/ci-swift` | `ios_swift_linux` (self-hosted Linux) and `ios` (macOS) | The `ZimmerKit` logic: sign-in protocol, token refresh, edge-refusal handling, list ordering |
| `ios/bin/build-app` | `ios` (GitHub-hosted `macos-latest`) | The app compiles and links for the simulator |
| `ios/bin/testflight check` | `ios` | An unsigned Release archive is uploadable in shape (bundle keys, icon, privacy manifest, no entitlements) |
| `ios/bin/ui-test` | `ios` | The app runs on a simulator against its debug fixture, and the screenshots are kept as the `ios-ui-test` artifact |
| `ios/bin/testflight upload` | `testflight.yml`, on push to `main` | Signs in Apple's cloud at export, uploads, and waits for processing |

The iOS jobs run only when `ios/**` or one of the three workflows changes. The `ios-changes` job
decides, and when it cannot tell it builds anyway. All three are in `all-checks-pass`. The macOS
runner is GitHub-hosted, which costs nothing on a public repository. It is the one exception to the
self-hosted pool, because nothing in the pool is a Mac.

`testflight.yml` is fenced the way Motet's is. Its only triggers are a push to `main` and a dispatch;
it refuses any other ref or repository; the App Store Connect key is a secret of the `testflight`
*environment*, behind a `main`-only branch policy; and it runs on an ephemeral hosted runner. Until
that environment has its key, the run says so in a notice and skips the upload, staying green.

## What a human does, once

[`ios/README.md`](https://github.com/tadasant/zimmer/blob/main/ios/README.md#what-a-human-does-once)
has the full list: register the App ID `com.tadasant.zimmer`, create the App Store Connect record,
create or reuse the Admin API key, and create the `testflight` environment with its secrets and the
`APPLE_TEAM_ID` and `ZIMMER_IOS_API_BASE_URL` variables.
