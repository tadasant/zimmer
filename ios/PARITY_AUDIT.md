# iOS ↔ web parity audit

This file is the full matrix of what the Zimmer web app (the PWA) can do against what the iOS app can do, derived from the web source on 2026-10-15 at commit `1dc36979` of `main`. It was built by enumerating every HTML route a signed-in person reaches, every view and partial under `app/views`, and every Stimulus controller, in five areas — Settings and account, the session page, the board and the ways to start a session, the operations pages, and the global chrome — then cross-checking those five against a census of the routes so nothing fell between them. The open PRs #1282, #1284 and #1318 were read; rows they close say so.

Each row is one control or piece of information on the web: where it is (view file and line, or route), what it does, the iOS file that does the same thing (or `—`), a status, and a note. The status is one of `present` (the app does it), `partial` (the app does part of it; the note says which part is missing), `missing` (the app does not do it; the note names the API it needs, or says it is app-only), or `web-only` (it stays in the browser, with a reason a phone user would accept). "needs API" means no `/api/v1` route or field carries it; "open X to the native token" means the route exists and only the `accepts_native_app_tokens` allowlist stands in the way; "MCP only" means an MCP tool exists but no REST route. Notes that cite G1–G25 or P-numbers refer to the previous revision of this file, which this one replaces.

## Why earlier audits missed things

Every audit before this one started from the previous audit, or from memory of the web app, and checked the app against that list. A list built that way can only shrink. What the first pass never wrote down at all — Settings → Experimental, the MCP Apps switch, `/clis`, the Issues pages, the Supervisor console — stayed invisible to every pass after it. What it did write down, it wrote down as one line: `/inference`, `/connectors`, `/settings/api_keys`, Outcomes and Gate Decisions each got a row that said "browser by choice", and no pass after that opened the page to count what was on it.

Two habits did the damage:

1. **"Settings" was one row.** The page has seven cards and four sub-pages, and the row stood in for about 160 items.
2. **"Stays in the browser" was accepted as a status.** It is not a reason, and because it was never challenged, the API gap behind each such row was never written down either.

This audit was derived from the web app's source instead: every HTML route a signed-in person reaches in `config/routes.rb` (382), every view and partial under `app/views` (183 files), and every Stimulus controller that adds behaviour (82). Five areas were enumerated independently from that source, then cross-checked against the routes census so nothing fell between them. A row is `web-only` only with a reason a phone user would accept — installing the PWA, a ⌘ shortcut, an admin console whose edit forms show plaintext secrets. Everything else that is not in the app is `missing`, with the API it needs named, and anything built in an open PR is marked with that PR.

## Totals

| Area | present | partial | missing | web-only | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| A Settings & account | 16 | 19 | 125 | 3 | 163 |
| B Session page | 90 | 18 | 20 | 3 | 131 |
| C Board & starting sessions | 79 | 24 | 11 | 1 | 115 |
| D Operations | 34 | 29 | 84 | 3 | 150 |
| E Global chrome | 20 | 5 | 10 | 8 | 43 |
| **Total** | **239** | **95** | **250** | **18** | **602** |

Counted from the rows below after removing the 44 duplicate copies of items two areas both rowed. Four rows in B are `present` only with #1282, and two in C are `partial` only with #1284, both open; the counts take them as those PRs leave them. The 205 Administrate routes under `/supervisor` and the GoodJob mount are one `web-only` row each in D, not 206.

## The biggest gaps, by how often they are hit

Ranked within each group by how often a person on a phone runs into it. The area letter and row location point into the matrix.

**App-only — the API already carries it; the app does not read or send it**

1. Health drops every number, table and action: process/session/system counts, retry budgets, post-deploy tasks, cron freshness, recent failures and errors, and the queue-recovery state — all in `GET /api/v1/health` (D, `_health_content.html.erb`, `health/_*.html.erb`; E `_queue_recovery_mode_banner`).
2. Costs decodes `total_cost_usd`, `by_day(day,cost_usd)`, `by_agent_root`, `by_model`, `top_sessions` and discards the rest: ledger coverage, token/call tiles, per-day drilldown, cost by token kind, by feature, by thread kind, by runtime, by ad-hoc source, burn rates (D, `costs/show.html.erb`).
3. Board rows do not show genesis, precedence or (on Ranked/flat views) the agent root, and only the newest PR is reachable — all already in `session_json` / `board_row` (C `_session_card:95-108`, `_user_view_row:133`, `_ranked_row:178`, `_github_pr_link`).
4. The new-session form lacks the auto-compact window, precedence, `/` slash commands, attachments on the first prompt and Clone Only; the first two are permitted on `POST /api/v1/sessions` today (C `new.html.erb:196-246, 256, 430`).
5. The trigger page omits scheduling class, precedence, the catalog chips, the coalescing window and the missed-fires date, and Run Now cannot fill `{{variables}}` — the API returns every field and accepts `variables` (D `triggers/show.html.erb:67-72, 318-457`).
6. The Quick Router sends no page context and always opens the new session; the ingest takes `page_url` / `page_title` / `page_context` and the web has Submit-in-background (C `_chat_bubble.html.erb:127, 160-166`).
7. Camera capture and paste-an-image are absent from the Quick Router and the first prompt; the session composer has paste but no camera (B `_follow_up_form:174-179`, C `index.html.erb:505-515`, `_chat_bubble:64-104`).
8. Promote/demote and heartbeat are on the session page only, not on the row (C `_ranked_row:100-111`, `_session_heartbeat` on the card); the session page does not show the session's cost though `GET /api/v1/costs?session_id=` exists (B `_detail:123`).
9. Verbose logs are unreachable (`logs?level=` exists) and subagent transcripts are a separate modal rather than inline (B `timeline_items/_log`, `subagent_transcripts/_accordion`).
10. Supervisor and the Jobs dashboard have no "Open in browser" row under More (E `sessions/index.html.erb:72, 79`); "Set up a new authenticator" could open `/login/second_factor/setup` in the sign-in sheet (A `_web_sign_in:25`).

**Needs a route opened to the app's token (`accepts_native_app_tokens`)**

11. Trigger create, edit and delete, plus the Slack channel and WhatsApp chat pickers — `POST/PATCH/DELETE /api/v1/triggers`, `#channels`, `#whatsapp_chats` exist and permit every form field (D `triggers/_form.html.erb`, `_condition_fields.html.erb`).
12. The two trigger switches, Enqueue messages and Resuscitate archived — the API half is in #1318; the app half is not written (D `triggers/show.html.erb:264-287`).
13. Health's operator actions: clean up orphans, retry failed, trash old, enter/exit queue recovery, re-arm post-deploy tasks, discard/reschedule queued jobs — all exist under `/api/v1/health` (D `_health_content:69, 138, 607`, `_queue_recovery_mode`, `_queued_job_maintenance`, `_post_deploy_tasks:112`).
14. CLIs: status, the attention badge, refresh and clear cache — `api/v1/clis#status/refresh/clear_cache` exist (A `clis/*`, E nav badge).
15. Outcomes, gate decisions and the work backlog: `outcome_analyses#index/show`, `goal_checks#index`, `gate_decisions#index/show`, `work_backlog_items#index/show/start_now/pin/unpin/remove/hold` exist (D, three sections). Analyze/analyze-all/cancel, stats, the issue trend, the GitHub read and gate feedback need new routes.
16. Costs "Sweep now" — `POST /api/v1/costs/backfill` exists (D `costs/show:106-109`).
17. Add and remove a model — `POST`/`DELETE /api/v1/model_catalog_entries` exist; index is already open (A `model_catalog_entries/index.html.erb:43-86, 155-160`).

**Needs a new API**

18. The Inference page: account roster, per-account quota windows, refresh/switch/delete, the CLI login flow, the rotation log, the OpenRouter key, the spot gate, backlog top-up and genesis classes — 47 rows, no REST at all; MCP `get_spot_policy` / `action_spot_policy` cover the policy half (A §2).
19. App settings read and write: the global default runtime and model, the three experimental toggles, the MCP Apps switch and allowlist, catalog pins — MCP covers all but MCP Apps and pins; REST for all but the pins is in #1341, open (A §1).
20. API keys and OAuth grants, including the phone's own grant: list, mint, revoke, restore, change privilege — nothing under `/api/v1` (A §4, E).
21. Connectors: per-server state, the secret-store banner, start and complete an MCP OAuth flow from the phone, disconnect, unclaimed credentials — nothing under `/api/v1`; the session page already hands OAuth to the browser (A §3).
22. Rich transcript rows: thinking, compaction, error, runtime notices, queue events, MCP logs, image badges, tool parameters, `is_error`, `#message-N` anchors, MCP App views — `conversation` emits user/assistant/tool only (B `timeline_items/_item.html.erb`).
23. Fields the board and session page need: `last_timeline_entry_at` (running elapsed), per-session cost on the index, `off_board_count`, `merge_authorized_at`, the web `refresh` semantics (restart + nudge), `failure_summary` / `failure_detail` (B, C).
24. Per-session push toggle, auto-compact window edit, `touch_activity`, the scratch path, `sent_message` restore (B `_session_header_actions:26-43`, `_session_metadata:409-456`, `_github_pr_link`).
25. Attachments on `POST /api/v1/sessions`, and a `genesis` for native-app creates: today a phone-created session is `genesis: api`, which classifies as spot while the web's default is priority (C `new.html.erb:216-232, 273-346`).
26. Catalog refresh and catalog health on `/configs`; identity (`/me`), sign-out-everywhere, server deploy info; external-app (plugin) management (REST; MCP exists); trigger `spent_one_shot_wake` and the pending-session id; a push channel for live updates or an accepted poll (C `new.html.erb:14-33`; A §1, §5; D; C `index.html.erb:30`).

**Needs something outside this repo**

27. Universal links: a tapped `https://<zimmer>/sessions/:id` never opens the app. Needs the Associated Domains entitlement enabled in the Apple developer portal, plus an `apple-app-site-association` served by Rails and `onOpenURL` in the app (E).

## Matrix

### A Settings & account

163 rows: 16 present, 19 partial, 125 missing, 3 web-only.

