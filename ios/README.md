# Zimmer for iOS

The iPhone app for Zimmer: the sessions that need you, on your phone. User-facing prose is
[docs: The iOS app](https://docs.zimmer.tadasant.com/extend/ios-app/). This file is the
engineering design doc — read it before changing anything here.

It is set up **the same way as the Motet iOS app** (`tadasant/motet`, `ios/`), deliberately, so
one set of habits covers both. Where this file says "as Motet does", the Motet file of the same
name is the precedent.

## Layout

```
ios/
  Package.swift              SwiftPM: ZimmerKit + ZimmerPlatform libraries + ZimmerKitTests
  Sources/ZimmerKit/         Foundation-only logic. Builds and tests on Linux
    Auth/                    OAuth sign-in (PKCE, a pure-Swift SHA-256), token lifecycle
    Configuration/           BuildEnvironment, ServerURL
    Networking/              HTTPTransport, ZimmerHTTPClient, EdgeCredential, ZimmerError
    Model/                   SessionSummary, SessionStatus, SessionFilter
    Support/                 FakeZimmerAPI (unit tests and the app's debug fixture)
  Sources/ZimmerPlatform/    Apple-only adapters (Keychain), each behind #if canImport
  Tests/ZimmerKitTests/      XCTest, run on Linux and macOS
  App/Zimmer.xcodeproj/      hand-written project: 2 targets, 3 configurations, 3 shared schemes
  App/Zimmer/                SwiftUI app, Info.plist, privacy manifest, assets
  App/ZimmerUITests/         XCUITest, one flow
  bin/                       build-app, ci-swift, install-swift-toolchain, testflight, ui-test
  tools/                     app_store_connect.py (stdlib Python)
```

- **Logic lives in `ZimmerKit`, which imports only Foundation**, so every rule that could be wrong
  — the sign-in callback checks, refresh-once under concurrency, telling an edge refusal from a
  Zimmer 401, list ordering — is tested on the self-hosted Linux runners with no Mac and no
  Apple account. `App/` holds screens and wiring only.
- **Swift 6 language mode**: strict concurrency is the static gate. There is no SwiftLint or
  swift-format, as in Motet. Stateful services are actors (`AuthSession`, `FakeZimmerAPI`);
  screen state is one `@MainActor` `AppModel: ObservableObject`; `AppEnvironment.shared` is the
  composition root, a singleton because the app delegate and (later) the CarPlay scene cannot
  receive SwiftUI environment objects.
- **No dependencies.** No CocoaPods, no remote SwiftPM package, no fastlane, no xcodegen. The
  project is hand-written and uses Xcode 16's folder-synchronised groups, so adding a Swift file
  under `App/Zimmer/` needs no project edit. Its header comment has the two-minute recovery if
  Xcode ever refuses it.
- **No generated API client.** Motet generates one from `openapi.yaml`; Zimmer publishes no
  OpenAPI document, so the few responses the app reads are hand-written `Codable` types. Every
  field beyond `id` and `status` is optional and unknown statuses decode as `.unknown`, because
  TestFlight ships minutes after a merge and the server may be older or newer than the app.

## Running the checks

Every check is a script; every CI step is one line that calls it. Each script **skips** on a
machine without its toolchain and **fails** when `CI` is set, so a green run that compiled
nothing is impossible.

| Script | Does | Needs |
| --- | --- | --- |
| `ios/bin/ci-swift` | `swift build && swift test` on the package | Swift (Linux or Mac) |
| `ios/bin/install-swift-toolchain [dir]` | Swift 6.2 for Linux into `dir` (default `~/.zimmer-ios/swift`), once; prints the shim path | Linux |
| `ios/bin/build-app [--configuration …] [--api-base-url https://…]` | Simulator build, unsigned | Xcode |
| `ios/bin/testflight check` | Unsigned Release archive + assertions on the archived app, and the entitlements guard | Xcode |
| `ios/bin/testflight upload` | The same archive, signed at export, uploaded, processing awaited | Xcode + ASC key |
| `ios/bin/ui-test [--configuration Debug\|Staging] [--api-base-url …] [--artifacts dir]` | Runs `ZimmerUITests` on a simulator it picks by `simctl` JSON, records video, photographs the sign-in and session-list screens | Xcode + simulator |

On Linux: `ZIMMER_SWIFT_SHIM=$(ios/bin/install-swift-toolchain)/swift ios/bin/ci-swift`.

CI (`.github/workflows/ci.yml`): `ios-changes` (no checkout, `ubuntu-latest`) decides whether
anything under `ios/**` or the three iOS workflows moved, and fails open to "build". `ios`
(GitHub-hosted `macos-latest`, free on a public repo) runs `build-app`, `testflight check`,
`ci-swift` and `ui-test --configuration Staging --api-base-url https://ui-test.invalid`, and
keeps the `ios-ui-test` artifact (video, screenshots, result bundle). `ios_swift_linux`
(self-hosted) runs `ci-swift` on Linux. All three carry the fork-PR guard and are in
`all-checks-pass`. `ios-ui-tests.yml` is the same simulator run on demand, against a server named
by the *name* of a repository variable.

## Configurations and what a build is pointed at

`Debug`, `Release`, `Staging`. `Staging` is `Debug` plus `ZIMMER_BUILD_ENVIRONMENT=staging`, and
keeps `DEBUG` so the UI-test fixture exists. **One bundle id for all of them**
(`com.tadasant.zimmer`); a staging build installed beside production would need a second App ID
and App Store Connect record, and was not built, as in Motet.

**No hostname is written anywhere in this repository.** The deployment a build defaults to is the
`ZIMMER_DEFAULT_WEB_BASE_URL` / `ZIMMER_DEFAULT_API_BASE_URL` build settings
(→ `ZimmerDefaultWebBaseURL` / `ZimmerDefaultAPIBaseURL` in `Info.plist`), passed
by `--api-base-url` / `--web-base-url` or by `testflight.yml` from the `ZIMMER_IOS_API_BASE_URL`
and `ZIMMER_IOS_WEB_BASE_URL` environment variables, https only; either alone serves both. The sign-in screen lets a person type another. The label is separate:
`ZimmerBuildEnvironment`, shown as a strip on non-production builds and as
`env=… host=… source=…` in Settings, which the UI test asserts.

## Signing in

The app is a public OAuth client of Zimmer's own authorization server — the built-in `zimmer-ios`
client (`app/services/oauth_server/native_app.rb`). It is Motet's model (PKCE, the web sign-in
does the identity work, a short-lived code, no OAuth client of our own at Google) on a server that
already existed: `/oauth/authorize` sits behind Zimmer's web sign-in wall (Google + TOTP), so the
system sheet shows the same steps a browser does, then a consent screen for "Zimmer for iOS" (both connection levels reach the same API; only **Acts on my behalf** records what you send from the app as your message).

