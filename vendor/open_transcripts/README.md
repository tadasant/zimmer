# Vendored OpenTranscripts snapshot

`app/services/open_transcript.rb` is a hand-written Ruby mirror of the
OpenTranscripts v0.1 spec and its reference converters, which live in
[`pulsemcp/ai-artifacts`](https://github.com/pulsemcp/ai-artifacts). A hand-written
mirror drifts. This directory is what makes the drift visible instead of silent.

## What is here

- `upstream/` — a byte-for-byte snapshot of the upstream files Zimmer mirrors.
  Do not edit these by hand; they are not Zimmer's code.
- `UPSTREAM.json` — the pin: repository, branch, the commit the snapshot was
  taken at, and a SHA-256 for each file.

## The two links, and what checks each

Drift can happen on either side of the snapshot, so both sides are checked.

| Link | Checked by | When |
| --- | --- | --- |
| Zimmer's Ruby ↔ the snapshot | `test/services/open_transcript_drift_test.rb` | every CI run, offline |
| The snapshot ↔ upstream `main` | `scripts/check_open_transcripts_drift.rb` | daily schedule, manual dispatch, and any PR that touches these files |

The test is offline and deterministic: it re-derives the digests in `UPSTREAM.json`
from the files on disk, and asserts that `OpenTranscript` still agrees with the
snapshotted spec (the nine event-type discriminators, the schema version) and that
`TranscriptRedactor` still covers every redaction label the upstream reference
redactor ships.

The script talks to GitHub. It runs on a schedule rather than on every PR so that
an upstream commit does not turn every unrelated pull request red — but it does
fail loudly, and `.github/workflows/alert-ci-failure.yml` posts any failed workflow
in this repo to Slack.

## Updating the snapshot when upstream moves

1. Run `bin/rails open_transcripts:check_drift` (or `ruby scripts/check_open_transcripts_drift.rb`)
   to see which files moved.
2. Fetch the new bytes for each drifted file into `upstream/`, e.g.
   `gh api "repos/pulsemcp/ai-artifacts/contents/<upstream path>?ref=<sha>" --jq .content | base64 -d > upstream/<local path>`.
3. Update `ref`, `captured_at`, and the changed `sha256` values in `UPSTREAM.json`.
4. **Read the diff and decide what it means for Zimmer.** This is the step the
   whole mechanism exists for. A new event type, a changed field, a new redaction
   pattern upstream — each is a change `app/services/open_transcript.rb` or
   `app/services/transcript_redactor.rb` may need to make too. Deciding that a
   change does *not* apply to Zimmer is a fine outcome; deciding it silently is not.
5. Run `bin/rails test test/services/open_transcript_drift_test.rb`.

## Deliberate divergences

Zimmer's mirror is not a port. Where it differs on purpose:

- **Redaction runs at a different layer.** The reference converter redacts while
  converting; Zimmer redacts at `TranscriptSource#read` (`TranscriptRedactor`),
  because Zimmer also stores the raw transcript string and the point is to keep
  credentials out of the database, not only out of the rendered events.
- **Per-line normalization** with no cross-line timestamp carry-forward.
- **Several envelope fields are hardcoded to null** (`cost_usd`, `model_default`).
- **Events carry Zimmer-internal adornments** (`sort_time`, `transcript_index`,
  `event_order`) that the spec does not define and ignores.
