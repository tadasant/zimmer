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
  tools/                     app_store_connect.py (stdlib Python) and its tests
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

## How it looks

Every colour, radius, type role and shared component is in `App/Zimmer/Support/Theme.swift`.
Screens take their colours from it, and the only ones they name directly are white and clear. It is shaped like Motet's `Theme`: a ground, a surface, ink at
three strengths, hairlines instead of shadows, small uppercase tracked labels, and digits that do
not jitter. The colours come from the Zimmer web UI instead of Motet's:

- **Light** is the web UI's own Tailwind palette: gray-50 page, white cards, gray-200 rules,
  gray-900 ink, indigo-600 accent (also `AccentColor` in the asset catalog). Filled buttons and
  chips keep the accent at indigo-500 or deeper in dark mode, so white stays legible on them.
- **Dark** is drawn on the PWA manifest's navy (`#000e2b` ground, `#031942` cards), because the
  web UI has no dark mode to copy.
- **Status colours** are `SessionsHelper#status_badge_classes`: the `bg-*-100 text-*-800` pastel
  in light, and the same hue on a deep wash in dark.
- **The mark's gold** is a signature used sparingly: the primary button's foot, the ring round the
  mark on sign-in, empty-state rings, the status summary's edge, and the build
  strip. It is never used for text.

The Quick Router is placed as the web UI places it: a bar pinned to the foot of the Sessions
screen, and a round button in the bottom-right corner of every other screen (`quickRouterCorner()`),
which opens the sheet. While the bar has the keyboard an X stands on its left, across the field
from send, and empties it as the search box's Cancel does. The button carries the app's one shadow — a thing floating over content
needs the lift, as Motet's play button does.
[`PARITY_AUDIT.md`](PARITY_AUDIT.md) is the running comparison against the web UI and against
Motet, grouped into the slices that land it.

The system font is kept, as the web UI's `font-sans` is on a phone, and the bars keep the system
material. The app stays native in the places where iOS's own chrome is the familiar thing.
Rows on the board share one surface with hairlines between them rather than a card each, and
ages are compact (`Format.age`: "41m", "3h"), so a screen shows roughly half again as many
sessions as a card per row did.
`ui-test` photographs the main screens in both appearances.

## Running the checks

Every check is a script; every CI step is one line that calls it. Each script **skips** on a
machine without its toolchain and **fails** when `CI` is set, so a green run that compiled
nothing is impossible.

| Script | Does | Needs |
| --- | --- | --- |
| `ios/bin/ci-swift` | `swift build && swift test` on the package | Swift (Linux or Mac) |
| `ios/bin/install-swift-toolchain [dir]` | Swift 6.2 for Linux into `dir` (default `~/.zimmer-ios/swift`), once; prints the shim path | Linux |
| `ios/bin/build-app [--configuration …] [--api-base-url https://…]` | Simulator build, unsigned | Xcode |
| `ios/bin/testflight check` | Ad hoc signed Release archive + assertions on the archived app, its signed entitlements, and the entitlements guard | Xcode |
| `ios/bin/testflight upload` | The same archive, signed at export, uploaded, processing awaited | Xcode + ASC key |
| `ios/bin/ui-test [--configuration Debug\|Staging] [--api-base-url …] [--artifacts dir]` | Runs `ZimmerUITests` on a simulator it picks by `simctl` JSON, records video, photographs every key screen in both appearances | Xcode + simulator |
| `ios/bin/ui-test --smoke [--also ios/App/ZimmerUITests/X.swift …]` | The per-PR subset: the session list, the build's server, a session started from a sentence and opened, plus every class in each `--also` file. No photographs | Xcode + simulator |
| `ios/bin/ui-test --only A,B [--no-photos]` | One shard of the suite: the named `ZimmerUITests` classes only, each checked against the sources before the build; `--no-photos` skips the photograph pass. `ios-ui-tests.yml` runs four of these at once | Xcode + simulator |

On Linux: `ZIMMER_SWIFT_SHIM=$(ios/bin/install-swift-toolchain)/swift ios/bin/ci-swift`.