The callback is the private-use scheme `com.tadasant.zimmer:/oauth/callback` (RFC 8252 §7.1)
rather than Motet's `webcredentials` https link. That needs no Associated Domains capability and
no app-site-association file on the server, and PKCE is what makes a custom scheme safe: an
intercepted code is useless without the verifier. `OAuthSignIn.code(fromCallback:)` checks
`state`, the RFC 9207 `iss`, and the scheme.

Tokens: `AuthSession` (an actor) keeps them in the Keychain via `KeychainTokenStore`
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service `com.tadasant.zimmer`), refreshes
60 seconds before expiry, makes one refresh however many requests find the token stale (Zimmer
rotates refresh tokens and revokes a grant on replay), and signs out locally on `invalid_grant`.
Signing out revokes the refresh token at `/oauth/revoke`.

## Two origins, and the edge sign-in

A deployment can serve the app from two origins (`ServerOrigins`): **web**, where a person signs
in (`/oauth/authorize`, the OAuth issuer), and **api**, where every machine call goes
(`/oauth/token`, `/oauth/revoke`, `/api/v1`). Tadas's puts the api origin on its own hostname
(`zimmer-app.…`) behind a Cloudflare Access application that admits only the `@tadasant.com`
Google policy — no service token, no bypass. The contract, from the edge design in the private
companion repo:

1. **Edge login** (`CloudflareAccessCredential`). The sheet opens
   `https://<api>/native/access-handoff?state=<random>`; Access runs its Google login; Rails
   checks the forwarded `Cf-Access-Jwt-Assertion` (`NativeAccessAssertion`: RS256 against the
   team JWKS, `iss`, `exp`, `aud` when configured) and redirects to the hard-coded
   `com.tadasant.zimmer:/access/callback?state=…#cf_access_token=…` — the JWT in the fragment,
   which no server or log sees. `aud` must include `ZIMMER_NATIVE_ACCESS_AUD`; with it unset the
   route refuses everything. The app checks `state` from the query, reads the JWT from the
   fragment, and keeps it in the Keychain (`KeychainEdgeTokenStore`).
2. **Zimmer OAuth** is unchanged and runs on the web origin.
3. **Every machine call** goes to the api origin with `cf-access-token: <JWT>`. API calls also
   carry `Authorization: Bearer <Zimmer token>`; the two never mix — `HTTPRequest.apply(_:)`
   drops any `Authorization` an edge credential offers.
4. **Refresh**: the JWT's `exp` (~30 days) is read without checking the signature; the handoff
   runs again when under 24 hours remain, or when the edge refuses a call. Re-running it *is* the
   refresh.
5. **Telling refusals apart** (`EdgeRefusal`): Access redirects to `*.cloudflareaccess.com` (the
   transport never follows that — `AccessRedirectGuard`), sends `www-authenticate:
   Cloudflare-Access …`, or a 401/403 HTML page with `cf-access-aud`. Rails answers a JSON 401
   with `x-request-id`. A 404 `text/plain` without `x-request-id` is the tunnel saying the path
   is not on the app host's allow-list — `ZimmerError.edgeNotRouted`, a bug, never retried.
   `server: cloudflare` is on every response, so it is never evidence.