#### 1. `/settings` — `SettingsController#show`, `app/views/settings/show.html.erb`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `settings/show.html.erb:6` back link to `root_path` | Return to the board | `SettingsView.swift:75` Done button (sheet) | present | Navigation only |
| `settings/_web_sign_in.html.erb:5-13` "Sign-in" card: signed in as `<email>` with Google; authenticator age; recovery codes left | Shows the web identity, when TOTP was enrolled, and how many recovery codes remain | `SettingsView.swift:13-19` "Signed in to" shows the server host only | partial | iOS shows the host, not who is signed in; TOTP age and recovery-code count absent. needs API: a `/api/v1/me` read (email, TOTP enrolled at, recovery codes left) |
| `_web_sign_in.html.erb:15-19` "Off" state with `ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID` hint and docs link (when web sign-in is not configured) | Says sign-in is off for this deployment | — | missing | Informational: the phone cannot sign in at all without web sign-in (`/oauth/authorize` needs it). needs API: the same identity read, returning not-configured |
| `_web_sign_in.html.erb:25` "Set up a new authenticator" → `GET login/second_factor/setup` (`web_second_factors#setup`), only `if web_auth_configuration.totp_required?` | Re-enroll TOTP, shows QR + secret, then recovery codes | — | missing | needs API: TOTP re-enrol (issue secret / otpauth URI, confirm code, return recovery codes); see section 7 |
| `_web_sign_in.html.erb:28` "Sign out" → `DELETE /logout` (`web_sign_ins#destroy`) | End this browser's web session | `SettingsView.swift:57` "Sign out" → `AuthSession.signOut` revokes the OAuth grant at `/oauth/revoke` (`AuthSession.swift:123`), unregisters APNs | present | Different mechanism, same outcome for the device |
| `_web_sign_in.html.erb:30` "Sign out everywhere" → `POST /logout/everywhere` (`web_sign_ins#destroy_everywhere`), confirm dialog | Invalidate every browser session for this identity | — | missing | needs API: `POST /api/v1/...` sign-out-everywhere (and whether it should also revoke the phone's own OAuth grant) |
| `show.html.erb:21-42` "Session Defaults" banner: active global default `runtime / model` or "No global override set — using the built-in default (Claude Code / opus)" | Read the global base runtime+model and whether it is an override | — | missing | MCP only: `get_app_settings`. needs API: `GET /api/v1/app_settings` |
| `show.html.erb:44-57` Runtime `<select>` (`app_setting[default_runtime]`, Stimulus `runtime-select`) | Pick the global default runtime (`RuntimeRegistry.registered_runtimes`) | — | missing | Runtime list is already in `GET /api/v1/configs` (`Catalog.swift` reads it); write is MCP only (`action_app_settings set_session_defaults`). needs API: `PATCH /api/v1/app_settings` |
| `show.html.erb:64-79` Model `<select>` (`app_setting[default_model]`, Stimulus `model-select`, options scoped to the selected runtime, hidden field) | Pick the global default model; reset to the runtime's default when runtime changes | — | missing | Same as above; validation pair (runtime ⨯ model) lives on `AppSetting` |
| `show.html.erb:83` "Save session defaults" → `PATCH /settings/session_defaults` (`app_settings#update`) | Persist both, audit-logged as `web:/settings` | — | missing | MCP only (`action_app_settings`). needs API |
| `show.html.erb:85-88` hint "pick Claude Code / opus and save to return to the built-in default" | Explains that the built-in pair clears the override | — | missing | Follows the row above |
| `show.html.erb:96-110` "Models" card → `GET /settings/models` "Manage models" | Link to the model catalog page | — | missing | See section 4; `GET /api/v1/model_catalog_entries` exists and accepts the app token (index only) |
| `show.html.erb:113-127` "API keys" card → `GET /settings/api_keys` "Manage API keys" | Link to keys + OAuth grants page | — | missing | See section 5; the phone's own connection is listed there (`SignInView.swift:88` tells the user so) but the app cannot show it |
| `show.html.erb:130-144` "Zimmer plugins" card → `GET /settings/plugins` "Manage plugins" | Link to external apps page | — | missing | See section 6; MCP `search_external_apps` / `action_external_app` exist, no REST |
| `show.html.erb:147-154` "Experimental" card header | Explains the toggles are unstable features with a stated default | — | missing | — |
| `show.html.erb:164-173` + `_experimental_toggle.html.erb:9-12` per-toggle status banner "`<title>` is ON/OFF (recommended default)" (amber when it differs from default) | Read each experimental toggle and whether it matches the shipped default | — | missing | MCP only: `get_app_settings` lists each key with value and default. needs API: `GET /api/v1/app_settings` |
| `_experimental_toggle.html.erb:24-31` toggle "MCP tool search" (`app_setting[mcp_tool_search_enabled]`, default ON, `onchange` submits the form) | Spawn Claude Code sessions with `ENABLE_TOOL_SEARCH=true` | — | missing | `ExperimentalSettingsRegistry::BUILT_INS[0]`; write MCP only (`set_experimental_setting mcp_tool_search`). needs API |
| `_experimental_toggle.html.erb:24-31` toggle "Warm clones for every active root" (`app_setting[warm_clone_pool_active_roots_enabled]`, default OFF) | Pool git clones for every root active in the last week, not just the router's | — | missing | Key `warm_clone_pool_active_roots`; `/health → Warm clone pool` links back here. needs API |
| `_experimental_toggle.html.erb:24-31` toggle "Warm Quick Router process" (`app_setting[warm_router_process_enabled]`, default OFF) | Keep one idle Claude Code process booted for the Quick Router (~250 MB RAM) | — | missing | Key `warm_router_process`; `/health → Warm router process` links back here. needs API |
| `show.html.erb:164-173` registry-driven rows for experimental Zimmer Extensions (`app_setting[extensions][<id>]`, `extension_states` jsonb) | One toggle per registered experimental extension | — | missing | Zero rows on `main` (no extension class resolves) but the surface is live; `action_app_settings` accepts `extension.<id>`. needs API returning the dynamic list |
| `show.html.erb:176` "Save experimental settings" → `PATCH /settings/session_defaults` | Persist the toggles (each toggle also auto-submits) | — | missing | MCP only. needs API |
| `show.html.erb:184-193` "MCP Apps" card header | Explains `ui://` views render sandboxed HTML from the server operator, off by default | — | missing | — |
| `show.html.erb:201-211` checkbox "Render MCP App views" (`app_setting[mcp_apps_enabled]`, master switch) | Enable rendering MCP App views in transcripts | — | missing | No MCP tool by design (`McpApps::Policy`: "a human's call"). That argument covers agents, not the operator on a phone. needs API: a REST write open to the human-held token, or an explicit web-only decision with a reason |
| `show.html.erb:213-240` fieldset "Servers allowed to render views": one checkbox per remote catalog MCP server (`app_setting[mcp_apps_allowed_servers][]`, `McpApps::Policy.eligible_servers`), or "No remote MCP servers in the catalog." | Per-server opt-in allowlist; stdio servers are not offered | — | missing | `GET /api/v1/mcp_servers` (open to the app) lists servers but not whether each is remote/eligible or allowed. needs API: eligible list + allowlist read/write. The phone's transcript does not render MCP App views either (area B) |
| `show.html.erb:243` "Save MCP Apps settings" → `PATCH /settings/session_defaults` | Persist switch + allowlist | — | missing | needs API |
| `show.html.erb:256-289` "Notifications → Push Notifications" toggle (Stimulus `push-subscription`: Web Push permission, VAPID key from `<meta>`, `POST/DELETE /push_subscriptions`) with status line | Subscribe / unsubscribe this browser for Web Push | `SettingsView.swift:33-48` Notifications status + "Turn on notifications"; `PushCoordinator.swift` registers APNs via `POST /api/v1/apns_devices`, unregisters on sign-out | present | Platform-native equivalent; the web blocked / not-supported states map to iOS "Off" / "Change it in iOS Settings → Zimmer" |
| `show.html.erb:291-300` "blocked in browser" / "not supported" messages | Explain why the toggle cannot be turned on | `SettingsView.swift:47` footer | present | — |
| `show.html.erb:308-383` "Catalog Pins" card (only when a pinnable catalog exists): per catalog name, "Pinned to `<ref>`" or "Tracking latest HEAD", resolved SHA | Read each AIR catalog's pin state | — | missing | Hidden on the default self-contained catalog, live on any deployment with a remote catalog. No REST, no MCP. needs API: `GET /api/v1/catalog_pins` |
| `show.html.erb:346-368` per-catalog "Pin to ref" text input + "Pin to current HEAD" (Stimulus `catalog-pin#pinToHead`, only `if cp[:head_sha].present?`) + "Clear" | Edit a pin: type a SHA/tag/branch, copy HEAD into it, or blank it to track HEAD | — | missing | needs API: `PATCH /api/v1/catalog_pins` |
| `show.html.erb:374-378` "Save catalog pins" → `PATCH /settings/catalog_pins` (`catalog_pins#update`), re-resolves the catalog, rejects unknown refs | Persist pins and refresh `AirCatalogService` | — | missing | needs API (same) |
| `show.html.erb:386-411` "Deployment Information → Git": commit SHA (short, full in `title`), branch, commit date | Which build is running | `SettingsView.swift:49-55` "This build" shows the *app's* version and `env=… host=… source=…` (`AppEnvironment.swift`), not the server's commit | partial | iOS shows the phone build, not the server deploy. needs API: server git SHA/branch/date (e.g. on `GET /api/v1/health`, which returns only `ruby_version`) |
| `show.html.erb:414-430` "Environment": Rails env, Ruby version, Rails version | Server runtime versions | — (`GET /api/v1/health` returns `ruby_version`; `HealthView` does not display it — grep "ruby" in `OperationsViews.swift` → no hit) | missing | needs API: `rails_env`, `rails_version` next to `ruby_version`; render in `HealthView` or a server-info screen |
| `show.html.erb:433-447` "MCP Servers" `<details>`: full `mcp.json` config, secrets redacted, server count | Inspect the loaded MCP server config | — (`GET /api/v1/mcp_servers` gives name/title/description/startable, not the full redacted config; iOS uses it only in the new-session form) | partial | needs API: the redacted full config (`DeploymentInfoService.mcp_config_with_redacted_secrets`), or at least a count |
| `show.html.erb:450-464` "Agent Roots" `<details>`: full `roots.json`, count | Inspect the loaded roots | — (`GET /api/v1/configs` `agent_roots` is read for the new-session form, `CatalogAPI.swift`; no screen shows the raw config) | partial | Data mostly exists; no iOS view |
| `show.html.erb:467-481` "Skills" `<details>`: full `skills.json` (internal keys stripped), count | Inspect the loaded skills | — (`GET /api/v1/skills` is read for the new-session form; no screen shows the catalog) | partial | Data exists; no iOS view |

#### 2. `/inference` — `InferenceController`, `SpotPoliciesController`, `FleetTopUpPoliciesController`, `GenesisClassesController`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `inference/show.html.erb:7` back arrow | Return to the board | `RootView.swift` tabs | present | Navigation |
| `show.html.erb:14-21` "Refresh All" → `POST /inference/refresh_all` (Claude tab) | Re-probe every account's quota; turbo-streams cards, pool, alert, spot gate | — | missing | needs API: `POST /api/v1/inference/refresh_all` |
| `show.html.erb:23,27-38` runtime tabs (Claude Code / Codex / Pi) + subtitle | Switch the page's runtime | — | missing | Runtimes are in `GET /api/v1/configs`; needs API: per-runtime inference state |
| `show.html.erb:40` → `_pi_panel.html.erb:7-26` OpenRouter key Set / Not set badge, variable name (:29-33), resolving provider badge (:35-43), SHA-256 fingerprint (:45-50), last set from this page + how (:52-60), Parameter Store address (:61-68, if `status.path`) | Read the Pi runtime's OpenRouter key status without exposing the secret | — | missing | needs API: `GET /api/v1/inference/pi/openrouter_key` (status only) |
| `_pi_panel.html.erb:80-98` password field + "Save key" / "Replace key" → `PUT /inference/pi/openrouter_key` (if `status.writable?`) | Write the key to the secret store | — | missing | needs API: `PUT` |
| `_pi_panel.html.erb:100-110` "Delete key" (confirm) → `DELETE /inference/pi/openrouter_key` (if deletable), else "Delete is unavailable" note | Remove the key | — | missing | needs API: `DELETE` |
| `_pi_panel.html.erb:111-137` not-writable explanation + missing IAM permissions list | Why Zimmer cannot write the key | — | missing | needs API: `write_reason`, `missing_permissions` |
| `_pi_panel.html.erb:140-153` Pi models this key drives | List of Pi models | `Catalog.swift` pickers (via `GET /api/v1/configs` `runtime_models`) | partial | Data present in the new-session picker, no inference screen |
| `show.html.erb:47` → `_pool_alert.html.erb:7-26` dry-pool banner | No account can serve: why, and how to recover | `OperationsViews.swift:682` HealthView "Auth" (status + message) | partial | `GET /api/v1/health` `auth_health` is Claude-only and lacks the breakdown/recovery text |
| `_aggregate_stats.html.erb:42` pool capacity banner with "work unblocked in" countdown | When held work resumes | — | missing | MCP `get_spot_policy` only; needs REST |
| `_aggregate_stats.html.erb:44-61` Total / Active / Quota Exceeded / Needs Reauth counts | Pool composition | HealthView "Auth" (available count in message) | partial | `auth_health` has available/serviceable/needs_reauth/refused, not the same four |
| `_aggregate_stats.html.erb:63-106` average 5-hour and 7-day utilization bars, worst account, weekly reset (local time) | Pool utilization | — | missing | MCP `get_spot_policy`; needs REST |
| `_capacity_line.html.erb:13-33` dollars remaining, capacity, priority reserve, spot share, estimate provenance per window; "No dollar estimate yet" | Dollar view of each window | — | missing | MCP `get_spot_policy`; needs REST |
| `_aggregate_stats.html.erb:108-109` "No usage data" | Empty state | — | missing | — |
| `_spot_gate.html.erb:9-22` "Spot vs priority" card header | Explains the gate | — | missing | — |
| `_spot_gate.html.erb:35-47` toggle spot gating on/off (`spot_gating_enabled`) | Master switch for the gate | — | missing | MCP `action_spot_policy set_gating enabled`; needs REST `PATCH /api/v1/inference/spot_policy` |
| `_spot_gate.html.erb:51-79` "Max sessions at once" (`spot_max_concurrent_sessions`) + worker-pool warning (:67-78, `ceiling_out_of_reach?`) | Concurrency ceiling | — | missing | `set_gating max_concurrent_sessions`; needs REST |
| `_spot_gate.html.erb:81-111` 5-hour and weekly priority reserve % (`spot_reserve_five_hour_pct`, `spot_reserve_weekly_pct`) with derived dollars | Reserve for priority work | — | missing | `set_gating five_hour_reserve_pct / weekly_reserve_pct`; needs REST |
| `_spot_gate.html.erb:121-139` checkbox preemption (`spot_preemption_enabled`) | Let priority work take a spot slot | — | missing | `set_gating preemption_enabled`; needs REST |
| `_spot_gate.html.erb:145-166` starvation age ceiling hours (`spot_starvation_age_ceiling_hours`, max 720) | Promote long-held spot work | — | missing | `set_gating starvation_age_ceiling_hours`; needs REST |
| `_spot_gate.html.erb:173` "Save spot policy" → `PATCH /inference/spot_policy` (`spot_policies#update`) | Persist the six fields | — | missing | needs REST |
| `_spot_gate.html.erb:180-209` live decision (running / held, reason, detail, what lifts it) | Current gate verdict | `WaitingBanners.swift` per-session `spot_hold` banner | partial | Fleet-level verdict is MCP `get_spot_policy` only |
| `_spot_gate.html.erb:218-256` paused / preempted / held + overdue / starvation-lane counts | Gate effects | — | missing | MCP `get_spot_policy`; needs REST |
| `_spot_gate.html.erb:266-340` sessions on a worker of the cap, awaiting, fleet burn $/min, 5-hour and weekly spot budget left, pacing per window, accounts read | Gate inputs | — | missing | MCP `get_spot_policy`; needs REST |
| `_spot_gate.html.erb:353-363` "Sessions no trigger started" heading, copy, link to triggers (:361) | Genesis class intro | Triggers tab (`RootView.swift`) | partial | Link target only |
| `_spot_gate.html.erb:354-356` "Reset to defaults" → `DELETE /inference/genesis` (`genesis_classes#destroy`) | Clear `genesis_class_overrides` | — | missing | MCP `action_spot_policy reset_genesis_classes`; needs REST |
| `_spot_gate.html.erb:370-445` per genesis kind (cards on mobile, table on desktop): label, key, current class, "changed from", description, live count | Read genesis classes | — | missing | MCP `get_spot_policy`; needs REST |
| `_spot_gate.html.erb:392,434` "Make spot" / "Make priority" → `PATCH /inference/genesis/:genesis` (`genesis_classes#update`) | Reclassify a genesis kind | — | missing | MCP `promote_genesis` / `demote_genesis`; needs REST |
| `_fleet_top_up.html.erb:9-25` "Backlog top-up" header, link to triggers (:14) | Explains fleet-idle top-up | — | missing | — |
| `_fleet_top_up.html.erb:31-58` "Top up while under" ceiling (`fleet_idle_max_sessions`) + out-of-reach warning (:46-57) | Top-up ceiling | — | missing | MCP `action_spot_policy set_top_up max_running_sessions`; needs REST `PATCH /api/v1/inference/fleet_top_up` |
| `_fleet_top_up.html.erb:59-109` idle minutes (`fleet_idle_threshold_minutes`), min fire interval (`fleet_idle_min_fire_interval_minutes`), quiet-backlog floor (`fleet_idle_quiet_backlog_interval_minutes`) | Top-up timing | — | missing | `set_top_up idle_minutes / min_fire_interval_minutes / quiet_backlog_interval_minutes`; needs REST |
| `_fleet_top_up.html.erb:112-116` "Save top-up policy" → `PATCH /inference/fleet_top_up` | Persist | — | missing | needs REST |
| `_fleet_top_up.html.erb:124-207` status: room / at ceiling badge, turns on a worker, awaiting split, headroom, asleep, under ceiling since, last fired, next fire, footnote | Top-up state | — | missing | MCP `get_spot_policy`; needs REST |
| `show.html.erb:70-92` "Accounts" list per runtime, or empty state | Account roster | — | missing | needs API: `GET /api/v1/inference/accounts?runtime=` |
| `_account_card.html.erb:6-32` email, Current badge, status badge, "Probe failed" tooltip, quota-hit count, reading age, API-key badge (Codex), "No tokens", "Token refused" + reason | Per-account state | — | missing | needs API (`auth_health` gives only a refused count) |
| `_account_card.html.erb:33-42` "Refresh" → `POST /inference/refresh_account/:id` (not Codex) | Re-probe one account | — | missing | needs API |
| `_account_card.html.erb:57-65` "Switch" / "Re-activate" (confirm; disabled without tokens) → `POST /inference/switch_account/:id` | Make this the current account | — | missing | needs API |
| `_account_card.html.erb:66-69` "Delete" (confirm) → `DELETE /inference/account/:id` | Remove account (current → next activates) | — | missing | needs API |
| `_account_card.html.erb:73-84` Codex auth note | Static explanation | — | missing | — |
| `_account_card.html.erb:89-149` 5-hour and 7-day bars, window status, reset lines, headroom-unusable note, plan + tier, "No quota data" | Per-account quota snapshot | — | missing | needs API: per-account snapshot |
| `_login_panel.html.erb:10-26` last login failed/expired + reason, credential sentence, "Authenticate" / "Re-authenticate" → `POST /inference/accounts/:id/login` (`inference#start_login`) | Start the CLI OAuth/device login for an account | — | missing | needs API: start login |
| `_login_attempt.html.erb:4-58` poller; "Cancel login" → `POST /inference/login/:attempt_id/cancel`; "Starting the login CLI…"; verification link (`_verification_link.html.erb:9-15`); one-time device code (Codex, :27-34); paste-code field + Submit → `POST /inference/login/:attempt_id/code` (`awaiting_code`); "Finishing sign-in…"; humanized status | Drive the login attempt to completion | — | missing | needs API: login status JSON (the web `GET /inference/login/:attempt_id` already answers JSON, but outside `/api/v1`), submit code, cancel. The phone can open the verification URL natively |
| `_login_attempt_lost.html.erb:5-12` "Login no longer tracked" | Attempt vanished; polling stops | — | missing | needs API |
| `_add_account_form.html.erb:5-45` "Add account" disclosure: hidden runtime, Email (required), Priority, optional OpenAI API key (Codex), Claude note, submit → `POST /inference/add_account` | Create an account row | — | missing | needs API: `POST /api/v1/inference/accounts` |
| `show.html.erb:98-163` Rotation Log table (Time, From, To, Reason, Source, Triggered By; ≤50 per runtime, if any) | Account rotation history | — | missing | needs API: `GET` rotation events |
| `show.html.erb:148` link to the session that triggered a rotation | Jump to the session | `SessionDetailView.swift` | present | Target only |
| `show.html.erb:166-191` "Account management" help (Codex vs Claude text) | Static help | — | missing | — |

#### 3. `/connectors`, the MCP OAuth flow, `/clis`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `connectors/index.html.erb:6-17` back arrow, title, intro | Page frame | — | missing | No entry point in `MoreView` |
| `connectors/index.html.erb:22-26` → `GET /connectors/secret-store` (`connectors#secret_store`), "Checking…" placeholder | Eager frame for the secret-store banner | — | missing | needs API: secret-store status (MCP `get_system_health` has a Secret Store section) |
| `connectors/_secret_store.html.erb:185-200` (if `store`) "Secrets resolve from Parameter Store": project, location, namespace, fallback path | Where secrets come from | — | missing | needs API |
| `_secret_store.html.erb:208-227` (if `legacy_namespaces.any?`) legacy-namespace migration state and remaining variables | Migration progress | — | missing | needs API |
| `_secret_store.html.erb:236-247` "Held but not served" undecodable values | Bad secrets list | — | missing | needs API |
| `_secret_store.html.erb:250-282` IAM capability verdict (nil / unprobed / least_privilege / writes / cannot_read) | What the store credential may do | — | missing | needs API |
| `_secret_store.html.erb:283-294` (no store) "Secrets resolve from Rails credentials" + reason | Fallback state | — | missing | needs API |
| `connectors/index.html.erb:28-57` "Catalog servers" card: count + attention summary ("N need attention, listed first" / "Everything is configured", `connector-list` target :44) | Overview of connector health | `NewSessionView.swift:265-347` lists catalog servers with unavailable reasons, inside the new-session picker only | partial | `GET /api/v1/mcp_servers` has unavailable flags; needs API: per-connector state summary |
| `connectors/index.html.erb:48-55` → `GET /connectors/*name` (`connectors#show`, 404 if unknown), `_connector_placeholder.html.erb:4-13` name/transport/"Checking…" | One lazy frame per server | — | missing | needs API: `GET /api/v1/connectors/:name` |
| `connectors/_server_identity.html.erb:4-12` title, catalog name, description, type + url or command + args | Identify the server | `NewSessionView.swift` shows title/description only | partial | `GET /api/v1/mcp_servers` lacks url/command |
| `connectors/_connector.html.erb:10-15` state badge (Ready / Missing configuration / Needs authorization / Token expired / Needs re-auth / Unavailable) + summary sentence | Connector state | picker's unavailable reason only | partial | needs API: the full state enum |
| `_connector.html.erb:20-26` (if `requires_periodic_reauth?`) "no refresh token" note | Re-auth cadence warning | — | missing | needs API |
| `_connector.html.erb:30-42` (if `variable_sources.any?`) badge per `${VAR}` naming the provider that resolved it | Which secret source served each variable | — | missing | needs API |
| `_connector.html.erb:44-138` (if `missing_configuration?`) "Where to set this": Secrets Console caption (:56-60), console link (:68-71), numbered steps (:73-77), gateway warning (:84-96), command + Copy (:98-115), snippet + Copy (:117-132), follow-up (:134) | Instructions to fix a missing secret | — | missing | needs API: missing vars + instructions |
| `_connector.html.erb:144-151` (if `authorizable?`) "Authorize" / "Re-authorize" → `POST /mcp_oauth/initiate` (session-less, `server_name`) | Start a session-less MCP OAuth flow | — (`WebAuthPresenter.swift` is used only for Zimmer sign-in, `AppModel.swift:511`) | missing | needs API: initiate (returns `authorization_url` + manual flag) and completion; the phone can run the provider page in `ASWebAuthenticationSession` |
| `_connector.html.erb:153-157` (if credential) "Authorized X ago · refresh token stored" | Credential metadata | — | missing | needs API |
| `_connector.html.erb:158-163` "Disconnect" (confirm) → `DELETE /connector_credentials/:id` (`mcp_oauth_credentials#destroy`) | Delete the stored OAuth credential | — | missing | needs API: `DELETE /api/v1/mcp_oauth_credentials/:id` |
| `connectors/index.html.erb:58-65` "No MCP servers in the catalog" | Empty state | picker empty state | partial | — |
| `connectors/index.html.erb:67-96` (if `@unclaimed_credentials.any?`) "Unclaimed credentials" card: server_name, url, stored-ago; "Delete" (confirm, :86-91) → `DELETE /connector_credentials/:id` | Credentials for servers no longer in the catalog | — | missing | needs API: list + delete |
| `connectors/index.html.erb:99-124` "How these statuses are determined" help | Static help | — | missing | — |
| `GET /mcp_oauth/status/:session_id` (`mcp_oauth#status`) → `mcp_oauth/_status.html.erb:4-82` per-server Authorized / Authorizing badges, Authorize form, "All MCP servers are authorized" | Per-session OAuth status panel (HTML or JSON) | — | missing | Dead on the web too (no caller, no Stimulus controller). Needs API only if parity is wanted |
| `POST /mcp_oauth/initiate` (`mcp_oauth#initiate`): refuses non-catalog/non-OAuth server when session-less (:68); already-authorized branches (:83, :91); pre-registered vs discovery (:118); flash errors for no metadata / endpoints / DCR failure / insecure token endpoint (:156-219); manual → render `manual`, else redirect to provider | Start the flow | — | missing | needs API |
| `GET /mcp_oauth/callback` (`mcp_oauth#callback`) | Provider redirect target: validates state/expiry/error/code, stores tokens, resumes the session, redirects to session or `/connectors` | — | missing | A hosted callback is fine; the app needs a way to start the flow and learn it finished |
| `mcp_oauth/manual.html.erb:6-58` "Authorize <server>" heading, inline error (:11-15), "Open authorization page" (:25-32), shows `redirect_uri` (:36), "Pasted redirect URL (or bare code)" textarea + "Complete authorization" (:45-52) → `POST /mcp_oauth/complete`, Cancel to `/connectors` or the session (:56-58) | Manual code-paste completion for providers without a reachable redirect | — | missing | needs API: `POST complete` equivalent |
| `mcp_oauth/error.html.erb:1-21` "OAuth Authorization Failed" + message + "Go Back" | Failure page | — | missing | — |
| `sessions/index.html.erb:191` → `GET /clis/badge` (`clis#badge`) → `clis/_cli_badge.html.erb:1-11` red count when `cli_issues > 0` | CLI attention badge on the board | — | missing | `GET /api/v1/clis/status` `unauthenticated_count` exists but is closed to the app token |
| `clis/index.html.erb:4-15` title, subtitle, "Back to Sessions" | Page frame | — | missing | — |
| `clis/index.html.erb:16-21` "Clear Cache" → `POST /clis/clear_cache` (`clis#clear_cache`, queues `CacheClearJob(reinstall: true)`) | Reinstall CLIs | — | missing | `POST /api/v1/clis/clear_cache` exists, closed to the app token; MCP `action_health cli_clear_cache` |
| `clis/index.html.erb:22-27` "Refresh" → `GET /clis/refresh` (`clis#refresh`, queues `CliStatusRefreshJob`) | Re-probe CLI status | — | missing | `POST /api/v1/clis/refresh` exists, closed to the app token; MCP `action_health cli_refresh` |
| `clis/index.html.erb:33-49` "Connect to Server": `ssh root@<tailscale ip or host>` + Copy | SSH hint | — | missing | needs API: server SSH host; arguably low value on a phone but copyable |
| `clis/index.html.erb:52-73` → `GET /clis/status` (`clis#status`) lazy frame; `_cli_status.html.erb:3-27` green "All CLI tools are installed and authenticated" / yellow "N need attention" | CLI status summary | — | missing | `GET /api/v1/clis/status` exists, closed to the app token |
| `clis/_cli_content.html.erb:7-108` per tool: name, key, version; Installed / Not Installed; Authenticated / Not Authenticated; details; install instructions + Copy; "ENV var not set" + copyable `VAR=…` (`auth_method == :env_var`); auth instructions + Copy; "Ready to use (via VAR)" | Per-CLI detail | — | missing | Same endpoint; open it with `accepts_native_app_tokens only: %i[status]` at minimum |

#### 4. `/settings/api_keys` — `ApiKeysController`, `api_keys/index.html.erb`, `_oauth_grants.html.erb`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `api_keys/index.html.erb:11-26` back link, header, explainer, link to plugins (:23) | Page frame | — | missing | — |
| `index.html.erb:30-45` (if `@minted_token`) "Created <name>" box with the one-time key; Quick Router hint (:38, if `quick_router?`) | Show a freshly minted key once | — | missing | needs API: `POST /api/v1/api_keys` returning the secret once |
| `index.html.erb:55` (if `@create_errors`) error banner | Validation / duplicate name | — | missing | same |
| `index.html.erb:62-88` create form: Name (required, ≤100), radio "What it opens" (Full API / Quick Router only), "Create key" → `POST /settings/api_keys` (`api_keys#create`) | Mint a key | — | missing | needs API: `POST` (name, grant) |
| `index.html.erb:93-105` "Keys" header: `API_KEYS` env-var fingerprint note, agent-reach note; "No keys" (:107) | List header / empty state | — | missing | needs API: `GET /api/v1/api_keys` |
| `index.html.erb:113-173` key row: name; Revoked / Retired (no longer in env) / Active badge; `API_KEYS` vs Minted source; "Quick Router only" badge; "Zimmer plugin: X" badge linking to the plugin (if `external_app?`); "Agent sessions use this key" badge (`SelfSessionInjector` digest, ctrl:143-149); fingerprint, last used (relative + UTC), created, revoked at | Read every key | — | missing | needs API: `GET` list |
| `index.html.erb:178-180` (if revoked) "Restore" → `POST /settings/api_keys/:id/restore` (`api_keys#restore`) | Un-revoke | — | missing | needs API |
| `index.html.erb:182-191` "Revoke" (confirm text varies: self-session / env / minted) → `POST /settings/api_keys/:id/revoke` (`api_keys#revoke`) | Revoke a key without a restart | — | missing | needs API |
| `_oauth_grants.html.erb:1-18` "MCP connections" section, explainer (acts-on-behalf vs relay), "No OAuth connections" (list capped at 50, ctrl:137) | OAuth grants list header | — | missing | needs API: `GET /api/v1/oauth_grants` |
| `_oauth_grants.html.erb:28-78` grant row: client name / "Unnamed client"; Revoked / Active; "Acts on your behalf" / "Relay only"; "Published by host" (CIMD) / "Self-registered"; approved by, last used, approved, level set + reason (if `scope_changed_at`), revoked + reason | Read every OAuth connection, including this phone's | — | missing | needs API: list. The app cannot see its own grant's privilege level after consent |
| `_oauth_grants.html.erb:83-88` (unless revoked) "Make relay only" / "Let it act on my behalf" (confirm) → `POST /settings/api_keys/oauth_grants/:id/privilege` (`api_keys#set_oauth_grant_privilege`) | Change a connection's privilege | — | missing | needs API |
| `_oauth_grants.html.erb:90-92` "Revoke" → `POST /settings/api_keys/oauth_grants/:id/revoke` (`api_keys#revoke_oauth_grant`) | Revoke any connection | `SettingsView.swift:57` "Sign out" revokes only this phone's own grant via `POST /oauth/revoke` (`AuthSession.swift:121`) | partial | needs API: revoke any grant |
| ctrl:56/67 alerts "Unknown privilege level", "connection is revoked" | Error feedback | — | missing | — |

#### 5. `/settings/plugins` — `ExternalAppsController`, `external_apps/index.html.erb`, `show.html.erb`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `external_apps/index.html.erb:6-21` back link, header, explainer | Page frame | — | missing | — |
| `index.html.erb:33` (if `@create_errors`) error banner; `index.html.erb:38-55` register form: Name (required), "What it is", "Register" → `POST /settings/plugins` (`external_apps#create`) | Register a plugin | — | missing | MCP `action_external_app create`; needs REST |
| `index.html.erb:63-84` "None registered." / per plugin: name → show page, Enabled / Disabled badge, description, trigger count, active key count, last invoked | List plugins | — | missing | MCP `search_external_apps`; needs REST |
| `show.html.erb:12-17` back, name heading; `show.html.erb:25-34` (if `@minted_token`) one-time key; `show.html.erb:36` (if `@update_errors`) banner | Show frame | — | missing | — |
| `show.html.erb:46-64` edit form: Name, "What it is", "Enabled" checkbox (off → 403 on all its keys without revoking) | Edit plugin | — | missing | MCP `action_external_app update`; needs REST |
| `show.html.erb:67-92` "Triggers it may invoke": one checkbox per allowlistable trigger (name, #id, status; ctrl:109-112 keeps already-allowlisted workflow triggers); "No triggers yet. Create one" link (:74-75); red "runs a workflow — untick it" (:86, if `workflow_backed?`); variables `{{v}}` + per-minute cap (:89-92) | Allowlist editor | `TriggersView` (`OperationsViews.swift:157`) lists triggers but not as a picker | missing | Read `GET /api/v1/triggers` (open); write MCP `update trigger_ids`; needs REST |
| `show.html.erb:101` "Save" → `PATCH /settings/plugins/:id` (`external_apps#update`) | Persist | — | missing | needs REST |
| `show.html.erb:108-119` keys header, rotation advice, "Create key" → `POST /settings/plugins/:id/mint_key` (`external_apps#mint_key`) | Mint a plugin key | — | missing | MCP `mint_key`; needs REST |
| `show.html.erb:121-142` "No keys yet." / key row: name, Revoked / Active, fingerprint, last used; "Revoke" → `POST /settings/plugins/:id/keys/:api_key_id/revoke` (`external_apps#revoke_key`) | Key list + revoke | — | missing | MCP `search_external_apps` `keys`, `revoke_key`; needs REST |
| `show.html.erb:152-165` "Connecting": MCP URL `/mcp/external_app`, tool names, REST equivalents (`/api/v1/external_app/triggers[/:id/invoke]`, plugin key only) | Static integration text | — | missing | — |
| `show.html.erb:169-189` "Recent sessions" (last 10): title → session, trigger name, age, status; "None yet." | Sessions the plugin started | `SessionDetailView.swift` as link target only | missing | needs API: sessions filtered by `external_app` (no such filter in `GET /api/v1/sessions` or MCP) |
| `show.html.erb:195-198` "Delete plugin" (confirm) → `DELETE /settings/plugins/:id` (`external_apps#destroy`) | Delete | — | missing | MCP `delete`; needs REST |

#### 6. `/settings/models` — `ModelCatalogEntriesController`, `model_catalog_entries/index.html.erb`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `model_catalog_entries/index.html.erb:6-21` back, header, explainer (CLI check) | Page frame | — | missing | — |
| `index.html.erb:34-41` error box (amber for `:unlisted`) | CLI does not know the id | — | missing | REST `POST` 422 carries it; closed to app |
| `index.html.erb:43-86` add form: Runtime select, Model id (required), Label, "Needs an interactive login" (`requires_oauth`), "Add it even if the CLI does not list it" (`allow_unlisted`), "Add model" → `POST /settings/models` (`model_catalog_entries#create`, `added_via: web_ui`) | Add a model without a deploy | — | missing | `POST /api/v1/model_catalog_entries` exists; needs `accepts_native_app_tokens` on create (or MCP `manage_models add`) |
| `index.html.erb:93-106` (if `@shadowed_entries.any?`) "Added models that are now built in" + "Remove" each | Shadowed entries | — | missing | `GET /api/v1/model_catalog_entries` `shadowed_by_built_in` (open, unused) |
| `index.html.erb:109-125` one card per runtime: label, id, count of added models; model id rows | Per-runtime catalog | `NewSessionView.swift:78-85,376-406`, `QuickRouterView.swift:118,133` pickers | partial | `GET /api/v1/configs`; no catalog screen |
| `index.html.erb:126` "Default" badge | Which model is the runtime default | `NewSessionView.swift:101` preselects, does not show | partial | `configs` `default` |
| `index.html.erb:129-141` Added vs Built-in; "CLI lists it" / "Not in CLI's list" / "Not checked"; "Login only" (if `requires_oauth`) | Provenance + CLI verdict | — (`ModelOption` drops these) | missing | `configs` has `source`, `cli_listed`, `requires_oauth`; `model_catalog_entries#index` too |
| `index.html.erb:145` label line (if label ≠ id) | Label | `ModelOption.title` | partial | — |
| `index.html.erb:148-153` (if entry) CLI note; "Added <date> via <channel>" | Entry metadata | — | missing | `GET /api/v1/model_catalog_entries` (`cli_note`, `added_via`, `created_at`) |
| `index.html.erb:155-160` "Remove" (confirm) → `DELETE /settings/models/:id` (`model_catalog_entries#destroy`, refuses if in use) | Remove an added model | — | missing | `DELETE /api/v1/model_catalog_entries/:id` exists, closed to the app; MCP `manage_models remove` |

#### 7. OAuth server consent screen and web sign-in / second factor

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `GET /oauth/authorize` (`oauth_server/authorizations#new`, ctrl:41: validates sign-in, allowed domain, client, redirect, PKCE S256, resource) → `oauth_server/authorizations/new.html.erb:2-55` "Connect <client>?", first-party vs third-party scope wording (:4-10), link to Settings → API keys (:12), client name + first-party / published-by-host / self-registered (:19-26), endpoint, "Signed in as", "Sends you back to" (:31-39), hidden request params (:51-55) | Consent screen | `OAuthSignIn.swift:41` + `WebAuthPresenter.swift:20` system sheet | present | Rendered in the sheet during sign-in |
| `new.html.erb:43` (if `@loopback_redirect`) amber loopback warning | Warns about a loopback redirect | n/a — iOS uses the `com.tadasant.zimmer:` scheme | web-only | Only a desktop/CLI client can present a loopback redirect |
| `new.html.erb:59-85` privilege radio Relay only / Acts on my behalf (never preselected); "Choose what this connection may do" error (:61, ctrl:58-63) | Pick the connection level | Sheet; `ios-app.md:366-373` documents the choice | present | Changing it later is section 4's gap |
| `new.html.erb:88-89` "Deny" (→ `access_denied`) / "Approve" → `POST /oauth/authorize` (`authorizations#create`, ctrl:50, issues the code) | Finish consent | Sheet; `OAuthSignIn.swift:59,68-69` handles code / "Sign-in was declined." | present | — |
| `oauth_server/authorizations/error.html.erb:1-4` for not configured (503, ctrl:140), not signed in (401, ctrl:147), domain refused (403, ctrl:154), invalid client/redirect (400, ctrl:165); `RedirectError` (ctrl:135) goes back to the client | Error page | Sheet; the user cancels; `OAuthSignIn.swift:68-69` surfaces `error_description` | present | — |
| `POST /oauth/token` (`tokens#create`: exchange_code :30, refresh with rotation :51, domain re-check :106) | Token exchange and refresh | `OAuthSignIn.swift:84,95`; `AuthSession.swift:158-164` | present | Machine endpoint |
| `POST /oauth/revoke` (`revocations#create`) | Revoke a token | `AuthSession.swift:121-127` on sign-out | present | Machine endpoint |
| `POST /oauth/register` (`registrations#create`, RFC 7591) | Dynamic client registration | Not needed: iOS is the built-in `zimmer-ios` client (`app/services/oauth_server/native_app.rb`) | web-only | For third-party MCP clients such as Claude.ai |
| `GET /.well-known/oauth-protected-resource(/mcp)`, `GET /.well-known/oauth-authorization-server(/mcp)` (`metadata#protected_resource` / `#authorization_server`), `OPTIONS` preflights (`metadata#preflight`) | RFC 9728 / 8414 discovery + CORS | Not used; iOS hard-codes the paths | web-only | Machine endpoints for MCP clients |
| `GET /login` (`web_sign_ins#new`, ctrl:17; redirects to `/` if signed in) → `web_sign_ins/new.html.erb:3-34`: allowed-domains sentence (if `usable?`), "Then enter a code" hint (if `totp_required?`), "Sign in with Google" → `POST /auth/google` (`web_sign_ins#create`, ctrl:25, 503 if unusable), misconfiguration notice with `@configuration.problems` (:22-34) | Google sign-in page | `SignInView.swift:4-9,68-82` opens the sheet (`AppModel.swift:493`) | present | Via sheet |
| `GET /auth/google/callback` (`web_sign_ins#callback`, ctrl:37: verifies state + TTL; no TOTP → finish; enrolled + trusted device → finish; enrolled → second factor; not enrolled → setup; 403 rejected domain / 502 exchange failed re-render login with `@error`) | Google return leg | Sheet | present | — |
| `GET /login/second_factor` (`web_second_factors#new`, ctrl:23; `require_totp_mode` :68, `load_verifying_identity` :72) → `web_second_factors/new.html.erb:3-24`: "Signed in with Google as <email>", code field (TOTP or recovery code), "Trust this browser" (TTL days), "Continue" → `POST /login/second_factor` (`#create` :27: totp / recovery_code with remaining count / locked 429 / mismatch 422), "Lost your second factor" docs link | Second-factor entry | Sheet (trusted-browser cookie is shared with Safari, `WebAuthPresenter.swift:10`) | present | — |
| `GET /login/second_factor/setup` (`web_second_factors#setup`, ctrl:48; `load_enrolling_identity` :78 — signed in means replacing) → `setup.html.erb:1-28`: "Set up a new authenticator" vs first-time wording (if `@replacing`), `otpauth://` link (:16), setup key grouped by 4 + account details (:19-20), code field + "Confirm" → `POST /login/second_factor/setup` (`#confirm_setup` :53, 422 on mismatch) | TOTP enrolment / replacement | Sheet for the first enrolment only; no entry point to *replace* from the app | partial | needs: an app entry that opens `/login/second_factor/setup` in the sheet (cheapest), or a TOTP re-enrol API |
| `recovery_codes.html.erb:1-18` one-time recovery codes list, trusted-device + session TTL note, "Continue to Zimmer" (`@return_to` back into authorize) | Show recovery codes once | Sheet | present | — |

### B Session page

131 rows: 90 present, 18 partial, 20 missing, 3 web-only.

#### Page frame and header

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `_detail.html.erb:37-44` (`turbo_stream_from` timeline/status/elicitations) | Subscribes the page to live Turbo Stream updates | SDV `poll()` :118-160 every 5 s running/waiting, 20 s otherwise; on foreground :421 | present | Polling, not push; a few seconds behind the web |
| `_detail.html.erb:37-38` `stream-visibility-recovery`, `cable-reconnect` | Backfills missed content after a dead socket / reopened PWA | SDV :421-423 polls on foreground | present | Equivalent outcome |
| `_detail.html.erb:38` `pull-to-refresh` (+ header `trigger` target :73) | Pull anywhere / on the sticky header to refetch | SDV `.refreshable` :597 | present |  |
| `_detail.html.erb:46-67` | "Session connection recovered" banner (`recently_recovered?`) | — | web-only | Announces an ActionCable re-subscribe; the app has no socket to recover |
| `_detail.html.erb:78-101, 154-175` | Drawer Close / "Open full page" (dashboard drawer) | NavigationStack back | present | The drawer is a desktop layout; push navigation is the phone's equivalent |
| `_detail.html.erb:103, 177` | Back to Sessions | nav back | present |  |
| `_detail.html.erb:111-113` mobile title; `:189-200` desktop `editable-title` (PATCH `update_title`) | Title; inline edit on desktop | SDV :732 title; Rename alert :528-537 → `PATCH /sessions/:id {title}` | present |  |
| `_detail.html.erb:115-117`, `_status_badge.html.erb:1-20` | Status pill ("Trashed" when archived), live-replaced (`session_X_status_badge`) | SDV :736 `StatusBadge` (SessionBadges.swift:8-33) | present |  |
| `_status_badge.html.erb:10-16` `time-since` | Elapsed-since-last-transcript-entry inside the running spinner, colour by age | — | missing | needs API: `last_timeline_entry_at` is not in `session_json` |
| `_detail.html.erb:118` | `#id` | SDV :748 | present |  |
| `_detail.html.erb:123` `session_cost_badge`; `_session_metadata.html.erb:12-22` cost + link to `costs_path` | Estimated inference cost on the phone header and in metadata | — (Costs tab only) | missing | API exists: `GET /api/v1/costs?session_id=`; not wired into the detail screen |
| `_detail.html.erb:203-220`, `_mobile_joystick.html.erb:299-312` `log-level-filter` (`?filter=`, localStorage) | Log level: Minimal / Condensed / Show Logs / Verbose; refetches transcript at that level | SDV :1017-1027 Minimal / Condensed / Verbose, client-side; logs on separate screen (SLV) | partial | "Show Logs" (logs interleaved) missing; the picker only appears when tool traffic exists |

#### Banners (mobile block `_detail.html.erb:132-150`, desktop `_session_metadata.html.erb:601-626`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `_mcp_oauth_required_banner.html.erb:10-35` (`mcp_oauth_initiate_path`) | "OAuth Authorization Required" + one Authorize button per server | WB via `waiting.banners[mcp_oauth_required]` → `open_in_browser` action (SDV :667-680) | present | Hands off to the browser; OAuth needs one anyway |
| `_auth_outage_banner.html.erb:7-32` | Quota exhausted / no usable login, resume sentence, pool reset time | WB `auth_outage` banner (server-built, `waiting_explanation.rb:82-93`) | present |  |
| `_spot_hold_banner.html.erb:40-237` | Spot hold / pause / preempted / promoted / stalled, as-of, waiting, re-check sentences | WB `spot_hold` banner | present | Server builds the same sentences |
| `_spot_hold_banner.html.erb:228-234` "Make this session priority" (PATCH `update_scheduling_class`) | Promote the held session | WB action `update_scheduling_class` → `PATCH /sessions/:id {scheduling_class}` | present |  |
| `_spot_starvation_admission.html.erb:8-20` | "Admitted by the starvation lane" | WB `starvation_admission` banner | present |  |
| `_queued_turn_banner.html.erb:19-100` | "Queued for a worker" + Force (POST `force_start` with `expected_victim_id`, confirm) | WB `queued_turn` banner; `force_start` confirm SDV :512-527 | present |  |
| `_mcp_oauth_reconnect_banner.html.erb:8-38` | "Authorization complete — reconnects on next turn" + Reconnect / Queue a reconnect message (POST `follow_up`) | WB `mcp_oauth_reconnect` → `follow_up` action | present |  |
| `_session_metadata.html.erb:601-610` | "Paused: quota limit" notice | WB `quota_limit_paused` banner | present |  |
| `_failure_details.html.erb:25-78` | Failure summary, exit status, exception class; MCP connection failure detail; "Actionable Error" extraction (`ExceptionMessageHighlighter`); full output | SDV :462-464, 1210-1239 reason / exit status / exception message / class | partial | No actionable-error highlight, no `failure_detail` (MCP connection detail), no `failure_summary` text. needs API: both fields serialized; highlights are server-side |
| `_failure_details.html.erb:25` gating `shows_failure_details?` (failed OR parked undelivered turn) | Also shown for a needs_input session whose turn died pre-agent | SDV gates on `status == failed` | partial | Parked-undelivered case not shown |
| `elicitations/_lost_elicitation_banner.html.erb:5-42` (live-replaced) | "Approval request expired / lost" + summary + time | WB `lost_elicitation` banner | present |  |
| `elicitations/_elicitation_banner.html.erb:1-133` `elicitation-form` (PATCH web `respond`) | Pending MCP elicitation with schema-driven fields (bool / enum / string / number), Accept / Decline / Dismiss; live-appended and removed | `ElicitationViews.swift` PromptCard + ElicitationSheet | present | in #1282 (`GET …/elicitations`, `PATCH /elicitations/:id/respond`) |
| `enqueued_messages/_undelivered_messages.html.erb:10-25` | "N messages were never delivered" list | WB :95-125 undelivered card | present |  |
| `waiting_explanation.rb:110-118` `pending_wake` | (API-only) "Asleep until …" | WB banner | present | iOS shows a banner the web page does not render |

#### Desktop metadata block `_session_metadata.html.erb`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `:7` | Created N ago | SDV :748, 765-768 age (updatedAt ?? createdAt) | present |  |
| `:23-45` `clipboard` | Root key + copy working directory path | SDV :771-792 agentRoot; `clone_path` decoded (ZK Session.swift) but not shown | partial | No copy of the clone path |
| `:46-64` `clipboard` | Scratch directory path + copy | — | missing | needs API: scratch path not in `session_json` (derivable from id, but the app should not hard-code server paths) |
| `:79-185` `catalog-multiselect` MCP (PATCH `update_mcp_servers`, turbo_stream re-render incl. `session_X_mobile_mcp_servers`) | MCP chips with connected/failed/pending dot, injected marker, plugin-derived read-only chips, `error-popover` on failed, inline editor with search | SP :269-355 chips, tally, tap-failed-for-error, Add/Edit → `CatalogEditorSheet` → `PATCH mcp_servers` | present | Plugin attribution shown by subtraction; no field names the plugin (#1320) |
| `:161-162` `_inherited_defaults` | "agent root default" chips when the session captured none | SP :269-355 / :377-428 root defaults | present |  |
| `:187-215` Skills (PATCH `update_catalog_skills`, grouped by category) | Skill chips + plugin-derived + editor | SP :377-428 → `PATCH catalog_skills` | present |  |
| `:218-245` Hooks (PATCH `update_catalog_hooks`) | Hook chips + editor | SP → `PATCH catalog_hooks` | present |  |
| `:248-275` Plugins (PATCH `update_catalog_plugins`, with descriptions) | Plugin chips + editor | SP → `PATCH catalog_plugins` | present |  |
| `:278-285` | Runtime label | SDV :771-792 | present |  |
| `:291-341` `editable-model` (PATCH `update_model`) | Model display + select | SDV `ModelPickerSheet` → `PATCH model` | present |  |
| `:351-398` `editable-effort` (PATCH `update_effort`) | Effort display + select (Default / levels) | SDV :902-920 Effort submenu → `PATCH effort` | present |  |
| `:409-456` `editable-auto-compact-window` (PATCH `update_auto_compact_window`) | Context window tokens, editable (claude_code only) | — | missing | needs API: `auto_compact_window` is serialized but no route/param updates it |
| `:468-490` scheduling class form (PATCH `update_scheduling_class`) | Derive / Priority / Spot + "now X, source" | SDV :922-932 → `PATCH {scheduling_class}` | present |  |
| `:494-514` precedence form (PATCH `update_precedence`) + Ranked view link | Precedence number + explanation | SDV :538-552 alert → `PATCH {precedence}` | present |  |
| `:518-596` `editable-goal` (PATCH `update_goal`) with catalog dropdown, clear | Goal name/Custom, editor | SP :179-231 + `GoalPickerSheet` :703-797 → `PATCH {goal}` | present |  |
| `:627` | `#id` footer | SDV header | present |  |
| `_session_metadata.html.erb:2` `data-live-region="replace"` (`session_X_metadata` broadcast) | Whole block re-rendered on change | poll re-reads `GET /sessions/:id` | present |  |

#### Header actions `_session_header_actions.html.erb` (live-replaced)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `:15-19` (PATCH `toggle_favorite`) | Favourite star | SDV :630-661 toolbar star → `POST toggle_favorite` | present |  |
| `_session_heartbeat.html.erb:3-58` `heartbeat` (PATCH `toggle_heartbeat`, `update_heartbeat_interval`) | Heartbeat popover: on/off + "Beat every" 30 s…1 h | SDV :962-990 → `PATCH heartbeat` | present |  |
| `:26-43` (PATCH `toggle_push_notifications`) | Per-session push notifications on/off | — | missing | needs API: no toggle route; `session_json` lacks `push_notifications_enabled` |
| `:46-67` `transcript-copy` (GET `transcript.text`) | Copy full transcript to clipboard | SDV :305-314 Copy Transcript → `GET /transcript` | present |  |
| `_github_pr_link.html.erb:13-168` + `session-activity` (POST `touch_activity`) | PR button with status + CI dot; multi-PR dropdown; click records "last touched" | SDV :751 PR chips (SessionBadges.swift:60-103); View PR menu | partial | Clicking a PR does not touch activity — needs API: no `touch_activity` route (#1308 covers open-marks-read) |
| `:78-82` (POST `refresh`) | Refresh transcript from filesystem | SDV Refresh Transcript → `POST refresh` | present |  |
| `_visibility_menu.html.erb:58-66, 70-134` `visibility` (PATCH `update_visibility`) | Snooze: 5 presets with computed times, custom datetime, Hide, Put back, status | SDV snooze presets + `CustomSnoozeSheet` + Hide + Put back → `PATCH visibility` | present |  |
| `:88-95` (POST `pause`) when running | Pause session | SDV Pause (running only) → `POST pause` | present |  |
| `:102-109` (POST `restart`, `restart_confirmation`) when `restartable_by_hand?` | Restart with the three-way takeover confirm | SDV :431-443 + `SessionControls.swift:83-103` | present | Gate is failed/needs_input; web adds `!blocked_on_elicitation?` — minor |
| `:111-126` (POST `unarchive`) + trash expiry | Restore + "Expires N from now / Deletion pending" | SDV Restore; :755 Expires label | present |  |
| `:128-145` `archive-countdown` (POST `archive`, undo via flash) | Trash (clone kept 7 days) with Undo toast | SDV :507-509 Trash + queued-messages confirm; Undo on board | present |  |

#### Panel group `_detail.html.erb:249-338`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `_status_panel.html.erb:39-115` (POST `regenerate_status_summary`, live-replaced) | Status summary: markdown, "up to date as of / N messages since", generating, failed, abandoned, unavailable reason, Regenerate button | SDV :1149-1206 summary, spinner, error, freshness, Regenerate; menu Generate when none | partial | "cannot be regenerated: <reason>" and the abandoned state not shown (API `status_summary` lacks `unavailable_reason`) |
| `_status_panel.html.erb:81` `status-panel` `#message-N` fragment → transcript | Summary links jump to a transcript message | links open as URLs | missing | No message anchors in the app (needs API: `conversation` has `transcript_index` but no stable anchor/scroll target) |
| `_goal_check_panel.html.erb:19-72` (live-replaced) | Verdict pill, met count, delegated sessions, per-criterion marks, note | SP :100-174 | present |  |
| `_session_hierarchy.html.erb:34-217` (deferred frame, `disclosure-memory`, live-replaced) | Hierarchy tree: depth, root label, status, genesis·class pill, "drawn under", truncation, footnotes | SP :434-576 | present | Only shown with >1 node; web shows the solitary sentence too |
| `_session_hierarchy.html.erb:134-170` (DELETE `session_uncle_link`) | "also senior" uncle chips with × remove (confirm) | SP uncle chips + × → `DELETE uncle_links` | present |  |
| `_session_hierarchy.html.erb:220-338` | Human messages: here/elsewhere counts, capture gaps + roster link, entries with channel, "said in #N", time, content | SP :582-697 | present |  |
| `_session_hierarchy.html.erb:322-324` | "view in Slack" permalink per entry | — | missing | needs API: `human_messages` JSON has no `slack_permalink` (#1320) |
| `_session_notes_sidebar.html.erb:4-86` `session-notes` (PATCH `update_notes`, autosave 1.5 s, manual save) | Notes sidebar (desktop) / drawer (mobile) | SP :234-264 row + `TextEditSheet` → `PATCH notes`; menu Edit Notes | present | Save on sheet dismiss rather than autosave |

#### Transcript `_detail.html.erb:280-337`, `_transcript_body.html.erb`, `timeline_items/*`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `_detail.html.erb:280-291` `transcript-panel` | Transcript disclosure, collapsed by default, opens scrolled to bottom | SDV conversation inline, opens at newest (:388-408) | present |  |
| `_transcript_body.html.erb:32-44` | "Showing latest N items / N items" + "<Level> view" | SDV :1031-1047 "The last N of M" | present |  |
| `_transcript_body.html.erb:48-69` `infinite-scroll` (GET `timeline_items`, prefetch) | Load earlier messages (tail 10, pages of 100) | SDV :164-190 Show earlier (`before=`) | present |  |
| `_transcript_body.html.erb:86-104` | Empty state ("Agent is running…" / "No activity yet") | SDV :1049 "No transcript yet." | present |  |
| `_detail.html.erb:298-299` `timeline`, `auto-scroll` | New items appended live; stays pinned to bottom when at bottom | SDV :365-367 follows while end in view | present |  |
| `_detail.html.erb:37` `session-scroll` | Re-pin to bottom while content settles after render | SDV :388-408 | present |  |
| `timeline_items/_item.html.erb:32` `data-filter-category` | Items tagged message / regular-log / verbose-log for client filtering | `Transcript.swift:7-27` | partial | Only tool traffic is classified |
| `_item.html.erb:38-48, 69-102` + `sessions_helper.rb:209-239` | Row types: User, Assistant | SDV :1295-1357 You / Agent bubbles | present |  |
| same, `Tool: <name>` + `ot_tool_call_markdown` :382-394 (parameters list) | Tool call row with parameters | "Tool" bubble from `conversation` (`session.rb:1339-1350`: name, description, command only) | partial | Parameters other than description/command are not sent (needs API) |
| same, `Tool Result (Error)` | Tool result row, error-flagged | "Tool" bubble (`session.rb:1351-1357`) | partial | `is_error` not carried |
| same, Thinking | Thinking row | — | missing | needs API: `conversation` emits user/assistant only |
| same, Subagent (`SUBAGENT_SPAWN`) `ot_subagent_spawn_markdown` | Subagent spawn row (type, description, prompt) | — inline; SLV subagent list separate | partial | needs API for inline placement |
| same, Compaction `ot_compaction_markdown` | Context compaction row with token before/after | — | missing | needs API |
| same, Error | Error row | — | missing | needs API |
| `_item.html.erb:171-186` Runtime Notice digest (`ot_runtime_notice_digest`, skill name, approx tokens, Show/Hide) | Collapsed injected-context notices | — | missing | needs API |
| same, Queue Event / system events `ot_system_event_markdown` | Queue operation rows | — | missing | needs API |
| `timeline_items/_log.html.erb` (Show Logs / Verbose levels) | Session log rows interleaved, level icon, timestamp | SLV :6-102 separate modal, `exclude_level=verbose`, no level picker | partial | Verbose logs unreachable; API `logs?level=` exists |
| `timeline_items/_mcp_log.html.erb` | MCP server log rows (server name) | — | missing | needs API: `conversation` has none; logs API does not expose the `mcp_log` type |
| `_item.html.erb:103-110` `ot_image_count` | "N images attached" badge on a message | — | missing | needs API: `conversation` strips image blocks (web itself renders only "[Image attached: PNG]" text, `sessions_helper.rb:373-375`) |
| `_item.html.erb:113-134` `fork-session` (POST `fork` with `message_index`) | Fork conversation from this message / runtime notice | `MessageBubble` context menu "Fork from Here" | present | in #1282; runtime notices are not forkable there (they are not sent) |
| `_item.html.erb:135-150` `message-copy` | Copy a single message's markdown | context menu "Copy" | present | in #1282; `main` has only text selection |
| `_item.html.erb:151-153` `timestamp-updater` | "N ago" per row, live-updated | SDV bubble age | present |  |
| `_item.html.erb:57` `id="message-N"` anchors | Deep-linkable rows (`#message-N`) | — | missing | See status-panel row |
| `shared/_enhanced_markdown.html.erb` + `application_helper.rb:134-260` (Redcarpet: fenced code, tables, strikethrough, superscript, autolink, Rouge highlighting) | Markdown rendering | MT / `Markdown.swift:9-15` heading, paragraph, code, list, quote, table, rule, inline code, autolink | partial | No syntax highlighting, no strikethrough/superscript; link long-press menu is an iOS extra |
| `shared/_enhanced_markdown.html.erb:19` `code-block` | Copy button on every code block | MT :297-338 Copy | present |  |
| `_item.html.erb:202-208` + `mcp_apps/show.html.erb:8-66` `mcp-app-host` (GET `mcp_apps#show`, `fragment`, POST `rpc`, `message`) | MCP App view hosted in a sandboxed iframe under its tool call, fullscreen toggle | — | missing | needs API: mcp_apps routes are web-session only; the app would host it in a WKWebView |
| `_item.html.erb:211-218` + `subagent_transcripts/_accordion.html.erb:10-116` `subagent-accordion` (live-streamed messages) | Subagent accordion inline under the spawn row: status, type, counts, tokens, duration, nested transcript | SLV :106-196 Subagents modal list + transcript (`SessionExtras.swift:108-152`) | partial | Not inline; stats present; unknown block types skipped |

#### Composer `_follow_up_form.html.erb` (hidden when archived :1; live-replaced :36)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `:71-90` running indicator + `time-since` | "Agent is running (messages will be queued)" with elapsed | SDV placeholder "Queue message · hold send for now" | partial | Elapsed badge needs `last_timeline_entry_at` |
| `:94-121` `bottom-drawer` trigger with `draftIndicator` | Collapsed bar showing "Draft: …" | SDV composer always visible; `DraftStore` | present |  |
| `:152` form switches to `enqueued_messages#create` when a turn is underway, else `follow_up` | Send vs queue, decided server-side (`Sessions::LiveTurn`) | SDV `POST follow_up` always; server queues while running | present | Toast says Queued / Sent |
| `follow_up_prompt_controller.js:48-52` `pendingSentMessage` | A refused/undelivered prompt is put back in the composer (`metadata.sent_message`) | — | missing | needs API: `sent_message` is inside `metadata` (serialized) but the app does not restore it (#1307) |
| `follow_up_prompt_controller.js:2, 134-207` drafts (localStorage, 7-day prune) | Draft kept per session across reloads | `DraftStore.swift` | present |  |
| `:166-171, 242-250` `image-attachment` (POST `upload_images`; accept `media_picker_accept` images+video; max 20, 10 MB) | Attach photos/videos from picker | AV :11-173 PhotosPicker (JPEG, downscaled), 20 files / 10 MB / 75 MB total, base64 in `follow_up` | partial | Video not attachable; web uploads via `upload_images`, the app inlines base64 in `follow_up` (accepted API path) |
| `:174-179, 252-261` camera input (`capture="environment"`) | Take a photo with the phone camera | — | missing | G17 in PARITY_AUDIT; no API needed |
| `:180-184, 263-271` `file-attachment` (POST `upload_files`; max 200) | Attach arbitrary files | AV fileImporter, 20 max | present | Lower cap |
| `:187-192, 273-281` folder input (`webkitdirectory`, recursive) | Attach a folder recursively | — | missing | `fileImporter(allowsDirectories)` could do it |
| `image_attachment_controller.js` paste; `:200` "Ctrl+V to paste images" | Paste an image from the clipboard | AV "Paste Image" button | present |  |
| `shared/_composer_drop_overlay.html.erb` + `composer-drop` | Drag-and-drop files onto the composer | — | web-only | A pointer drag from another window is a desktop gesture; the picker/share sheet is the phone's path |
| `:198-204` label "Cmd+Enter to submit" + `handleKeydown` | Keyboard chord submits | — | web-only | Hardware-keyboard chord; the send button is the touch path |
| `:205, 295` `character-counter` (`PROMPT_MAX_LENGTH`) | Remaining-characters counter | — | missing |  |
| `:217-231, 297-310` `slash-command` (skills from `ClaudeSkillsCacheService`, `catalog-multiselect:selectionChanged`) | "/" typeahead of user-invocable skills, Tab/Enter select | `SlashCommandList.swift:7-74`; SDV :1135-1139 | present |  |
| `:234-238, 322-324` previews + progress | Attachment chips with remove; upload progress | AV :176-209 chips with sizes | present |  |
| `:282-287, 356-365` submit ("Send Message" / "Queue Message") | Submit | SDV send; long-press "Send Now — ends the current turn" (`force_immediate`) | present | The web has no force-immediate on the composer |
| `enqueued_messages/_enqueued_messages_list.html.erb:4-47` `enqueued-messages-panel` (+ `turbo_stream_from` enqueued) | Queued Messages panel, count, collapse, live | SQV :7-78 QueueCard, polled | present |  |
| `enqueued_messages/_enqueued_message.html.erb:2-163` `enqueued-message-accordion`, `enqueued-message-edit`, `enqueued-messages-list` drag (PATCH `reorder`) | Position, expand, copy, edit content + goal (PATCH), Send Now (POST `interrupt`), Delete (DELETE, confirm), drag to reorder | SQV Send Now / Edit sheet :126-168 / Delete / Manage with drag-reorder :82-122 | present | Copy of a queued message not found — minor |
| `enqueued_messages/_form_errors.html.erb` | Validation errors on enqueue | SDV error banner :482 | present |  |
| `_running_loader.html.erb:3` (live target) | Empty broadcast target for the running loader | n/a | present | Nothing visible to port |

#### Mobile joystick `_mobile_joystick.html.erb` + sheets

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `:73-191` `joystick-menu` radial petals (hold-drag) + `:194-313` bottom sheet | Single FAB: press-and-hold radial menu, tap for the sheet | SDV "…" actions menu :798-957 | present | Menu, not a gesture; same actions |
| `:209-212` Quick Router petal → `shared/_chat_bubble.html.erb` (`chat-bubble`, POST `chat_bubble_sessions_path`) | Opens the Quick Router threaded under this session | SDV Quick Router item; `QuickRouterView.swift:351` FAB → `POST /quick_router` | present | Quick Router internals are another area |
| `:213-216` Edit Notes petal | Opens the notes drawer | SDV Edit Notes | present |  |
| `:218-224, 328-497` Artifacts modal | MCP / Skills / Hooks / Plugins / Goal read-only with Modify buttons | SP rows with Edit | present |  |
| `:226-253` View PR / PR list with status + CI dot (`session-activity` touch) | Open PR(s) | SDV View PR / submenu | partial | No `touch_activity` (see header row) |
| `:259` `_visibility_menu` sheet variant | Snooze until… / Hide / Put back | SDV menu | present |  |
| `:261-271` Trash / Restore |  | SDV | present |  |
| `:273-276` Refresh Transcript |  | SDV | present |  |
| `:278-283` Pause (running) |  | SDV | present |  |
| `:286-291` Restart (`restartable_by_hand?`, `window.confirm`) |  | SDV | present |  |
| `:293-296` Add/Remove Favorites |  | SDV toolbar star | present |  |
| `:299-312` Log Level select |  | SDV picker | partial | See filter row |
| `_mobile_mcp_servers.html.erb:7-124` (stacked editor; OAuth-required banner inside; live target `session_X_mobile_mcp_servers`) | Modify MCP Servers sheet | `CatalogEditorSheet` | present |  |
| `_mobile_catalog_skills/_hooks/_plugins.html.erb` | Modify sheets | `CatalogEditorSheet` | present |  |
| `_mobile_goal.html.erb:5-83` | Modify Goal sheet | `GoalPickerSheet` | present |  |

#### Live updates (Turbo Streams the page receives)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `session_X_timeline` append `timeline_items/item` | New transcript rows | poll tail of 20 merged by position (`ConversationPages.swift:94-100`) | present |  |
| `session_X_status_badge`, `_header_actions`, `_metadata`, `_follow_up_form`, `_running_loader`, `_status_panel`, `_goal_check` replace | Status, actions, metadata, composer mode, summary, goal check | poll `GET /sessions/:id` | present |  |
| `session_X_provenance` replace (`disclosure-memory`) | Hierarchy / human messages re-render on family change | poll | present |  |
| `session_X_elicitations` append/remove, `session_X_lost_elicitation` replace | Elicitation banners come and go | poll `GET …/elicitations` | present | in #1282 |
| `session_X_enqueued_messages` replace + per-message frames | Queue panel | poll (paused while editing) | present |  |
| `subagent_<id>_messages` replace | Subagent transcript streams while running | SLV re-read on open only | partial |  |
| `session_X_mobile_mcp_servers` replace | MCP chips after an MCP save | poll | present |  |

### C Board & starting sessions

115 rows: 79 present, 22 partial, 13 missing, 1 web-only.

#### Board chrome and navigation (`app/views/sessions/index.html.erb`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| index.html.erb:40–41 | Title "Agent Sessions" + subtitle | SessionListView.swift:154 `.navigationTitle("Sessions")` | present |  |
| index.html.erb:46, 174 | **New Session** button (mobile icon + desktop) → `sessions#new` | SessionListView.swift:305 pencil → `NewSessionView` | present |  |
| index.html.erb:152 / 275 | **Refresh All** (`POST sessions#refresh_all`; refreshes transcripts, restarts failed, continues stalled waiting, max 50) | SessionListView.swift:51–55, 291 view menu → confirm → `refreshAll()` (`POST /api/v1/sessions/refresh_all`) | present |  |
| index.html.erb:30 `turbo_stream_from "sessions_index_individual"` | Live: card replaced on status/title/slug/prompt/catalog/metadata/custom_metadata/favorite/notes-blankness change (`Session#should_broadcast_to_index?`, session.rb:2984), throttled 30 s for `last_timeline_entry_at`; new session prepended to `#sessions_grid`; archived card removed | RootView.swift:92–116 `BoardPoller` (30 s poll while the board is in front, and on foreground) | partial | Polling, not streaming: up to 30 s stale, and only while the board tab is in front with nothing selected. Neither side re-renders a row when a summary lands |
| index.html.erb:31 `turbo_stream_from "notification_badge"` | Live unread count | `refreshUnreadCount()` after each board read | partial | Polled |
| _ranked_sessions.html.erb:59 `turbo_stream_from Session::RANKED_STREAM` | Ranked view live: status pill replace (`broadcast_ranked_row`) and membership envelopes (`broadcast_ranked_membership` → `_ranked_delivery`) judged client-side against filters; deliveries held mid-drag | same `BoardPoller` | partial | Polled; the poll is suppressed while reordering (`isEditingBoard`), so a status change during a long drag is not seen |
| index.html.erb:29 `stream-visibility-recovery` | After a backgrounded PWA's socket dies, re-sync the board on visibility/pageshow | RootView.swift:105 refresh on `scenePhase == .active` | present |  |
| index.html.erb:29 `pull-to-refresh` | Pull down to reload the board | SessionListView.swift:230 `.refreshable` | present |  |

#### Filters (`index.html.erb:290–465`, `sessions#index`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| index.html.erb:296 `hidden_field FILTERS_SUBMITTED_PARAM` + `persisted_filters` (cookie `sessions_filters`) | Filter choice persists across visits | AppModel.swift:16 `stored("boardFilters")` UserDefaults | present |  |
| index.html.erb:307 **Reset filters** (`root_path(reset_filters: 1)`) | Drop persisted filters, back to default (needs_input) | SessionListView.swift:561 "Reset" in the summary line; BoardFiltersSheet.swift:90 Reset | present |  |
| index.html.erb:321 Quick: **All** | Every status | BoardFiltersSheet.swift:21 "All" | present | Web puts the three quick links on the board; iOS puts them inside the Filters sheet. The chip row (SessionListView.swift:493) has Needs input / Active / Waiting / Running / Failed / Archived instead, which the web does not have |
| index.html.erb:322 Quick: **All Unarchived** | All but archived | BoardFiltersSheet.swift:22 | present |  |
| index.html.erb:323 Quick: **All Priority Unarchived** | priority class, not archived | BoardFiltersSheet.swift:23 | present |  |
| index.html.erb:336 search box `q` ("Search sessions...") | Title/prompt/slug search within the current filters and view | SessionListView.swift:231 `.searchable`, debounced 350 ms | present | iOS search comes from `/api/v1/sessions/search` (created-desc), re-sorted client-side by urgency (`SessionOrdering.sorted`) and re-sectioned by the view; the web keeps the view's order |
| index.html.erb:343–353 **Status** checkboxes (waiting, running, needs_input, failed, archived) any number | Status filter; none = every status; "Archived" is the trash | BoardFiltersSheet.swift:28–40 toggles | present | iOS "none ticked" = every status except Archived (web says every status). Documented difference, deliberate on iOS |
| index.html.erb:330 "showing needs input and failed" summary | Says what the status filter shows | SessionListView.swift:548 `FilterSummary` + footer | present |  |
| index.html.erb:361–372 **Scheduling class** segmented (All / Priority / Spot) | `priority_class` filter | BoardFiltersSheet.swift:43–49 | present |  |
| index.html.erb:385–409 **Board visibility** (On board / Snoozed & hidden / Both) with "N tucked away" count | `visibility` filter; the count nudges reveal | SessionListView.swift:277 view menu "Board visibility" picker; BoardFiltersSheet.swift:78 | partial | The "N sessions tucked away" count is missing: `GET /api/v1/sessions` returns no off-board count. Needs API: `off_board_count` on the index |
| index.html.erb:412–425 Advanced: **Agent root** text + datalist of every root | `agent_root` filter | BoardFiltersSheet.swift:55–65 picker from `configs.agent_roots` | present | iOS picker uses invocable + any root in configs; web datalist is `AgentRootsConfig.all` — same source |
| index.html.erb:426–439 Advanced: **Genesis** select | `genesis` filter | BoardFiltersSheet.swift:66–72 | present |  |
| index.html.erb:440–443 Advanced: **Search transcript contents** checkbox | `search_contents` (bounded scan, `SessionContentSearch`) | SessionListView.swift:232 search scopes "Titles" / "Transcripts" | present |  |
| _content_scan_notice.html.erb | "Transcript scan stopped early: newest N of M searched…" banner | SessionListView.swift:178 `incompleteNotice` ("stopped before reading every session") | partial | iOS says it stopped, not how far it got (`scanned` / `candidate_count` are in the API's `content_scan`; not shown) and has no cursor to continue |
| index.html.erb:448 **Apply filters** | Submit the form | BoardFiltersSheet.swift:97 Apply | present |  |

#### View switcher and views (`index.html.erb:632–744`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| index.html.erb:641–646 view mode links: **Your board / Last Touched / Created / Ranked** (persisted in cookie `sessions_view`, `?view=`) | Switch view, keep filters | SessionListView.swift:274 Picker "View" in the view menu; `boardView` UserDefaults | present |  |
| sessions#index:76 Ranked default status filter = waiting+running+needs_input+failed | Ranked opens on live work | BoardFilters.ranked (SessionFilter.swift:81) | present |  |
| _flat_sessions.html.erb:12–15 heading "Sorted by last touched" + total count badge | Title and count | — | partial | iOS shows no total count for flat views (API pagination `total_count` is available; not rendered). Your board has a count on web (`_user_view_sessions:43`) — iOS has none |
| _flat_sessions.html.erb:31 Kaminari `paginate` (50/page, `?page=`) | Page through flat views | SessionActionsAPI.swift:174 reads up to 5×100 then says "Showing the first 500" | present | Different mechanism, same reach |
| _user_view_sessions.html.erb:24–67 **Your board**: one list, priority above spot, precedence within, capped 500 with truncation notice | The decision board | BoardView.swift:204; SessionListView.swift:172 `listIncomplete` | present |  |
| _user_view_sessions.html.erb:26 `user-view` drag reorder (writes precedence via `reorder_precedence`) | Drag a row to reorder | SessionListView.swift:283 "Reorder Board" edit mode, `.onMove` → `reorder(above:below:)` | partial | iOS needs an explicit "Reorder Board" mode, then Done; the web drags directly. Priority rows are `moveDisabled` on iOS. Acceptable, but two extra taps per reorder |
| _user_view_sessions.html.erb:38 **Reprioritize** button + "Working in session #N" | Hand the board to the reprioritizer session | `SessionListView.swift` (#1284) | partial | **in #1284**: view menu → confirm → `reprioritize()`, toast with the message. The "Working in session #N" link is not shown (the response carries `session`; the PR shows only `message`) → partial once #1284 lands |
| _user_view_sessions.html.erb:64 error live region for failed reorder | Error without reload | AppModel.swift:465 `handle(error)` + refresh | present |  |
| _ranked_sessions.html.erb:77–102 **Priority** section + count | Priority sessions above the queue | SessionListView.swift:123 sections "Priority" / "Spot queue"; BoardView.swift:207 | present | Section counts not shown on iOS (web shows `priorityCount` / `spotCount`) — minor |
| _ranked_sessions.html.erb:104–124 **Spot queue** section + count, capped 200 | The queue in work order | same | present |  |
| _ranked_row.html.erb:163 inline **precedence number field** (Enter commits, `update_precedence`) | Type an exact rank | SessionDetailView.swift (`setPrecedence`) only | partial | Rank is editable on the session page, not on the row; iOS Ranked rows do not show the precedence number at all (`SessionRow`), the web row does |
| _ranked_row.html.erb:36 drag handle on spot rows (`ranked-queue#persistDrop`) | Drag to reorder the spot queue | SessionListView.swift:295 "Reorder Spot Queue" | present | Same explicit mode caveat as Your board |
| _ranked_row.html.erb:100–111 ⋮ **Promote to priority** / **Demote to spot** (`update_scheduling_class`, demote → `place: top_of_spot`) | Move a row between sections | SessionDetailView.swift `setSchedulingClass` | partial | Only on the session page; not on the row's context menu. API supports it (`PATCH /sessions/:id` `scheduling_class` / `place`) |
| _ranked_row.html.erb:127 ⋮ **Start now** (`start_now`) | Take the waiting session's turn now | SessionListView.swift:461 context menu "Start Now" (status == waiting) | present | Web offers it on every row and lets the server refuse; iOS only on waiting rows — fine |
| _ranked_row.html.erb:135 ⋮ **Open session** (full page) | Navigate to `/sessions/:id` | row tap → `SessionDetailView`; "Open in browser" | present |  |
| _ranked_row.html.erb:144 ⋮ **Trash** | Archive via the ranked stream | swipe / context menu Trash | present |  |
| _ranked_row.html.erb:118 ⋮ Snooze until… / Hide | Visibility from the row | SessionListView.swift:453 context menu / swipe | present |  |
| _ranked_row.html.erb:178 agent root (else genesis) on the row | What the work is | SessionRow shows root only on Your board (`RowSummary`) | partial | Ranked/flat rows on iOS have no root. `board_rows` comes with `include=board_row`, which iOS requests for user/ranked views, but `SessionRow` renders it only when `showsSummary` (Your board). Ranked could show it today without an API change |
| _ranked_row_status.html.erb | Status pill with spinner | SessionBadges.swift `StatusBadge` (halo dot) | present |  |
| index.html.erb:749–787 **Empty state** ("No sessions" / "No sessions found" + Clear Search / New Session) | Empty state | SessionListView.swift:613 `EmptyListRow` | present |  |
| index.html.erb:775 **Clear Search** (drops q/agent_root/genesis/search_contents, keeps filters) | Abandon a query only | system search cancel clears `searchText` | present |  |

#### Session card (`_session_card.html.erb`, flat views) and row (`_user_view_row.html.erb`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| _session_card.html.erb:8 **Favorite star** (`toggle_favorite`) | Star/unstar | SessionListView.swift:369 leading swipe; context menu; star glyph in `SessionRow` | present | Note: `GET /sessions` docs claim favorites sort to the top; neither web view does (`LAST_TOUCHED_ORDER` session.rb:711 ignores it) — parity holds |
| _session_heartbeat.html.erb (card top-right) **Heartbeat** heart + popover (on/off, interval) | Per-session heartbeat from the card | SessionDetailView.swift (`setHeartbeat`, `setHeartbeatInterval`) | partial | Session page only; not on the row. API exists (`PATCH /sessions/:id/heartbeat`). The web card shows the heart state at a glance; iOS rows show nothing |
| _session_card.html.erb:19–37 status badge with **running elapsed** (`time-since`, colour by age) | How long since the last timeline entry | `StatusBadge` | partial | No elapsed/age colour. `last_timeline_entry_at` is not in `session_json`. Needs API: `last_timeline_entry_at` |
| _session_card.html.erb:51–62 per-card **Refresh** (`sessions#refresh`: re-sync transcript, restart failed, nudge stalled waiting; hidden while running) | Refresh one session | SessionListView.swift:439 context menu "Refresh Transcript" (`POST /api/v1/sessions/:id/refresh`) | partial | API `refresh` only re-reads the transcript; the web action also restarts a failed session and sends the continue nudge. Needs API: the web `refresh` semantics |
| _session_card.html.erb:65 `#id` | Session id | SessionRow `#id` mono | present |  |
| _session_card.html.erb:69 `session_cost_badge` (estimated spend) | Cost on the card | — | missing | `session_json` carries no cost (`session_costs_helper.rb:38` is web-only). Needs API: `estimated_cost` per session, or `include=cost` on the index (P11/G13 in PARITY_AUDIT, "not yet") |
| _session_card.html.erb:70 created "N ago" (`timestamp-updater`) | Age | SessionRow `Format.age` (updatedAt ?? createdAt) | present | iOS uses updatedAt first; web card shows created. Minor |
| _session_card.html.erb:78–89 **editable title** (pencil, `update_title`) | Rename inline | SessionListView.swift:437 context menu "Rename" alert | present |  |
| _session_card.html.erb:90–94 prompt excerpt when untitled (`truncate(80)`, full prompt on hover) | Fallback title | SessionSummary.displayTitle | present |  |
| _session_card.html.erb:95–99 agent root key | Which root | Your board rows only (see above) | partial | Flat views on iOS have no root |
| _session_card.html.erb:104–108 **genesis · class** pill (`web_ui · priority`) | Origin and the class it resolved to | SessionRow "Priority" word only | partial | Genesis not on the row (field `genesis` is in `session_json`; just not rendered). No API change needed |
| _session_card.html.erb:112 / _visibility_badge | "Snoozed · date" / "Hidden" pill when revealing | SessionBadges.swift `VisibilityLabel` | present |  |
| _session_card.html.erb:123 / _github_pr_link | PR button: state glyph/colour, CI dot, multi-PR dropdown (all PRs, latest marked) | SessionRow shows newest PR glyph+label+CI dot; context menu "View PR" opens only the last | partial | Multiple PRs: only the newest is reachable from the row/menu; the web lists all. `custom_metadata.github_pull_request_urls` is already decoded (`pullRequests`) — app-only |
| _session_card.html.erb:138–145 **Restart** (failed → footer button; needs_input → ⋮ with confirm) | Restart a failed/paused session | SessionListView.swift:466 context menu "Restart Session" with the web's confirm copy | present |  |
| _session_card.html.erb:152–190 ⋮ overflow (`overflow_menu_controller.js`) | Houses restart + visibility | context menu (press and hold) | present |  |
| _visibility_menu.html.erb:95–104 **Snooze presets** (Later today / Tomorrow / In 3 days / This weekend / Next week) computed in the browser's zone | Snooze | SessionListView.swift:398 `SnoozeButtons` (same five, SessionActionsAPI.swift:37–41) | present |  |
| _visibility_menu.html.erb:106–119 **Custom** datetime-local + Snooze | Pick a time | CustomSnoozeSheet.swift | present |  |
| _visibility_menu.html.erb:125–131 / :138 **Hide** (no end time) | Hide | `SnoozeButtons` "Hide" | present |  |
| _visibility_menu.html.erb:86–92 / :148 **Put back on the board** + `visibility_summary` | Restore | swipe "Put back" / context "Put back on the board" | present | The summary sentence (why it is away, when it returns) is on the row as `VisibilityLabel` |
| _visibility_menu.html.erb:189 status line for a failed visibility write | Error without reload | `perform` → `handle(error)` | present |  |
| _session_card.html.erb:192–197 **Restore** (archived card, `unarchive`) | Out of the trash | swipe "Restore" / context "Restore from Trash" | present |  |
| _session_card.html.erb:199–204 **Trash** (`archive`; queued-messages speed bump "Archive anyway" via `_flash` `force_archive`; running session trashed outright) | Trash | AppModel.swift:377 `trash()` sends `end_turn: true`; `.queued` → `QueuedTrashQuestion` "Trash anyway" (`force: true`) | present |  |
| _session_card.html.erb:219 **View** → right-side drawer (`session_drawer_controller.js`, `sessions#drawer`, resizable, lazy frame, focus trap) | Peek at a session without losing your place | row tap pushes `SessionDetailView` on the NavigationStack; back returns to the same scroll | present | Below `sm` the web drawer declines and the full page opens (`_ranked_row:51`), so the phone behaviour is a push there too |
| _user_view_row.html.erb:40 drag handle | reorder | see Your board | partial | explicit mode |
| _user_view_row.html.erb:52 title link | open | row tap | present |  |
| _user_view_row.html.erb:60 **Priority / Spot** badge | which half | SessionRow "Priority" (spot shown by absence) | present |  |
| _user_view_row.html.erb:86–121 **status summary** as inline markdown + freshness chip (Up to date / Stale / Regenerating, "N messages since", "written N ago") | Decide on the row | SessionListView.swift:570 `RowSummary` (markdown attributed, freshness, since-count, written-ago) | present | Links render as text on iOS (row is one tap target) |
| _user_view_row.html.erb:128 agent root / genesis chip |  | `RowSummary` root ?? genesis | present |  |
| _user_view_row.html.erb:133 **precedence readout** `#N` |  | — | missing | `precedence` is in `session_json`; not rendered on any iOS row |
| _user_view_row.html.erb:139 PR button |  | SessionRow PR | present |  |
| _user_view_merge_button.html.erb **Merge** (offered when open+green; "Merge sent" when `AuthorizeMerge.authorized_at`; "Merged" when merged) | Authorize the merge | `SessionListView.swift` (#1284) | partial | **in #1284**: swipe/context "Merge" with confirm. The "Merge sent" state is not shown afterwards: `authorized_at` is not in `session_json`, so a second press is only refused server-side. Needs API: `merge_authorized_at` → partial once #1284 lands |
| _user_view_row.html.erb:147 Snooze popover on the row |  | swipe/context | present |  |
| _user_view_row.html.erb:156 Trash (turbo stream removes the row) |  | swipe/context | present |  |

#### Bulk select / bulk actions

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `sessions#bulk_archive` (routes.rb:706; no checkbox UI renders it on the board — no `session_ids[]` inputs in any index partial) | Bulk trash by ids | SessionListView.swift:276 "Select Sessions" → bottom bar Trash → confirm → `bulkArchive` | present | iOS has more than the web here; the web has no multi-select on the board today |

#### Dashboard notes sidebar (`index.html.erb:790–832`, `dashboard_notes_controller.js`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| index.html.erb:790–832 slide-in notes sidebar (`dashboard-notes#open`, `manualSave`, autosave) | Edit a session's notes from the board | SessionDetailView.swift `updateNotes`; `SessionRow` shows a notes glyph | web-only | Unreachable on the web: nothing in `app/views` dispatches `dashboard-notes#open`, so the sidebar is dead markup. Notes are at parity on the session page |

#### New session form (`app/views/sessions/new.html.erb`, `sessions#new` / `#create`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| new.html.erb:5 Back to Sessions / :427 Cancel | leave | NewSessionView.swift:52 Cancel | present |  |
| new.html.erb:14–26 catalog "Updated N ago" + **Refresh catalogs** (`POST /catalogs/refresh`) | Re-resolve the AIR catalog | — | missing | No API (`catalogs#refresh` is web-only in routes.rb:617). Needs API: `POST /api/v1/catalogs/refresh` + `last_refreshed_at`. A stale catalog is why a root or skill is missing from the pickers |
| new.html.erb:33 `shared/catalog_failure_banner` | Says the catalog failed to resolve | — | missing | `GET /api/v1/configs` has no failure flag; the app shows a generic error only when the request fails. Needs API: catalog health on `/configs` |
| new.html.erb:42–51 validation errors list |  | NewSessionView.swift:36 `ErrorBanner` | present |  |
| new.html.erb:59–73 **Agent Runtime** select (`runtime_select_controller.js` → `ao:runtime-changed`) | Harness | NewSessionView.swift:78 Picker "Runtime" (only when >1 runtime) | present |  |
| new.html.erb:89–125 **Agent Root** autocomplete (`agent_root_select_controller.js`: search, keyboard, selected display with change) | Root | NewSessionView.swift:74 Picker over `invocableRoots` | present | Web lists `@agent_roots` (user-invocable); iOS the same. No search inside the picker, but a native wheel/menu is fine |
| new.html.erb:131–148 **Model** select scoped to runtime, following the root's `default_model` (`model_select_controller.js`) | Model | NewSessionView.swift:83 + `apply(root:)` :211–230 | present | Same inheritance rule (root's model only if the runtime lists it) |
| new.html.erb:158–181 **Reasoning effort** (levels per model; hidden when the model takes none; `effort_select_controller.js`) | Effort | NewSessionView.swift:88–94 | present | Sent as `config.effort` (NewSessionRequest body) |
| new.html.erb:196–210 **Auto-compact window** (Claude Code only; `auto_compact_window_controller.js`) | Per-session compaction threshold | — | missing | `auto_compact_window` is permitted on `POST /api/v1/sessions` (api sessions_controller.rb:1765), so app-only. PARITY_AUDIT G21 covers the session-page editor, not the create form |
| new.html.erb:216–232 **Scheduling class** (Default for web_ui / Priority / Spot) | Class | NewSessionView.swift:139 ("From its origin" / Priority / Spot) | present | An iOS create is recorded as `genesis: api` (unless `parent_session_id`), which classifies as **spot** (rest-api.md:402), while the web's default is priority. So "From its origin" on a phone means waiting for quota — a difference a person hits. Needs API: a `genesis` for native-app creates, or the app sends `scheduling_class: priority` by default |
| new.html.erb:237–246 **Precedence** number (+ link to Ranked) | Where it lands in the spot queue | — | missing | Permitted on `POST /api/v1/sessions`; app-only |
| new.html.erb:249–263 **Initial Prompt** textarea (6 rows, `character-counter` with `PROMPT_MAX_LENGTH`, Cmd/Ctrl+Enter submit) | Prompt | NewSessionView.swift:114 TextField 4…12 lines | partial | No character counter / max-length guard on iOS (`Session::PROMPT_MAX_LENGTH`); the server returns 422 past it |
| new.html.erb:256, 261 **/ slash commands** typeahead from catalog skills (`slash_command_controller.js`) | Insert a skill invocation | SlashCommandList.swift exists but is wired to the session composer; not in `NewSessionView` (grep: no `SlashCommandList` in NewSessionView.swift) | missing | App-only (the catalog skills list is already fetched for the Skills picker) |
| new.html.erb:273–346 **Attach images / camera / files / folder** (staged to `upload_images_new_session` / `upload_files_new_session`, `files_payload`), paste and drag-drop | Attachments on the first prompt | — | missing | `POST /api/v1/sessions` permits no attachments; the Quick Router route does (`InlineAttachments`). Needs API: `attachments[]` on create, the shape `follow_up` and `quick_router` take. Camera capture is absent from `AttachmentViews.swift` everywhere (G17) |
| new.html.erb:350–384 **Goal** typeahead (predefined goals, root default, custom text, clear; `goal_controller.js`) | Goal | NewSessionView.swift:121–135 Picker None / goals / Custom… + text field; root default applied in `apply(root:)` | present | Predefined goal stored as its words, as the web does |
| new.html.erb:388–395 **MCP Servers** multiselect (root defaults, `emit_empty_input`) |  | NewSessionView.swift:149 Artifacts → `CatalogPicker(.mcpServers)` | present | Unavailable servers listed last with reason, as the web dropdown does |
| new.html.erb:397–404 **Skills** (grouped by category) |  | `CatalogPicker(.skills)` | partial | No category grouping on iOS (`CatalogItem` has no category; `GET /api/v1/skills` — check field). Minor |
| new.html.erb:406–413 **Hooks** (with description) |  | `CatalogPicker(.hooks)` | present |  |
| new.html.erb:415–422 **Plugins** (with description) |  | `CatalogPicker(.plugins)` | present |  |
| new.html.erb / `_catalog_multiselect_field` `ao:agent-root-changed` → re-default all four lists to the new root | Root change resets artifacts | NewSessionView.swift:229 `selections[kind] = kind.defaults(of: option)` | present |  |
| new.html.erb:117 (f.form) hidden `title`? — no; title is auto-generated on web (`SessionTitleJob`) |  | NewSessionView.swift:117 "Title (optional)" | present | iOS adds an optional title; harmless |
| new.html.erb:430–435 **Clone Only** (blank prompt → clone set up, no job) | Prepare a clone without a first turn | — | missing | `POST /api/v1/sessions` already enqueues nothing when `prompt` is blank (api sessions_controller.rb:232 "if @session.prompt.present?"); iOS disables Create on an empty prompt (NewSessionView.swift:55). App-only |
| new.html.erb:436 **Create Session** (Cmd/Ctrl+Enter) | Create | NewSessionView.swift:54 Create, idempotency key | present | iOS adds retry safety the web lacks |

#### Quick Router (`index.html.erb:468–629`, `_quick_router_advanced.html.erb`, `shared/_chat_bubble.html.erb` in `layouts/application.html.erb:44`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| index.html.erb:475–482 phone pill "What do you want to do?" → full-screen overlay (`quick_prompt_controller.js#openMobile`) | The board's prompt box | QuickRouterView.swift:229 `QuickRouterBar` pinned to the foot; sparkles open the sheet | present |  |
| index.html.erb:565–629 desktop inline textarea, Cmd/Ctrl+Enter |  | `QuickRouterBar` send button | present |  |
| index.html.erb:496, 570 `POST sessions#quick_prompt` (router root, `genesis: web_ui`, `metadata.source = quick_prompt`) | Create a router session | `POST /api/v1/quick_router` (`startQuickRouter`) | present | Recorded as `ios_app` |
| index.html.erb:505–515 / 577–587 **images / camera / files** inputs | Attachments | QuickRouterView.swift:55 `AttachMenu` (photos, files) | partial | No camera capture anywhere in `AttachmentViews.swift` (grep "camera" → none); G17 |
| index.html.erb:538 / 623 `_quick_router_advanced` **Harness** select (blank names the default) |  | QuickRouterView.swift:121 | present |  |
| _quick_router_advanced.html.erb:83 **Model** select scoped to harness (`quick_router_advanced_controller.js`) |  | QuickRouterView.swift:131, `onChange(runtime)` drops a stale model | present | iOS blank reads "Default" without naming the model (web: "Default (opus)") — the app cannot know the router root's model from `/configs`; cosmetic |
| _quick_router_advanced.html.erb:99 **Run as spot** |  | QuickRouterView.swift:150 Toggle | present |  |
| quick_prompt notice "Router session created…", "harness not available, default applied" | Outcome messages | AppModel.swift:244 opens the session; server message not surfaced | partial | `quick_router#create` answers with the rejected-pick notes (`runtime_rejected?` / `model_rejected?` lines 84–91); the app navigates and drops the message |
| _chat_bubble.html.erb:8 bubble on every page, `data-turbo-permanent`, ⌘/Ctrl+K | Start work from anywhere | RootView.swift:50–62 `.quickRouterCorner()` on Inbox / Triggers / More; session page has `parent` | present |  |
| _chat_bubble.html.erb:127 "Page context is automatically included" (`capturePageContext` → `page_context`, `page_url`, `page_title`) | The router sees what you were looking at | — | missing | `POST /api/v1/quick_router` takes `page_url` / `page_title` / `page_context` but `QuickRouterRequest.json` sends none. App-only: send the screen's title/URL (trigger name, cost window) |
| _chat_bubble.html.erb:160–166 **Submit** (background) vs **Submit & Open** | Stay or navigate | QuickRouterView `Start` always opens the session | partial | No "start in background and stay here" on iOS — from Inbox or a session page the person is taken to the new session every time |
| chat_bubble `parent_session_id` from a session page | Thread under the session | QuickRouterView.swift:61 "Thread under #N" toggle | present |  |
| chat_bubble `handlePaste` images | Paste an image | — | missing | iOS has no paste-image on the Quick Router sheet (G17 covers the composer only; same gap here). App-only |

#### Counts

#### Routes covered

### D Operations

150 rows: 34 present, 29 partial, 83 missing, 4 web-only.

#### Triggers

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| triggers/index.html.erb:16,34 (`triggers#new`) | "New Trigger" button → form | — | missing | needs API: open `triggers#create` (+ `#channels`, `#whatsapp_chats`) to the native token; `POST /api/v1/triggers` already permits every form field. PARITY_AUDIT G22 calls this "browser by choice" — that is not a reason. |
| triggers/_trigger.html.erb:98 | Trigger name, links to show | OperationsViews.swift:267-275 TriggerRow | present |  |
| _trigger:100-112 | Enabled / Failed / Disabled badge | TriggerRow (dims when off; `lastError` line in warning ink), TriggerDetailView:53 TriggerStatusBadge | partial | List row never prints the word "Failed"; the detail page does. |
| _trigger:117-122 | "Agent root not in catalog" badge | TriggerDetailView:154-160 | partial | Detail only; the list row shows the root name in normal ink. Field `agent_root_missing_from_catalog` is decoded. |
| _trigger:123-142 | Re-uses session / Enqueues messages / Resuscitates archived / Skips while pending badges | Operations.swift:213-223 `badges`, rendered at TriggerDetailView:54 | partial | Detail only; not on the list row. |
| _trigger:147-151 | "N missed fires" badge | Operations.swift:220 | partial | Detail only. |
| _trigger:155-159 | Scheduling class badge (when set) | — | missing | API already returns `scheduling_class` / `effective_scheduling_class` (triggers_controller.rb:379-380); `TriggerSummary` does not decode them. |
| _trigger:160-165 | "P<n>" precedence badge | — | missing | API returns `precedence` (line 381); not decoded. |
| _trigger:172-187 | N conditions · N sessions · last triggered | TriggerRow:296-308 | present |  |
| _trigger:189-200 | Failed line: when, re-arm wording, last_error (200 chars) | TriggerRow:310, TriggerDetailView:75-95 | partial | Cannot say "its wake was already consumed, so re-arming will not re-fire it" — needs API: `spent_one_shot_wake` in trigger JSON (not in `trigger_json`, lines 338-400). |
| _trigger:207-220 (`triggers#toggle`) | Disable / Enable / Re-arm | TriggerRow:276 Toggle, TriggerDetailView:64,240 | present | Label "Re-arm" when failed (Operations.swift:207-210). |
| _trigger:221-225 (`triggers#edit`) | Edit link | — | missing | needs API: open `triggers#update` to the native token. |
| triggers/show.html.erb:15-58 | Title + status + badges (incl. "No coalescing") | TriggerDetailView:50-72 | present |  |
| show:60-63 | "N conditions: <summary>" | TriggerDetailView:124-148 | present |  |
| show:67-72,131-184 (`triggers#invoke`, Stimulus `trigger-invoke`) | Run Now panel: per-`{{variable}}` inputs (text/link/author…), then Run | TriggerDetailView:28-38,312-323; OperationsAPI.swift:70-86 | partial | The app always POSTs `{}` (OperationsAPI:73); the API accepts `variables`, so a template with `{{text}}` cannot be fed from the phone. 409/422/burst outcomes are handled. |
| show:73-81 | Disable / Re-arm / Enable | TriggerDetailView:64,240 | present |  |
| show:82-84 | Edit | — | missing | as above |
| show:85-87 (`triggers#destroy`) | Delete (with confirm) | — | missing | needs API: open `triggers#destroy` to the native token (`DELETE /api/v1/triggers/:id` exists). |
| show:93-128 | Failure panel: headline, spent-wake vs re-armable wording, session-scoped wake caveat, full last_error | TriggerDetailView:75-95 | partial | Shows headline + error; replaces the wording with "the trigger's page in the browser says whether re-arming fires it again". needs API: `spent_one_shot_wake`. |
| show:193-207 | Sessions created / Last triggered / Conditions tiles | TriggerDetailView:97-122 | present |  |
| show:214-235 | Each condition: type badge, detail, watched session, last fired | TriggerDetailView:124-148 | present |  |
| show:242-257 | Agent root + "not in catalog" explanation | TriggerDetailView:151-161 | present |  |
| show:260-262 | Session re-use on/off | TriggerDetailView:163 | present |  |
| show:264-274 (`triggers#toggle_enqueue_messages`) | Enqueue messages value + Enable/Disable switch (only with re-use) | TriggerDetailView:164 (value only) | partial | API half in #1318 (`toggle_enqueue_messages`, native-token opened); #1318 has no iOS change, so the switch is still missing in the app. |
| show:277-287 (`triggers#toggle_resuscitate_archived`) | Resuscitate archived value + switch | TriggerDetailView:166 (value only) | partial | Same: API in #1318, no app half. |
| show:290-315 | Skip while pending: value, "inert while re-using" note, "Skipping — session #N (status) is still pending" link | Operations.swift:219 badge only | partial | API returns `skip_if_pending_session_inert` (line 362); the pending session link needs API: pending session id in trigger JSON. |
| show:318-337 | Coalescing window: effective seconds / Off, "(default)", inert note | Operations.swift:221 ("No coalescing" badge when 0) | partial | API has `effective_coalesce_window_seconds`, `coalesce_window_inert` (lines 367-369); not decoded. |
| show:339-352 | Missed fires: count + "since <date>" + explanation | badge count only | partial | API has `first_missed_fire_at` (line 375); not decoded. |
| show:354-364 | Max sessions / minute + "Bursting — spawns suppressed" | TriggerDetailView:168, badge "Bursting" | present |  |
| show:367-376 | Scheduling class (effective) + "set on this trigger / default for its conditions" | — | missing | API has both fields. |
| show:379-389 | Precedence | — | missing | API has it. |
| show:391-457 | MCP servers / Skills / Hooks / Plugins chips, each flagged "(not in catalog)" | — | missing | API has `mcp_servers`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`, `unresolved_catalog_references` (lines 382-394). The session page already draws these chips (#1329), so the view code exists to reuse. |
| show:459-463 | Goal | TriggerDetailView:171-176 | present |  |
| show:470-477 | Prompt template + variable legend | TriggerDetailView:186-197 | present | Legend text not shown; the template is. |
| show:480-514 | Recent sessions (10): title, created, status, link | TriggerDetailView:199-233 | present |  |
| triggers/_form.html.erb:38 | Name | — | missing | All form rows: needs API: open `triggers#create`/`#update` to the native token (see first row). |
| _form:47-62, _condition_fields:22-37 (Stimulus `trigger-form`) | Add / remove conditions; type select: Slack, WhatsApp, Email, Schedule, Zimmer Event, System Event, GitHub Label, GitHub Issue | — | missing | `trigger_conditions_attributes` permitted on the API. |
| _condition_fields:39-108 (`triggers#channels`) | Slack: channel picker (fetched), channel id, event type (new_message / bot_mention / dm_message / passive thread / passive channel), thread_ts | — | missing | needs API: open `triggers#channels` to the native token. |
| _condition_fields:110-168 (`triggers#whatsapp_chats`) | WhatsApp: chat picker (fetched), mode listen/addressed, keywords, include_from_me | — | missing | needs API: open `triggers#whatsapp_chats`. |
| _condition_fields:171-197 | Email: Gmail search query, include_automated | — | missing |  |
| _condition_fields:199-305 | Schedule: recurring (interval+unit, day_of_week, time, timezone) or one-time (scheduled_at, timezone) | — | missing |  |
| _condition_fields:308-332 | Zimmer event: event_name (needs_input/failed/archived/account_needs_reauth), watched_session_id | — | missing |  |
| _condition_fields:335-347 | System event: quota_available / no_sessions_in_progress | — | missing |  |
| _condition_fields:350-395 | GitHub: repos (≤ MAX), target PR/issue, labels; GitHub issue: exclude_labels | — | missing |  |
| _form:75-105 | Agent root select (catalog, keeps a stored unknown root) | — | missing | `GET /api/v1/configs` is open to the token. |
| _form:116-157 (Stimulus `catalog-multiselect`) | MCP servers / Skills / Hooks / Plugins multi-selects | — | missing | `/api/v1/mcp_servers`, `skills`, `hooks`, `plugins` index are open to the token; the session page's picker (#1329) is reusable. |
| _form:167-193 (Stimulus `goal`) | Goal typeahead from `config/goals.json` | — | missing | The session page's goal picker (#1320) is reusable. |
| _form:204-238 | reuse_session, enqueue_messages, resuscitate_archived checkboxes | — | missing |  |
| _form:248-262 | Scheduling class select (default / priority / spot) | — | missing |  |
| _form:271-285 | Precedence | — | missing |  |
| _form:290-305 | Max sessions per minute | — | missing |  |
| _form:309-330 | Coalesce window seconds (+ "inert without Slack" warning) | — | missing |  |
| _form:336-348 | Skip while pending checkbox | — | missing |  |
| _form:357-385 | Prompt template textarea + variable and `untrusted`-fence help | — | missing |  |

#### Notifications (the inbox)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| notifications/index.html.erb:11 (`notifications#mark_all_read`) | Mark all read (shown only when something is unread) | OperationsViews.swift:63-66 menu | present |  |
| index:16 (`notifications#dismiss_all_read`) | Dismiss all read, with a confirm | OperationsViews.swift:68-71 | present | Destructive role but no confirmation step; the web asks "This cannot be undone." |
| index:30-47, controller:13-17 | List: active (non-stale), newest first, limit 100; no filters on the web | InboxView, `per_page=100` | present | API offers `status=read\|unread` (api notifications_controller.rb:29-30); neither surface uses it. |
| _notification_row.html.erb:2,25 | Unread tint + blue dot | InboxRow:119-125 dot, dimming | present |  |
| _notification_row:32 (`notifications#click`) | Tap → mark read → redirect to session | InboxView:94-99 | present |  |
| _notification_row:34 | Session title or "Session #N" | InboxRow:128 | present |  |
| _notification_row:37-46 | Needs your input / Session failed / Session completed / Status update | Operations.swift:36-43 `headline` | present |  |
| _notification_row:54-56 | "N ago" (hidden on narrow screens) | InboxRow:141-143 | present |  |
| _notification_row:60 (`notifications#dismiss`) | Dismiss (read rows only) | InboxView:29-34 swipe | present |  |
| _notification_row:68 (`notifications#mark_read`) | Mark read (unread rows only) | InboxView:36-41 swipe | present |  |
| _notification_badge.html.erb:7 (`notifications#badge`) | Pending count on the nav button | RootView.swift:52 tab badge, AppModel:288 | present |  |

#### Costs

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| costs/_window_picker.html.erb:23-33 | Presets 24h / 7d / 30d / 90d / 1y | CostsView:448-458, Operations.swift:331-334 | present |  |
| _window_picker:37-60 | Custom From/To calendar range, "Showing …" | CostsView:461-471 | present | Ends swapped / year-clamped as the web does. |
| costs/show.html.erb:28-60 | Scope banner: agent root or session (title, deleted), ad-hoc caveat, "All agent roots" | CostsView:506-548 | present | Deleted-session case: app shows id without title (API scope carries no title) — acceptable. |
| show:62-105 | Ledger coverage banner: backfilled / running % / queued / not yet, covers since, swept N ago, last error | — | missing | API returns `ledger_coverage` (costs_controller.rb:44,107-115); not decoded. |
| show:106-109 (`costs#backfill`) | "Sweep now" / "Re-scan history" button | — | missing | needs API: open `costs#backfill` to the native token (`POST /api/v1/costs/backfill` exists; token list is `index records`). |
| show:113-123 | Empty state explaining ingestion cadence | $0 total, empty sections | partial | No explanation text. |
| show:126-139 | Headline tiles: Total cost | CostsView:401-405 | present |  |
| show:126-139 | Tiles: Tokens, API calls, Ad hoc share | — | missing | In `totals` (`total_tokens`, `api_calls`, `adhoc_cost_usd`). |
| show:141-150 | Unpriced models warning | — | missing | `unpriced_models` in API. |
| show:152-176 | "Where the money goes" — cost by token kind with share bars | — | missing | `cost_breakdown` in API. |
| costs/_daily_chart.html.erb:7-25 | Daily spend bar chart | CostsView:406-414 Swift Charts | present |  |
| _daily_chart:16-60 (Stimulus `cost-chart`) | Tap/hover a bar → sessions $ / ad hoc $ / tokens / calls / top roots / top models for that day | — | missing | `by_day` rows carry `session_cost_usd, adhoc_cost_usd, tokens, api_calls, roots, models` (cost_analytics.rb:165-172); `CostSnapshot.Day` decodes only `day, cost_usd`. |
| costs/_bar_table.html.erb (By agent root) | Rows with share bar; narrow link | CostsView:556-588 | present |  |
| _bar_table:45-115 (Stimulus `hover-details`) | Expand a row: tokens, per call, share, and the context-feature split per root | — | missing | `by_agent_root[].features` etc. in API; not decoded. Same for the By model rows. |
| costs/_feature_table.html.erb | Context features (estimated) table | — | missing | `by_feature` in API. |
| costs/_experiment_table.html.erb (fleet only) | Experimental-setting cohorts: sample sizes, per-cohort cost, caveats | — | missing | `by_experiment` in API. |
| show:211-213 By model | Rows with share bar | CostsView:421 `rows("By model")` | present |  |
| show:215-217 | Main thread vs subagents | — | missing | `by_thread_kind` in API. |
| show:225-231 | By runtime (billing relationship) | — | missing | `by_runtime` in API. |
| show:236-239 | Ad hoc calls from Zimmer's own code, by source | — | missing | `by_adhoc_source` in API. |
| show:241-273 | Most expensive sessions: title, $, #id, calls, tokens, link, "Only this" | CostsView:590-632 | present |  |
| show:275-279 | "Most recent call recorded N ago" + list-price caveat | — | missing | needs API: `last_ingested_at` is not in the costs JSON (only `ledger_coverage.covers_until`). |
| costs/_burn_rates.html.erb (fleet only) | Burn rate by harness + model: $/min, $/hr, sessions, sample | — | missing | `burn_rates` is in the API since #1319 (costs_controller.rb:89-103); the app does not decode it and `docs/extend/ios-app.md:279` still says the API lacks it — stale doc. |

#### Health

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| health/dashboard.html.erb:1,17 (`health#refresh`, Stimulus `health-dashboard`) | Refresh button + 30 s auto-refresh | pull-to-refresh | partial | No auto-refresh. |
| dashboard:23 (`health#export_diagnostics`) | Export diagnostics JSON | — | missing | needs API: no API route for the diagnostics export. |
| dashboard:30-45 | Overall status banner + last updated | HealthView:691-699 | present |  |
| health/_queue_recovery_mode.html.erb (`health#enter/exit_queue_recovery_mode`) | Halted since / auto-resumes / entered by / reason; Resume; Enter (reason, TTL); unpause link to /jobs | — | missing | `queue_recovery_mode` is in `GET /api/v1/health`; enter/exit routes exist; needs API: open them to the native token. |
| health/_queued_job_maintenance.html.erb (`health#discard/reschedule_queued_jobs`) | Eligible backlog by class/queue; Discard; Reschedule with delay | — | missing | `GET /api/v1/health/queued_jobs` + both writes exist; needs API: open to native token. |
| _health_content.html.erb:9-69 | Process Health: recorded/active/tracked/orphaned counts, orphan list | status + message | partial | Numbers in `process_health` (health_monitor_service.rb:425-439). |
| _health_content:69 (`health#cleanup_processes`) | Clean Up Orphaned Processes | — | missing | needs API: open `health#cleanup_processes`. |
| _health_content:81-131 | Session Health: total, failure rate, status distribution, error categories, failure reasons | status + message | partial |  |
| _health_content:138 (`health#retry_sessions`) | Retry Failed Sessions | — | missing | needs API: open `health#retry_sessions`. |
| _health_content:150-320 | System Health: queue depth, jobs/hour, last finished, queue stats, backlog breakdown (ready/in-flight by queue and class, head of line), workers, database | status + message | partial |  |
| _health_content:330-355 | Network Egress (DNS): resolver, last checked, degraded since | status + message | partial |  |
| _health_content:362-405 | Agent Authentication: DB credentials, current account, accounts available, awaiting re-auth, refused credentials | status + message | partial | This is the accounts/quota panel on /health; the per-account quota windows live on /inference (outside this area). |
| _health_content:413-485 | SIGTERM Auto-Retry: recovered/exhausted, retry stats, rate-limit status | status + message | partial |  |
| _health_content:493-600 | API Error Auto-Retry: recovered/exhausted, quota limits (24h), retry stats | status + message | partial |  |
| _health_content:607-612 (`health#archive_old`) | Trash Sessions Older Than 7 Days | — | missing | needs API: open `health#archive_old`. |
| _health_content:615 | Link to GoodJob dashboard (`/jobs`) | — | web-only | GoodJob's own HTML console; no JSON surface. Its only phone-relevant use (unpause after queue recovery) is covered by the queue-recovery row above. |
| _health_content:622 | Link to /supervisor | — | web-only | See Supervisor block. |
| _health_content:636-665 | Retry Budgets: sessions / attempts / recent / exhausted per budget | status only | partial | `retry_budget_health.budgets`. |
| health/_post_deploy_tasks.html.erb:16-106 | Post-Deploy Tasks: succeeded/pending/running/failed, per-task table (status, last run, progress), "All runs" link | status + message | partial | Data in `post_deploy_task_health`. |
| _post_deploy_tasks:112 (`health#run_post_deploy_tasks`) | Re-arm and run now | — | missing | needs API: open `health#run_post_deploy_tasks`. |
| health/_cron_freshness.html.erb | On schedule / stale / behind / not judged, per-key table | status + message | partial |  |
| health/_log_retention.html.erb | Rows, size, indexes, oldest row / verbose | status + message | partial |  |
| health/_root_data.html.erb | Records, data, overdue expiry, per-namespace table, "All records" link | status + message | partial |  |
| health/_warm_clone_pool.html.erb | Claimed/missed, per-repo table, passed-over list | status + message | partial |  |
| health/_warm_process_pool.html.erb | Warm router process: state, age, model, account | status + message | partial |  |
| health/_inbound_events.html.erb | Webhook ingest per source: last delivery, deliveries, claimed via webhook/poll; Deliveries/Claims links | status + message | partial |  |
| _health_content:687-737 | Recent Failures (24h) table with session links | — | missing | `session_health.recent_failures` in API. |
| _health_content:744-785 | Recent Errors (1h) table | — | missing | In `system_health`. |
| _health_content:792-897 | Recent SIGTERM / API-error events tables | — | missing | In the two retry sections. |

#### Outcomes

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| outcomes/_page_header.html.erb:13-17 | Ledger / Stats / Goal checks tabs | — | missing |  |
| outcomes/_filters.html.erb | Created from/to, agent root, harness, model, analysis (analyzed/not), outcome; Clear | — | missing | `outcome_analyses#index` filters cover analyses only. |
| outcomes/index.html.erb:74-125 (`outcomes#index`) | Ledger table: session, root, harness, model, created, outcome pill, failed/segments, View | — | missing | needs API: open `outcome_analyses#index` to the native token **and** a session-level ledger (the web lists unanalyzed sessions too; the API lists analyses only). |
| index:30-45 (`outcomes#analyze_all`) | Analyze all matching, with concurrency | — | missing | needs API: no route. |
| outcomes/_batch_card.html.erb (`outcomes#cancel_batch`) | Batch progress (running/queued/saved/failed/canceled), Stop | — | missing | needs API: no route. |
| index:121 (`outcomes#analyze`) | Analyze / Re-analyze one session | — | missing | needs API: no route. |
| index:143-149 | Pagination | — | missing |  |
| outcomes/show.html.erb:10-30 (`outcomes#show`) | Header: title, session link, harness, analyzer session, Re-analyze | — | missing | `outcome_analyses#show` exists, closed. |
| show:40-57 | Tiles: segments, failed segments, segment success, max depth | — | missing |  |
| show:63-90 (Stimulus `outcome-flamegraph`) | Segment flamegraph with hover tooltips, cell↔row link | — | missing | A hover flamegraph is arguably unreadable at 375 px — but the same data is the table below, so the page is not web-only; only the drawing is. |
| show:95-125 | Segment table: segment, goal, trigger, outcome, why | — | missing |  |
| show:129-150 | Superseded analyses | — | missing |  |
| outcomes/stats.html.erb (`outcomes#stats`) | Tiles; by root/harness/model table (group_by); failed-per-transcript histogram; most failure-heavy transcripts | — | missing | needs API: no stats route. |
| outcomes/goal_checks.html.erb (`outcomes#goal_checks`) | Tiles (met/unmet/pending); unmet on its own PR; by criterion; by root/harness/model | — | missing | needs API: open `goal_checks#index` to the native token. |

#### Gate decisions (the agent gates' ledger)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| gate_decisions/_filters.html.erb:13-54 | Gate, surface, decision, decided from/to, artifact URL, full-text query, "with human feedback"; Apply / Clear | — | missing | API `FILTER_KEYS` support these. |
| gate_decisions/index.html.erb:22-118 (`gate_decisions#index`) | Table: decided, gate pill, surface, artifact (GitHub link), decision pill, note, Read; pagination | — | missing | needs API: open `gate_decisions#index/show` to the native token. |
| gate_decisions/show.html.erb:16-60 (`gate_decisions#show`) | Artifact, producing session, recorded by session, ledger row | — | missing |  |
| show:63-80 | "Another decision on this artifact" conflict notice with links | — | missing |  |
| show:93-150 | At a glance fields; The reasoning; other entry fields (`_field_value`) | — | missing |  |
| gate_decisions/_feedback.html.erb:13-62 (`gate_decision_feedbacks#create`) | Human feedback list + form (verdict, said on, note) | — | missing | needs API: a native-token feedback route. The controller keeps it browser-only because the fleet API key names no person — but the native token is per person, so that reason does not cover the phone. |

#### Issues (the work backlog)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| issues/index.html.erb:25 (`issues#refresh`) | Refresh (drop the GitHub cache) | — | missing | needs API: no route. |
| issues/_counts.html.erb | Queued / in flight / parked / stranded / queued convergent / divergent | — | missing | `work_backlog_items#index` returns `counts` (controller:261). |
| issues/_trend.html.erb (Stimulus `issue-trend`) | Open issues over time; window 7/30/90 d; segment by; scrub; legend toggles | — | missing | needs API: no trend route. |
| issues/_filters.html.erb:21-55 | Repo, direction, surface, kind, cost, pinned; Apply / Clear | — | missing | `WorkBacklog::Filters::KEYS` on the API. |
| issues/_queue.html.erb (`issues#index`) | Queued rows: #, issue (safe link), direction pill, kind, cost, precedence, cleared, labels, pinned / issue-closed flags | — | missing | needs API: open `work_backlog_items#index` to the native token. |
| issues/_promote.html.erb (`work_backlog_promotions#create`) | Promote (start now) | — | missing | needs API: open `work_backlog_items#start_now`. |
| issues/_pin.html.erb (`work_backlog_pins#create/destroy`) | Pin at precedence / Unpin | — | missing | needs API: open `#pin` / `#unpin`. |
| issues/_remove.html.erb (`work_backlog_removals#create`) | Remove with reason (pre-filled when the issue is closed) | — | missing | needs API: open `#remove`. |
| issues/_hold.html.erb (`work_backlog_holds#create`) | Hold with reason (stranded rows) | — | missing | needs API: open `#hold`. |
| issues/_started_rows.html.erb ×5 | In flight / parked on a person / recently ended / stranded (liveness) / awaiting decision, each with session link | — | missing |  |
| issues/_repo_summaries.html.erb + issues/_github.html.erb | "In GitHub, not on the queue": per-repo summary (errors), loose issues table with labels, opened, paged | — | missing | needs API: no route (GitHub is read in the web controller). |

#### Supervisor (`/supervisor/*`) and `/jobs`

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `config/routes.rb:2-150` (205 Administrate routes over ~50 tables; `/jobs` GoodJob mount) | Raw CRUD console: sessions, triggers, trigger_conditions, claude_accounts, app_settings, logs, users, post_deploy_task_runs, agent_root_records, webhook_deliveries, … including **editable** `mcp_oauth_credentials`, `mcp_oauth_pending_flows`, `x_oauth_credentials` whose edit forms hold plaintext tokens | — | web-only | Not admin-gated (`Supervisor::ApplicationController` has only `WebSignInRequired`; a security note, not a parity gap). Web-only: a generic table editor with no JSON surface, whose forms expose secrets a phone should not carry; what a phone operator needs (post-deploy runs, root data, webhook deliveries) is on /health, rowed there as partial. |
| supervisor/x_oauth_credentials/index,show; x_oauth_authorizations/new,manual,error | Connect / re-authorize an X account (OAuth consent round-trip, manual code finish) | — | missing | needs API: start and finish the X consent round-trip from the phone; `ASWebAuthenticationSession` runs the consent as the browser does. No REST under `/api/v1`. |

### E Global chrome

38 rows: 17 present, 3 partial, 10 missing, 8 web-only.

#### Navigation (board header, `app/views/sessions/index.html.erb`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| sessions/index.html.erb:52-70 + `mobile_menu_controller.js` | Hamburger toggles the mobile dropdown of every nav item | RootView.swift:34-72 TabView (Sessions / Inbox / Triggers / More) | present | Different shape, same reach for what is in the app; items it lacks are listed below. |
| sessions/index.html.erb:35, `2xl:` classes | Ultrawide sidebar layout | — | web-only | A phone has no 2xl viewport. |
| sessions/index.html.erb:72, :163 → `GET /supervisor` | Supervisor (Administrate dashboards) | — | missing | Operator surface, no REST reach. Cheapest parity: an "Open in browser" row under More using `AppModel.webURL(path:)`. |
| sessions/index.html.erb:75, :166 → `GET /good_job` (new tab) | Jobs dashboard | — | missing | Same as Supervisor: an "Open in browser" row. |
| sessions/index.html.erb:78, :169 → `GET /health` | Health link | App/Zimmer/Views/OperationsViews.swift:682 HealthView (More → Health) | present | Page content is area for Health; the nav reach is there. |
| sessions/index.html.erb:81, :172-176 + `app/views/clis/_cli_badge.html.erb` → `GET /clis`, `GET /clis/badge` | CLIs link with red issue-count badge (lazy turbo frame) | — | missing | No CLIs screen or badge in the app. API exists: `GET /api/v1/clis/status`, `POST /api/v1/clis/refresh`. |
| sessions/index.html.erb:84, :200-204 + `app/views/notifications/_notification_badge.html.erb` → `GET /notifications`, `GET /notifications/badge`; `turbo_stream_from "notification_badge"` (:31) | Notifications link with pending-count badge, live over Turbo Streams | RootView.swift:52 `.badge(model.unreadCount)` on the Inbox tab; `AppModel.refreshUnreadCount` via `GET /api/v1/notifications/badge` | partial | Same count (`Notification.pending_count`). The web updates the instant a notification lands; iOS recounts only after a board refresh (30 s poll), opening a session, or an Inbox action — on Triggers/More it goes stale |
| sessions/index.html.erb:87, :178 → `GET /triggers` | Triggers link | OperationsViews.swift:157 TriggersView (tab) | present |  |
| sessions/index.html.erb:90, :181 → `GET /connectors` | Connectors (MCP OAuth) link | — | missing | No app screen; `PARITY_AUDIT.md` G25 calls it "browser by choice". The connect/reconnect dance needs a browser, but the status list does not. needs API: connector list/status (none under `/api/v1`). |
| sessions/index.html.erb:93, :184 → `GET /costs` | Costs link | OperationsViews.swift:371 CostsView (More → Costs) | present |  |
| sessions/index.html.erb:96, :187 → `GET /outcomes` | Outcomes link | — | missing | API exists (`/api/v1/outcome_analyses`, rest-api.md "Outcome analyses"); G24 "not planned". |
| sessions/index.html.erb:99, :190 → `GET /gate_decisions` | Gate Decisions link | — | missing | API exists (`/api/v1/gate_decisions`); G24 "not planned". |
| sessions/index.html.erb:102, :193 → `GET /inference` | Inference (accounts, logins, policies) link | — | missing | No REST surface for inference accounts; the login flow is interactive. needs API. |
| sessions/index.html.erb:105, :196 → `GET /issues` | Issues / work backlog link | — | missing | API exists (`/api/v1/work_backlog`, rest-api.md "Work backlog"). |
| sessions/index.html.erb:108, :199 → `GET /settings` | Settings link | App/Zimmer/Views/SettingsView.swift (More → Settings) | partial | The app's Settings is sign-in, notifications, build only. The rest of `/settings` (defaults, catalog pins, models, API keys, plugins) is area A. |

#### Layout: banners, flash, bubble (`app/views/layouts/application.html.erb`)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| layouts/application.html.erb:30 → `shared/_queue_recovery_mode_banner.html.erb` | Global amber banner while QueueRecoveryMode halts queues: halted queues, reason, auto-resume countdown, "Manage" → /health | — | missing | Every web page says the instance is deliberately not processing work; the phone never does. API exists: `GET /api/v1/health` `queue_recovery_mode`; `HealthReport` (Operations.swift:560) decodes only `overall` + `sections` and drops it |
| layouts/application.html.erb:31 → `shared/_network_health_banner.html.erb` | Global red banner when worker DNS egress is degraded, since-time, "Health details" | OperationsViews.swift HealthView shows the `egress_health` section only when Health is opened | partial | No global surface; a person on the Sessions tab does not learn new logins will fail. Data already in `GET /api/v1/health` |
| layouts/application.html.erb:33-38 + `live_updates_status_controller.js` → `GET /live_updates/status` → `shared/_live_updates_paused_banner.html.erb` | "Live updates paused" banner, polled, while BroadcastService's breaker is open | — | web-only | The condition is Turbo Stream broadcasts being dropped; the app has no stream, it polls REST, so the freeze it warns about cannot happen on the phone. |
| layouts/application.html.erb:40 → `shared/_flash.html.erb:12-72`, `flash_controller.js` (also replaced over Turbo Streams by `TurboFlash`) | Notice/alert toasts top-right, auto-dismiss (`flash_duration_ms`), manual dismiss | SessionListView.swift:799 `Toast` (bottom, auto-dismiss) for `model.notice`; `ErrorBanner` (SignInView.swift) on every screen for `model.error` | present | Notices render only over the board; other screens surface errors inline. Equivalent in effect. |
| shared/_flash.html.erb:44-50 → `POST /sessions/:id/undo_archive` | Undo button inside the flash, lives as long as the server's undo window | SessionListView.swift:766 `UndoToast` → `AppModel.undoTrash` | present |  |
| shared/_flash.html.erb:53-60 → `POST /sessions/:id/archive?force=1` | "Archive anyway" when queued messages blocked the archive | `AppModel.queuedTrash` + `trash(force:)` (AppModel.swift:44, :377) | present |  |
| shared/_chat_bubble.html.erb:40, `chat_bubble_controller.js:102` | ⌘/Ctrl+K opens the bubble | — | web-only | Desktop keyboard shortcut. |
| shared/_chat_bubble.html.erb:118, `chat_bubble_controller.js:115` | ⌘/Ctrl+Enter submits in background | — | web-only | Desktop keyboard shortcut. |
| chat_bubble_controller.js:109; also Escape in `visibility_controller.js:228`, `joystick_menu_controller.js:61`, `dropdown`, `overflow_menu`, `bottom_drawer`, `session_drawer`, `session_notes`, `dashboard_notes`, `error_popover` | Escape closes the bubble / drawers / menus | — | web-only | Desktop keyboard; iOS sheets dismiss by swipe. No other global shortcuts exist (grep `keydown`). |

#### PWA, icons, theme (`public/`, `layouts/application.html.erb` head)

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| layouts/application.html.erb:11 → `public/manifest.json` (standalone, start_url `/`, portrait, maskable icons) | Installable PWA | The app itself | web-only | Installing a PWA is what the native app replaces. |
| layouts/application.html.erb:12, web_auth.html.erb:9, manifest `theme_color` `#031942` / `background_color` `#000e2b` | Brand navy chrome colour | App/Zimmer/Support/Theme.swift:18-38 (same navy, gold) | present |  |
| layouts/application.html.erb:15-18, `public/favicon.ico`, `public/icons/*` | Favicon / apple-touch-icon / 192 & 512 icons | App/Zimmer/Assets.xcassets/AppIcon.appiconset, ZimmerMark.imageset | present |  |
| `public/service-worker.js:11-44` | Push event → OS notification (icon, tag, sound) | ZimmerApp.swift:51-57 `willPresent` shows banner+list+sound even in foreground | present |  |
| `public/service-worker.js:47-92` | Notification click focuses/navigates an open window to `data.url` (always `/sessions/:id`, `send_push_notification_job.rb:198-207`) | ZimmerApp.swift:59-62 → PushCoordinator.swift:93-101 `open` sets `model.path = [session_id]` | present | APNs payload carries `session_id` + `notification_type` (`apns_service.rb:160-165`); every push type is session-scoped, so nothing is lost. The app does not switch to the Sessions tab first if another tab is selected — worth a device check |
| `public/404.html` via `ErrorsController#not_found` (catch-all route) | Styled 404 with "Go to Home"; API paths get JSON 404 | ZimmerError.swift:15 `.http(status,message)` → ErrorBanner | present | `public/500.html` does not exist (Rails' default is absent), so a 500 renders bare — a web defect, not a parity gap. |

#### Web push vs APNs

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| layouts/application.html.erb:19-21 `vapid-public-key` meta (`WebpushConfig`) | VAPID key for the browser subscription | App/Zimmer/Push.entitlements `aps-environment`; `PushCoordinator.environment` sandbox/production | present |  |
| `web_push_service.rb:98-106` payload `{title, body, data:{url, session_id, notification_type}}` | What a web push carries | `apns_service.rb:158-165`: `aps` alert + `thread-id` + `session_id`, `notification_type`; collapse-id per session+type (:171-175) | present | iOS threads and collapses per session; web uses one `tag`. |
| `GET /supervisor/apns_devices` | Operator view of registered phones | — | web-only | Operator surface about the phones themselves. |

#### Sign-in, session, "acting as you"

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `WebAuth::Cookies` (services/web_auth/cookies.rb:13, :70-74): 90-day encrypted session cookie, trusted-device cookie | How long the browser stays signed in | Sources/ZimmerKit/Auth/AuthSession.swift (Keychain `KeychainTokenStore`, refresh tokens, `OAuthSignIn.refreshRequest`) | present | Different mechanism, same effect: no re-login until revoked. |

#### Live updates

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| `timestamp_updater_controller.js` (session card, metadata, timeline rows) | Relative times tick every minute | SwiftUI `Text(date, style: .relative)` / `formatted(.relative)` (OperationsViews.swift:143, :301) | present |  |
| `page_header_offset_controller.js`, `bottom_panel_padding_controller.js`, `mobile_menu_controller.js` | Layout plumbing: sticky-header height var, composer padding, hamburger | Native layout | present | Nothing user-visible to port. |

#### External apps and "open in web"

| Web location | What it does | iOS equivalent | Status | Note |
| --- | --- | --- | --- | --- |
| (web → app) any `https://<zimmer>/sessions/:id` link: from a web push on another device, Slack, email, the transcript's `#message-N` links | Opening a Zimmer URL lands in the browser | App/Zimmer/Info.plist has no `CFBundleURLTypes` for content; no Associated Domains entitlement; the only scheme is `com.tadasant.zimmer:` for OAuth/Access callbacks (OAuthSignIn.swift:21-22) | missing | A tapped link on the phone never opens the app. needs: `/.well-known/apple-app-site-association` served by Rails, the `associated-domains` entitlement (Apple developer portal), and `onOpenURL` → `model.path` |
| `GET /up`, `GET /up/deep` | Liveness/deep health probes | — | web-only | Infrastructure probes. |
| `sessions/index.html.erb` (Live entry: the voice icon beside the board's controls, and a menu of the live modes) | Open Live Mode from the board | `SessionListView.swift` waveform button → `LiveViews.swift` (6556c1b3) | present | the modes from `GET /api/v1/live`, each with whether it can start |
| `live/index.html.erb` (`GET /live`): the overview — "One continuous conversation with Zimmer, typed or spoken", a card per mode, the OpenAI key panel | Read the modes and set or delete the OpenAI key | `LiveViews.swift` (6556c1b3): the modes and why one cannot start | partial | the OpenAI key's set/delete is the page's (`live_openai_key`), no REST; the app says to set it on the web |
| `live/show.html.erb` (`GET /live/:mode`): start a conversation in a mode, recent conversations | Start a live conversation | `LiveViews.swift` (6556c1b3): start, or resume the recent one | present | `POST /api/v1/live_conversations` |
| `live_conversations/show.html.erb`, `_turn`, `_header`: the conversation's turns, typed input, the session it runs in | Read and continue a live conversation, typed | `LiveViews.swift` (6556c1b3): the single-thread view with a composer, re-read every two seconds | present | — |
| `shared/_live_voice_dock.html.erb` (in the layout): the voice call's dock — mute, hang up, dismiss — above every page | A spoken conversation, continuous, with the call's controls on every page | `LiveCall.swift`, `LiveAudioEngine.swift`, `RealtimeConductor.swift` (6556c1b3): *Talk* opens a Realtime call, with Hang up; the same call in CarPlay | partial | the web's dock follows you to every page; the app's call controls live on the Live screen and in CarPlay |

Inventory notes from this area, not counted (neither side has it, or iOS has it and the web does not):

- layouts/application.html.erb:4 `<title>Zimmer</title>`. Static tab title; no needs-input/unread count in the title or favicon (grep `document.title`, `setAppBadge`: none). Not a gap: the web has none. Noted so nobody looks for it.
- `public/service-worker.js:95`. Service worker activation; no offline page, no precache (grep `offline`: none). Not a gap: the web is not offline-capable either.
- (none). No `beforeinstallprompt` handler, no dark mode (`prefers-color-scheme`/`dark:`: none), no STAGING banner on the web. iOS side: iOS has dark mode (Theme.swift) and a build strip (RootView.swift:12, BuildEnvironment.swift:47). iOS-only; see the list at the end.
- `local_time_controller.js`. Rewrites a UTC `<time>` into the viewer's zone. No consumer on `main` (grep `data-controller="local-time"`: none). Not a gap.
- `hello_controller.js`. Stimulus scaffold. No consumer. Not a gap.
- (app → web). iOS side: "Open in browser" on session rows (SessionListView.swift:477), session detail (SessionDetailView.swift:559, :949), trigger detail (TriggerDetailView.swift:250); `AppModel.webURL(for:)`/`webURL(path:)`. iOS-only affordance; not a gap.

## Web-only, with reasons

| Area | Web location | What it does | Reason |
| --- | --- | --- | --- |
| A | `new.html.erb:43` (if `@loopback_redirect`) amber loopback warning | Warns about a loopback redirect | Only a desktop/CLI client can present a loopback redirect |
| A | `POST /oauth/register` (`registrations#create`, RFC 7591) | Dynamic client registration | For third-party MCP clients such as Claude.ai |
| A | `GET /.well-known/oauth-protected-resource(/mcp)`, `GET /.well-known/oauth-authorization-server(/mcp)` (`metadata#protected_resource` / `#authorization_server`), `OPTIONS` preflights (`metadata#preflight`) | RFC 9728 / 8414 discovery + CORS | Machine endpoints for MCP clients |
| B | `_detail.html.erb:46-67` | "Session connection recovered" banner (`recently_recovered?`) | Announces an ActionCable re-subscribe; the app has no socket to recover |
| B | `shared/_composer_drop_overlay.html.erb` + `composer-drop` | Drag-and-drop files onto the composer | A pointer drag from another window is a desktop gesture; the picker/share sheet is the phone's path |
| B | `:198-204` label "Cmd+Enter to submit" + `handleKeydown` | Keyboard chord submits | Hardware-keyboard chord; the send button is the touch path |
| C | index.html.erb:790–832 slide-in notes sidebar (`dashboard-notes#open`, `manualSave`, autosave) | Edit a session's notes from the board | Unreachable on the web: nothing in `app/views` dispatches `dashboard-notes#open`, so the sidebar is dead markup. Notes are at parity on the session page |
| D | _health_content:615 | Link to GoodJob dashboard (`/jobs`) | GoodJob's own HTML console; no JSON surface. Its only phone-relevant use (unpause after queue recovery) is covered by the queue-recovery row above. |
| D | _health_content:622 | Link to /supervisor | See Supervisor block. |
| E | sessions/index.html.erb:35, `2xl:` classes | Ultrawide sidebar layout | A phone has no 2xl viewport. |
| E | layouts/application.html.erb:33-38 + `live_updates_status_controller.js` → `GET /live_updates/status` → `shared/_live_updates_paused_banner.html.erb` | "Live updates paused" banner, polled, while BroadcastService's breaker is open | The condition is Turbo Stream broadcasts being dropped; the app has no stream, it polls REST, so the freeze it warns about cannot happen on the phone. |
| E | shared/_chat_bubble.html.erb:40, `chat_bubble_controller.js:102` | ⌘/Ctrl+K opens the bubble | Desktop keyboard shortcut. |
| E | shared/_chat_bubble.html.erb:118, `chat_bubble_controller.js:115` | ⌘/Ctrl+Enter submits in background | Desktop keyboard shortcut. |
| E | chat_bubble_controller.js:109; also Escape in `visibility_controller.js:228`, `joystick_menu_controller.js:61`, `dropdown`, `overflow_menu`, `bottom_drawer`, `session_drawer`, `session_notes`, `dashboard_notes`, `error_popover` | Escape closes the bubble / drawers / menus | Desktop keyboard; iOS sheets dismiss by swipe. No other global shortcuts exist (grep `keydown`). |
| E | layouts/application.html.erb:11 → `public/manifest.json` (standalone, start_url `/`, portrait, maskable icons) | Installable PWA | Installing a PWA is what the native app replaces. |
| E | `GET /supervisor/apns_devices` | Operator view of registered phones | Operator surface about the phones themselves. |
| E | `GET /up`, `GET /up/deep` | Liveness/deep health probes | Infrastructure probes. |
| D | `config/routes.rb:2-150` (205 Administrate routes over ~50 tables; `/jobs` GoodJob mount) | Raw CRUD console: sessions, triggers, trigger_conditions, claude_accounts, app_settings, logs, users, post_deploy_task_runs, agent_root_records, webhook_deliveries, … including **editable** `mcp_oauth_credentials`, `mcp_oauth_pending_flows`, `x_oauth_credentials` whose edit forms hold plaintext tokens | Not admin-gated (`Supervisor::ApplicationController` has only `WebSignInRequired`; a security note, not a parity gap). Web-only: a generic table editor with no JSON surface, whose forms expose secrets a phone should not carry; what a phone operator needs (post-deploy runs, root data, webhook deliveries) is on /health, rowed there as partial. |

## Open PRs that close rows

Taken from the rows' notes ("in #NNNN"). Only the session page, the board and the triggers page are touched; areas A and E have no row in any open PR.

**#1282 — answer MCP prompts natively, fork from a message.** Flips four B rows from missing to `present`:

- `elicitations/_elicitation_banner.html.erb:1-133` — pending MCP elicitation with schema-driven fields, Accept / Decline / Dismiss (`ElicitationViews.swift` PromptCard + ElicitationSheet, via `GET …/elicitations` and `PATCH /elicitations/:id/respond`).
- `session_X_elicitations` / `session_X_lost_elicitation` streams — elicitation banners come and go (polled).
- `timeline_items/_item.html.erb:113-134` `fork-session` — Fork conversation from this message (`MessageBubble` context menu "Fork from Here"; runtime notices are not forkable there because they are not sent).
- `timeline_items/_item.html.erb:135-150` `message-copy` — Copy a single message's markdown (context menu "Copy").

**#1284 — Merge and Reprioritize.** Flips two C rows from `missing` to `partial`:

- `_user_view_sessions.html.erb:38` Reprioritize — view menu → confirm → `POST /api/v1/sessions/reprioritize`; partial because the "Working in session #N" link is not shown (the response carries `session`, the PR shows only `message`).
- `_user_view_merge_button.html.erb` Merge — swipe/context "Merge" with confirm → `POST /api/v1/sessions/:id/authorize_merge`; partial because the "Merge sent" state is not shown afterwards (`merge_authorized_at` is not in `session_json`).

**#1341 — the Settings page's row on REST, API half (auth boundary).** Opens `GET`/`PATCH /api/v1/app_settings` to the app's token: the session defaults and the experimental toggles on any grant, the MCP Apps switch and allowlist only on a grant that acts as you. The app half (Settings → Session Defaults, Experimental, MCP Apps) stacks on it and flips A's rows for `show.html.erb:21-88`, `147-176` and `184-243`.

**#1343 — the operations routes open to the app's token, API half (auth boundary).** Opens triggers create/update/destroy and the form's pickers, every health operator action, the work backlog (the human-only levers on a grant that acts as you), the gate-decision and outcome ledgers, the CLIs page's actions and the costs sweep. Flips the "needs a route opened" group's rows from refused to reachable; the screens follow.

**#1344 — Settings → Session Defaults, Experimental and MCP Apps in the app.** The app half of #1341; flips A's rows for `show.html.erb:21-88`, `147-176` and `184-243` to `present`.

**#1345 — Health, Costs and the trigger page read everything the API sends; Run Now fills a template's variables.** Flips the ranked list's app-only items 1, 2 and 5: D's health rows (every section, the banners on the board), the costs rows, and the trigger page's scheduling class, precedence, catalog chips, windows and variables.

**#1346 — who is signed in, the OAuth grants, API keys and sign-out-everywhere on REST, API half (auth boundary).** `GET /api/v1/me`, `/oauth_grants`, `/api_keys`, `POST /sign_out_everywhere`; every write only on a grant that acts as you. Flips A §4 and §7's "needs API" notes and E's sign-in rows from no-API to reachable.

**#1347 — a phone-started session is priority, as the web's is; rows carry genesis, precedence, root and every PR; cost on the page; Quick Router page context.** Flips the ranked list's app-only items 3, 4, 6 and 8 and C's rows for `new.html.erb:196-246, 256, 430`, `_session_card:95-108`, `_ranked_row:100-111, 178`, B's `_detail.html.erb:123`, and the genesis/spot row under "needs a new API" (resolved by a create rule instead of a genesis).

**#1348 — Settings → the Sign-in card, Deployment Information, and API keys & connections.** The app half of #1346; flips A's rows for `_web_sign_in.html.erb`, `show.html.erb:113-127` and `386-430`, and `api_keys/*`.

**#1349 — triggers are created, edited and deleted from the app.** The app half on #1343's routes; flips D's trigger-form rows.

**#1350 — the Health page's operator actions, Costs' Sweep now, and the CLIs page.** On #1343's routes; flips D's health-action and costs-sweep rows and A §3's `/clis` rows (the SSH hint stays out: the API does not carry the Tailscale IP).

**#1352 — main's Release build.** Not a parity row: the session page's single modifier chain exceeded the Release build's type-check budget after #1284; split into four expressions.

**#1353 — the Inference page over REST, API half (auth boundary).** `GET /api/v1/inference` and its writes, the CLI login flow included; flips A §2's 47 rows from no-API to reachable. The app half follows.

**#1318 — a trigger's two re-use switches, API half only.** Opens `POST /api/v1/triggers/:id/toggle_enqueue_messages` and `…/toggle_resuscitate_archived` to the native token and changes no iOS file, so these two D rows stay `partial` (value shown, switch absent) until an app change follows:

- `triggers/show.html.erb:264-274` Enqueue messages value + switch.
- `triggers/show.html.erb:277-287` Resuscitate archived value + switch.

## Routes census

Every HTML route a signed-in person reaches, from `config/routes.rb` at `1dc36979`, with `/api/**`, `/mcp*`, `/webhooks/*`, `/.well-known/*`, `/oauth/register|token|revoke`, `/up`, `/up/deep` and `/native/access-handoff` excluded as machine endpoints:

| Area | Routes |
| --- | ---: |
| A — Settings and account | 58 |
| B — Session detail page | 45 |
| C — Board, new session, quick router | 16 |
| D — Operations (incl. 205 Administrate routes under `/supervisor` and the GoodJob mount) | 256 |
| E — Global chrome | 7 |
| **Total** | **382** |

The cross-check (the cross-check (kept outside the repo)) matched all 382 against the five area files by controller#action and by path: every route is accounted for by a row or a `## Routes covered` entry, and the only two with no row are route-level redirects for stale links (`GET /sessions` → `/`, `GET /quotas` → `/inference`), which are not something a person uses. Nothing had to be added; the cross-check instead found 44 duplicate rows where two areas rowed the same item, and the matrix above keeps one copy of each.

Two web routes are dead on the web side — nothing in `app/views`, `app/javascript` or `app/helpers` reaches them: `POST /sessions/bulk_archive` (`sessions#bulk_archive`; its only callers are the API twin, the `action_session` MCP tool and the Slack poller — the iOS app has multi-select trash, the web does not), and `GET /mcp_oauth/status/:session_id` (`mcp_oauth#status`; renders a partial whose Stimulus controller does not exist and that nothing polls).