CI (`.github/workflows/ci.yml`): `ios-changes` (no checkout, `ubuntu-latest`) decides whether
anything under `ios/**` or the three iOS workflows moved, and fails open to "build". `ios`
(GitHub-hosted `macos-latest`, free on a public repo) runs `testflight check`, `ci-swift` and
`ui-test --smoke --configuration Staging --api-base-url https://ui-test.invalid`, adding an
`--also` for each UI test file the change touches, and keeps the `ios-ui-test` artifact (video,
result bundle, and the app's crash reports in `crashes/`, whose crashed thread is also printed in
the job's log). It does not run `build-app`: `ui-test` builds the same app for the simulator it runs on.
`ios_swift_linux` (self-hosted) runs `ci-swift` on Linux. All three carry the fork-PR guard and are
in `all-checks-pass`. `ios-ui-tests.yml` is the full run, every UI test and every screenshot, as
four shards on four simulators (`--only` a quarter of the classes each, the `photos` shard taking
the screenshots; `test/config/ios_ui_test_shards_test.rb` holds every class to one shard), on
each push to `main` that touches `ios/**`, and on demand: against a branch
(`gh workflow run ios-ui-tests.yml --ref <branch>`) or against a server named by the *name* of a
repository variable.

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
6. **Timeouts are not outages.** A gateway timeout (504 from the proxy, 524 from Cloudflare) or
   the request's own `URLError.timedOut` is `ZimmerError.timedOut`, which says "took too long".
   It is not `.transport`, which says "couldn't reach": in that case the server was reached.

Every `/api/v1` controller the app calls must declare `accepts_native_app_tokens`;
`test/config/native_app_api_coverage_test.rb` reads every `"/api/v1/…"` literal under
`ios/Sources` and fails if a controller behind one does not. Every path is joined through
`ServerURL.join`, so none contains `//` — the app host's tunnel answers that with a 404.

When web and api are one origin there is no edge credential (`NoEdgeCredential`). **Never put a
shared secret in either** — a service token compiled into a public app is a published service
token.

## CarPlay

A voice-based conversational CarPlay app (`com.apple.developer.carplay-voice-based-conversation`,
iOS 26.4+, Apple CarPlay App Programming Guide, 2026-10-13). The other categories don't fit: Zimmer is not
audio, navigation, communication (SiriKit messaging or VoIP) or a driving task, and what a driver does
with it is talk. The category allows list, grid, tab bar, alert, action sheet, information and voice
control templates, with a depth of three, requires voice as the primary modality at launch, allows
recording only under the voice control template, and shows no notifications. The design and every
decision in it is [`CARPLAY_DESIGN.md`](CARPLAY_DESIGN.md).

- `ZimmerKit/Driving/DrivingBoard.swift` is what the car shows and says, as pure rules: the two
  lists (needs you, running), their order and cap, each card's lines and buttons, what each button
  confirms, and the spoken briefing. `LiveContext.swift` is the call screen's title and the words
  for what the call is doing. Both are tested on Linux.
- `App/Zimmer/CarPlay/CarPlaySceneDelegate.swift` is the wiring: a `CPTabBarTemplate` root (a grid
  home, two lists), a `CPInformationTemplate` card per session, alerts and a sheet, a silent
  minute-by-minute read of the board, and the briefing when its tile is tapped. The car speaks only
  after a tap.
  `CarPlayDashboard.swift` builds those templates; `CarPlayLive.swift` is Live Mode's call screen, a
  `CPVoiceControlTemplate` whose title names the session the conversation is about and whose two
  action buttons are Mute and Hang up; `CarPlaySpeech.swift` is the car's own voice
  (`AVSpeechSynthesizer`), holding a playback audio session only while it speaks. There is no
  speech recogniser: the car listens only through the Live call.
- **Signed into every TestFlight build.** Apple granted the entitlement to the team as a managed
  capability, and it is ticked on the App ID. `App/Zimmer/CarPlay.entitlements` holds the key and
  is in the project's exception set; `ios/bin/testflight` signs it in, merged with
  `Push.entitlements` when push is on. Apple documents that its managed-capability workflow puts it
  in the profile cloud signing creates at export, so no profile is made by hand; the first signed
  build is what confirms it. Simulator builds stay
  unsigned and carry no entitlements.

## Distribution

`.github/workflows/testflight.yml` runs `ios/bin/testflight upload` on every push to `main` that
touches the app, and on dispatch. It is fenced the way Motet's is: (1) only `push` to `main` and
`workflow_dispatch`; (2) the job refuses any ref but `main` and any repository but this one; (3)
the key is a `testflight` **environment** secret behind a `main`-only branch policy; (4) a
GitHub-hosted ephemeral runner. The checkout is pinned by SHA.

The archive is signed ad hoc, which needs no certificate and exists only so the archived binary
carries its entitlements: export signs in what it finds there, and an archive built with signing
off has none. `-exportArchive -allowProvisioningUpdates` with the App Store Connect API key (Admin
role) then signs it with Apple's cloud-managed certificate. After the upload, the run checks
export's `DistributionSummary.plist` and fails if an admitted key is missing. One key is the
whole credential. `ZIMMER_SIGNING=archive` (dispatch input `signing=archive`) is the fallback.
`CFBundleVersion` is `run_number.run_attempt`; re-upload with a fresh dispatch, never "Re-run".

The export is retried, up to three attempts with backoff, only when xcodebuild fails with an error
App Store Connect gives transiently — "Error Downloading App Information" and three network
errors, listed in `EXPORT_TRANSIENT_ERRORS` in `tools/app_store_connect.py`. Before each retry
the helper asks App Store Connect for the build and stops if it is already there. On a retry,
"Redundant Binary Upload" also means the earlier attempt landed, since App Store Connect lists a
new build late. So one build number is never uploaded twice, and a listed build uploaded before
the export began fails the run as a collision. Any other failure — signing, the key, an agreement, a build-number
collision — fails the run on the first attempt. The retry logic is tested by
`tools/test_app_store_connect.py`, which the `ios` CI job runs.

**Until the `testflight` environment has its key, the workflow skips the upload with a notice and
stays green.**

`testflight` admits two entitlements files, each by name and with the one key it may ask for:
`CarPlay.entitlements` (`com.apple.developer.carplay-voice-based-conversation`, always) and
`Push.entitlements` (`aps-environment`, when `ZIMMER_IOS_PUSH_ENABLED=1`). A file is admitted only
once its capability exists on the App ID — an ungranted entitlement fails signing, not just the
feature. `check` asserts that the archived app's ad hoc signature carries every admitted key, so a
PR proves it before an upload does.

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
- **Live Mode's voice audio**: `App/Zimmer/Live/LiveAudioEngine.swift` and `LiveCall`'s WebSocket to
  OpenAI have not run. A simulator has no microphone worth testing echo cancellation on, and no
  deployment has the OpenAI key yet. The Realtime sequencing they drive (`RealtimeConductor`) and
  the PCM conversion (`RealtimeAudio`) are covered by ZimmerKit's tests, and the screens by
  `LiveUITests` against the fixture.
