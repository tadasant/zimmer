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

The app follows the web UI's board and session page: the same words, the same status colours
(needs input blue, running green, waiting purple, failed orange, trashed gray), the same actions.
Where the web UI has a button, the app has a swipe, a long press, or a menu item.

- **Lists sessions**, filtered by status and by board visibility. *Needs input* is the default
  status filter and sorts above everything else; the others are *Active* (everything not
  archived), *Running*, *Failed* and *Archived*. Board visibility is *On board* by default, like
  the web UI's board, with *Snoozed & hidden* and *Both* in the filter menu. Pull to refresh.
  Rows carry the status pill, a star for a favourite, the latest PR, a notes marker, and when a
  snooze ends.
- **Searches** titles and metadata from the search box, or transcripts too with the
  *Transcripts* scope (the web UI's "Search transcript contents"; the first page of one bounded
  scan, and the list says so when the scan stopped before reading every session).
- **Acts on a row.** Swipe right to star or unstar. Swipe left to trash (or restore, in Archived)
  and to snooze (*Later today*, *Tomorrow*, *In 3 days*, *This weekend*, *Next week*, the web UI's
  presets, worked out in the phone's time zone) or hide. Press and hold for the rest: pause,
  restart, view the PR, open the session in the browser.
- **Opens a session**: its status, priority class and board visibility; its agent root, runtime,
  model and effort; its PRs, coloured by state with the CI dot; the *Status summary* ("where
  things stand") with *Regenerate*; its goal and notes; and the conversation, newest last, with
  tool calls folded away until asked for (`GET /api/v1/sessions/:id/conversation`).
- **The session menu** (the ⋯ button) is the web UI's mobile *Session actions* sheet, in its order:
  Quick Router, Edit Notes, View PR, Snooze until… / Hide / Put back on the board, Refresh
  Transcript, Pause Session, Restart Session. Then what the web UI's metadata block and Ranked view
  edit: Rename, Modify Goal, Effort (the levels the session's model accepts, or the model
  default), Promote to priority / Demote to spot (to the head of the spot queue), the heartbeat on
  or off, Generate Status Summary when there is none, and Open in browser. A promotion that could
  not start the session says why. The star and the trash (or restore) are in the toolbar.
- **Sends a follow-up** from a box at the bottom, with quick replies for the common answers. A
  follow-up to a session mid-turn is queued, and the app says so; touch and hold the button to
  *Send Now* instead, which ends the turn in flight (`force_immediate`, the web UI's Send Now).
  It is recorded as your message if the app's connection acts on your behalf (below).
- **Trashes** a session, after a confirmation, and restores one from the trash.
- **Starts a session from a sentence** through the Quick Router (the pencil button), then opens it.
- **Says which deployment a build is for.** A Staging or development build shows a strip at the top,
  and Settings prints `env=… host=… source=…`.

Every action above is a route on `/api/v1/sessions` that the app's token could already reach; none
of them widened what the phone can do on the server.

### Not in the app yet

The web UI's queued-message list (reorder, edit, delete), image and file attachments, the
new-session form and MCP server / skill / hook / plugin / model changes, the notifications inbox,
triggers, costs and health are not in the app yet. They need `/api/v1` controllers the app's token
does not reach today, or, for attachments, an API route that does not exist, so each comes in its
own change that says what it opens. The admin pages (API keys, inference accounts, connectors,
settings) stay in the browser; *Open in browser* on any session gets you there.

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

## Push notifications

The app asks for permission after sign-in and registers the phone (`POST /api/v1/apns_devices`). It
sends the APNs token and the environment it belongs to: `sandbox` for a development or Staging build,
`production` for TestFlight. Tapping a notification opens its session. Signing out unregisters the
phone (a connection can unregister only its own phones), and revoking its connection stops its pushes
even if it never signs out.

The server sends the same notifications the web push does (*needs input*, a question waiting for an
answer, *finished*, *failed*, and a custom message) from `SendPushNotificationJob`, through `ApnsService`, but **the lock screen only says
what kind of thing happened**: "Zimmer — A session needs you.", "A session failed." and so on. A web
push is encrypted end to end, so the browser's push service relays ciphertext; an APNs alert is
readable by Apple. So the session's title, the summary of its last message, a failure detail and a
custom message's text never go to Apple. The push carries the session id, and tapping it opens the
session in the app, which reads it over its own authenticated connection. That is one HTTP/2 request per
phone to Apple, authenticated with an ES256 provider token signed by the APNs key. The key is
`APNS_AUTH_KEY_P8`, `APNS_KEY_ID` and `APNS_TEAM_ID` in the secret chain. **Until all three are set, it
sends nothing and logs why.** A token Apple reports dead is disabled with Apple's reason, and an APNs
failure never affects the web push or the notification record. Registered phones, and why one went
quiet, are listed at `/supervisor/apns_devices`.

The build signs in the `aps-environment` entitlement only when the `testflight` environment's
`ZIMMER_IOS_PUSH_ENABLED` variable is `1`. Set it once Push Notifications is ticked on the App ID.

## CarPlay

Zimmer's CarPlay scene is a **voice-based conversational app**, Apple's category for apps whose
primary way in is talking (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). None of
the other categories fit: Zimmer isn't audio, navigation, messaging, or a driving task. When the
phone connects, it says how many sessions need you and reads the first, its title and *Status
summary*, then listens:

- **"Yes"** (or "go ahead", "merge it") sends *Yes, go ahead.*
- **"Reply …"**, or anything else, is a reply in your own words. It is read back, and sent when you
  say yes. A bare **"reply"** asks what to say.
- **"Archive"** archives, after you say yes.
- **"Next"** skips, **"repeat"** reads it again, and **"stop"** ends the conversation.

Archive and replies wait for a spoken "yes", so a misheard word costs a sentence, not a session.
"Yes" on its own sends the approval at once, because it is the usual answer and only tells the agent
to carry on. If an action fails, the app says why and doesn't claim it worked. If Zimmer can't be
reached, the app says that instead of "nothing needs you". The screen underneath lists up to five sessions that need input. Each row is an action
sheet (Approve, Reply by voice, Archive) for a driver who would rather tap, and a Talk button
restarts the conversation. The voice control, list and action sheet templates are all ones the
category allows, and the stack never goes deeper than three. Speech is recognised on the phone only
(`requiresOnDeviceRecognition`), so a spoken reply never goes to Apple's servers. A phone that can't
recognise its language on the device says so instead of asking for an answer, and offers Approve and
Archive on the screen without Reply by voice. The audio session is held only while
the conversation runs. The rules live in `DrivingFlow`, which the unit tests cover.

**The scene is inert until Apple grants the entitlement.** The entitlement lives in
`App/Zimmer/CarPlay.entitlements`, which is wired into nothing, and `testflight` refuses to sign
CarPlay in. This is the same arrangement as Motet's.

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
