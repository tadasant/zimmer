---
title: The iOS app
description: Zimmer on an iPhone — the session list, signing in through Zimmer's own OAuth server and through the edge's access proxy, how it is built and shipped to TestFlight, and what has not been proven on a device yet.
sidebar:
  order: 7
---

Zimmer's iOS app puts the sessions that need you on your phone. It lives in
[`ios/`](https://github.com/tadasant/zimmer/tree/main/ios) in this repo. It is set up the same way as
the Motet iOS app (`tadasant/motet`, `ios/`): a checked-in Xcode project, a Swift package whose
logic is tested on Linux, every check a script under `ios/bin/`, and a TestFlight upload on every
merge. [`ios/README.md`](https://github.com/tadasant/zimmer/blob/main/ios/README.md) is the
engineering design doc. This page covers what the app does and how it reaches Zimmer.

:::caution[Not yet proven on a phone]
The app host and its Access application are being added in the private companion repo. Until that
is applied and this route is deployed, nothing has run the two sign-ins end to end on a device. See
[Known limitations](/limitations/#the-ios-apps-two-sign-ins-have-not-run-end-to-end).
:::

## What it does

- **Lists sessions**, filtered by status. *Needs input* is the default filter and sorts above
  everything else. The other filters are *Active* (everything not archived), *Running*, *Failed*
  and *Archived*. Pull to refresh.
- **Opens a session**: its status, the *Status summary* ("where things stand"), and the conversation,
  newest last, with tool calls folded away until asked for (`GET /api/v1/sessions/:id/conversation`).
- **Sends a follow-up** from a box at the bottom, with quick replies for the common answers. A
  follow-up to a session mid-turn is queued, and the app says so. It is recorded as your message if
  the app's connection acts on your behalf (below).
- **Archives** a session, after a confirmation. It goes to the trash and can be restored from the web UI.
- **Starts a session from a sentence** through the Quick Router (the pencil button), then opens it.
- **Says which deployment a build is for.** A Staging or development build shows a strip at the top,
  and Settings prints `env=… host=… source=…`.

## Two origins

A deployment can serve the app from two origins:

- **The web origin** (`zimmer.tadasant.com` for Tadas's) is where you sign in. `/oauth/authorize`
  runs there, and it is the OAuth issuer.
- **The app origin** (`zimmer-app.tadasant.com`) is where every machine call goes: `POST
  /oauth/token`, `/oauth/revoke`, `/api/v1/*`, and the edge handoff below. It is a separate hostname
  through the same tunnel to the same Rails, guarded by its own Cloudflare Access application that
  admits only the deployment's Google policy. There is no service token and no bypass.

A deployment without an app host uses one origin for both, and there is no edge sign-in.

## Signing in

On a deployment with an app host, the app signs in twice, and the two credentials stay independent.

**The edge first.** The system sign-in sheet opens
`https://<app origin>/native/access-handoff?state=<random>`. Access runs its own Google login and
forwards the request with the `Cf-Access-Jwt-Assertion` it minted. Rails checks that assertion
(`NativeAccessAssertion`):

- an RS256 signature from a key in the team's JWKS at `/cdn-cgi/access/certs`, cached for an hour;
- `iss` equal to the team domain (`ZIMMER_NATIVE_ACCESS_TEAM_DOMAIN`, default `tadasant.cloudflareaccess.com`);
- not expired;
- an `aud` that includes `ZIMMER_NATIVE_ACCESS_AUD`, the native app's Access audience tag. This is
  required. With the variable unset, every handoff is refused, because a JWT minted for any other
  Access application of the team would otherwise pass.

Rails then redirects to the hard-coded `com.tadasant.zimmer:/access/callback?state=…#cf_access_token=…`.
The JWT is in the fragment, which no server or request log ever sees. Anything invalid gets a 403,
and a malformed `state` gets a 400. The route has no web sign-in wall and
no CSRF check: it hands back only what Access minted for this requester, and every API call still needs
Zimmer's own token. The app checks `state` from the query, reads the JWT from the fragment, keeps it in the Keychain,
and sends it as `cf-access-token` on every machine call, never in `Authorization`. The edge passes
`Authorization` through untouched. Every `/api/v1` controller the app calls declares
`accepts_native_app_tokens`, and `test/config/native_app_api_coverage_test.rb` reads the app's
Swift sources and fails if one does not. Paths are joined so that none contains `//`, which the app
host's tunnel answers with a 404. The JWT lives about 30 days. The app
runs the handoff again when less than a day is left, or when Access refuses a call: a redirect to
`*.cloudflareaccess.com`, which the app never follows, or a 401/403 page with `cf-access-aud`.

**Then Zimmer**, as a public OAuth client of [Zimmer's authorization server](/auth/mcp-authorization-server/),
under the built-in `zimmer-ios` client:

1. You type your Zimmer's https address, unless the build already carries one.
2. The system sign-in sheet opens `/oauth/authorize` with a PKCE challenge. Zimmer's
   [web sign-in](/auth/web-sign-in/) does the rest, as it does in a browser: Google, restricted to
   the deployment's domain, then the second factor. Zimmer then shows a consent screen for
   "Zimmer for iOS". It asks for a [connection level](/auth/mcp-authorization-server/#relay-only-or-acts-on-my-behalf) like every
   other OAuth connection. Both levels reach the same API. **Acts on my behalf** records what you
   send from the app (follow-ups, Quick Router prompts) as your message, the way it does for an
   assistant; **Relay only** records nothing.
3. Approving sends the sheet to `com.tadasant.zimmer:/oauth/callback` with a 60-second code. The app
   redeems it at `/oauth/token` on the app origin with the verifier only it holds.
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
`APPLE_TEAM_ID`, `ZIMMER_IOS_WEB_BASE_URL` and `ZIMMER_IOS_API_BASE_URL` variables. On the server,
set `ZIMMER_NATIVE_ACCESS_AUD` to the app host's Access audience tag. Both Kamal configs read it from
the deploy's environment: `deploy-staging.yml` forwards the `ZIMMER_NATIVE_ACCESS_AUD` repository
variable, and production's deploy workflow has to forward it the same way.
