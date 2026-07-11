# Zimmer brand voice

How Zimmer sounds in writing: docs, README, UI copy, PR descriptions, commit
messages. This is downstream of `BRAND.md` — the voice exists to carry the
brand. When in doubt, plainer and more specific wins.

## Who you're writing to

One smart reader who can read code and doesn't need their hand held. They came
for a fact, not a mood. Respect their time: lead with the point, be specific,
and stop when you've said it.

## The voice in one line

Plain, direct, and honest — a competent engineer explaining a system they know
cold, with nothing to sell.

## Principles

- **Lead with the point.** No throat-clearing, no "in this section we will." The
  first sentence is the answer.
- **Second person, active voice.** "You give it a task." Not "a task is given."
- **Be concrete.** Name the file, the constant, the line. A specific
  `TRASH_RETENTION_PERIOD = 4.days` beats "a short retention window."
- **Explain the why, skip the obvious.** The reader can see *what* the code does;
  tell them *why* it's shaped that way. Don't narrate the self-evident.
- **Honest by default.** State what's broken, assumed, or unknown. A visible
  "unclear — needs confirmation" is worth more than a confident guess.
- **Confident, not breathless.** No hype. The facts are interesting enough.
- **Let structure carry emphasis.** A heading, a list, or a callout does the work
  that bold-in-the-middle-of-a-sentence tries to do. Reserve **bold** for genuine
  warnings.

## AI-slop tells to cut

These are the patterns that make writing read as machine-generated. Cut them.

- **The antithesis reflex.** "It's not just a docs site, it's a…", "This isn't X,
  it's Y." State the thing directly and delete the foil. If you catch yourself
  writing "not merely," rewrite the sentence.
- **Em-dash overload.** One dash a paragraph, at most. Prefer a period. Two dashes
  in one sentence is almost always a rewrite.
- **Rule-of-three padding.** "Fast, simple, and reliable." Say the one that's
  true and load-bearing; drop the rhythm-fillers.
- **Bold sprinkled for emphasis.** If everything is bold, nothing is. Bold marks
  a warning or a term being defined, not "this part is important too."
- **Emoji as decoration.** The one exception in these docs is the 🔴 severity
  marker on the limitations page, which is functional. Otherwise, no.
- **Filler verbs and hype adjectives.** Cut: leverage, utilize, delve, dive in,
  unpack, navigate (metaphorical), empower, seamless, robust, powerful,
  effortless, blazing-fast, cutting-edge, elegant.
- **Weasel intensifiers.** Cut: simply, just, basically, essentially, actually,
  really, very, quite. They almost always weaken the sentence.
- **Callout stacking.** Three `:::caution` blocks in a row is a wall, not a
  signal. Consolidate, or fold the minor ones into prose.
- **Generic openers.** "In today's fast-paced world," "Let's take a look,"
  "Imagine a scenario." Delete on sight.
- **Uniform sentence rhythm.** The short-punchy-fragment-then-a-longer-one cadence,
  repeated, reads as a tic. Vary it, or just write plainly.

## Mechanics

- Sentence case for headings. ("Known limitations," not "Known Limitations.")
- Oxford comma.
- Backticks for code, paths, identifiers, filenames, env vars, and commands.
- Prefer a period to a semicolon in prose.
- Spell out the trust model in Zimmer's own terms (see `BRAND.md`): a single
  circle of trust, secure downstream, no enterprise gating.

## Before / after

| Slop | Rewrite |
| --- | --- |
| "Zimmer isn't just an orchestrator — it's a whole new way to think about agentic workflows." | "Zimmer runs coding agents and hands you back a pull request." |
| "Simply configure your robust, seamless MCP servers to leverage powerful tooling." | "Add the MCP servers a session needs. Each one is a tool the agent can use." |
| "It's important to note that the session, in many cases, may potentially fail." | "A session can fail. When it does, it moves to `failed` and keeps the transcript." |
| "In this section, we'll dive deep into the fascinating world of the state machine." | "Every session is in one of five states. Here's the machine." |

## The test

Read it aloud. If it sounds like a person who knows the system talking to a peer,
it passes. If it sounds like a brochure or a chatbot, cut until it doesn't.