Every `/api/v1` controller the app calls must declare `accepts_native_app_tokens`;
`test/config/native_app_api_coverage_test.rb` reads every `"/api/v1/…"` literal under
`ios/Sources` and fails if a controller behind one does not. Every path is joined through
`ServerURL.join`, so none contains `//` — the app host's tunnel answers that with a 404.

When web and api are one origin there is no edge credential (`NoEdgeCredential`). **Never put a
shared secret in either** — a service token compiled into a public app is a published service
token.

## CarPlay

A voice-based conversational CarPlay app (`com.apple.developer.carplay-voice-based-conversation`,
iOS 26.4+, Apple CarPlay Developer Guide, June 2026). The other categories don't fit: Zimmer is not
audio, navigation, communication (SiriKit messaging or VoIP) or a driving task, and what a driver does
with it is talk. The category allows list, grid, tab bar, alert, action sheet, information and voice
control templates, with a depth of three, and requires voice as the primary modality at launch.

- `ZimmerKit/Driving/DrivingFlow.swift` is the conversation as a pure state machine. It holds
  `VoiceCommand` parsing, at most five needs-input sessions, and a spoken confirmation before
  any archive or reply. It is tested on Linux.
- `App/Zimmer/CarPlay/CarPlaySceneDelegate.swift` performs its effects. It uses a
  `CPListTemplate` root, a `CPActionSheetTemplate` per row, and a `CPVoiceControlTemplate` while
  talking. `VoiceIO` uses `AVSpeechSynthesizer` and `SFSpeechRecognizer`, on-device only, so spoken
  replies never go to Apple's servers. The tap and the
  recognition handler are built in a `nonisolated` helper, because a closure formed on the main
  actor and called from an audio thread is a Swift 6 runtime crash.
- **Inert until the grant**, as Motet's scene is. `App/Zimmer/CarPlay.entitlements` holds the key
  and is in the project's exception set, wired into nothing. `ios/bin/testflight` signs in only
  `Push.entitlements`. When Apple grants the entitlement: tick CarPlay on the App ID, merge the key
  into the signed entitlements, admit it in the guard, and check the first signed build's
  entitlements with codesign. Cloud signing may drop a managed entitlement; if it does, use a
  manually made App Store profile.

## Distribution

`.github/workflows/testflight.yml` runs `ios/bin/testflight upload` on every push to `main` that
touches the app, and on dispatch. It is fenced the way Motet's is: (1) only `push` to `main` and
`workflow_dispatch`; (2) the job refuses any ref but `main` and any repository but this one; (3)
the key is a `testflight` **environment** secret behind a `main`-only branch policy; (4) a
GitHub-hosted ephemeral runner. The checkout is pinned by SHA.

The archive is unsigned; `-exportArchive -allowProvisioningUpdates` with the App Store Connect
API key (Admin role) signs it with Apple's cloud-managed certificate at export. One key is the
whole credential. `ZIMMER_SIGNING=archive` (dispatch input `signing=archive`) is the fallback.
`CFBundleVersion` is `run_number.run_attempt`; re-upload with a fresh dispatch, never "Re-run".

**Until the `testflight` environment has its key, the workflow skips the upload with a notice and
stays green.**

`testflight check` refuses any `CODE_SIGN_ENTITLEMENTS`: nothing is admitted yet. Each
entitlements file the app grows is admitted there by name, with the keys it may ask for, only
once its capability exists on the App ID — an ungranted entitlement fails signing, not just the
feature. After the first signed build, check what Apple materialised:
`codesign -d --entitlements :- Zimmer.app`.

## What a human does, once

Each unblocks the next:

1. Accept any pending agreements at developer.apple.com and in App Store Connect → Business.
2. Register the App ID `com.tadasant.zimmer` (Certificates, IDs & Profiles → Identifiers).
3. Create the App Store Connect app record for it.
4. Reuse the Admin Team API key Motet uses, or create one (Users and Access → Integrations).
5. In `tadasant/zimmer`, create the `testflight` environment with a deployment-branch policy of
   `main` only. Secrets: `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`,
   `APP_STORE_CONNECT_API_KEY_P8`. Variables: `APPLE_TEAM_ID`, `ZIMMER_IOS_WEB_BASE_URL` (the
   sign-in host) and `ZIMMER_IOS_API_BASE_URL` (the app host).
6. On the server, set `ZIMMER_NATIVE_ACCESS_AUD` to the app host's Access audience tag (Terraform's
   `native_app_access_aud`).
7. After the first build processes, add internal testers in TestFlight.

## What is not verified

- **The two sign-ins end to end against Tadas's deployment** — waiting on the app host and its
  Access application (private companion repo) being applied, and on this route being deployed.
- **Anything signed**: no TestFlight build exists until the steps above are done.
- **On a device**: Keychain behaviour, the sign-in sheet against a real Google login and second
  factor. The UI test drives an in-memory fixture, because an agent cannot complete a Google
  sign-in.
- **In Xcode**: the project has only ever been read by `xcodebuild` in CI.
