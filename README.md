# Zimmer

**Zimmer is a self-hostable orchestrator for AI coding agents.** You give it a task
and a repo; it runs a real Claude Code or Codex session in an isolated clone, streams
the transcript, and hands you back a pull request to approve — or a specific question
about why it couldn't. You stay in control of what runs and what merges.

## Why run it

- **It isn't a bet on one vendor.** The agent harness is a registry behind a contract:
  Claude Code and Codex both ship today, and you pick the model per session (Claude or
  OpenAI). MCP servers are a JSON entry, not a code change. Nothing in the design assumes
  whose agent wins — which is the point, because nobody knows yet.
- **A boring stack on one cheap box.** Rails 8, PostgreSQL, Redis, GoodJob, Hotwire. It's
  a Docker image that Kamal ships to any Linux host you can SSH into; a single small
  droplet runs the whole thing. No per-seat bill, no exotic infra to keep alive.
- **You sign in — you don't paste keys.** The goal is to juggle as few long-lived secrets
  as possible. Claude and Codex authenticate against your own account over OAuth, `gh` uses
  the device flow, and MCP servers register themselves and refresh their own tokens. Short-
  lived credentials the runtime manages beat an API key pasted into a config file — and
  never sitting in one is the surest way to keep it out of a transcript.
- **It follows you off the laptop.** Install it as a PWA and it web-pushes your phone when
  a session finishes, fails, or stops to ask you something.
- **A UI shaped around work that outlives your attention.** Pinned sessions and
  categories, "blocked by" dependencies between sessions, live PR and CI status on each
  session, search across full transcripts, opt-in heartbeats that nudge an idle agent, and
  goals that spell out what "done" actually requires.

The honest exception: cloning works against any git remote, but the PR, CI, and
review-comment automation is GitHub-specific today.

It's a Rails 8 app (Ruby 3.4, PostgreSQL, Redis, GoodJob, Hotwire, Tailwind), packaged
as a Docker image and deployed to a single DigitalOcean droplet on a Tailscale tailnet.

> **Status:** early but real — CI is green and the app runs on a live tailnet-gated
> staging box. Expect rough edges; the docs name them.

## Documentation

**Everything lives at [docs.zimmer.tadasant.com](https://docs.zimmer.tadasant.com/)** —
architecture, philosophy, the REST API, the AIR catalog chapter, and a candid, file-by-file
[Known limitations](https://docs.zimmer.tadasant.com/limitations/) page. The premise is that
you can read the docs instead of the code.

Start there:

- **[Run it locally](https://docs.zimmer.tadasant.com/start/local/)** — the fastest look.
- **[Your first session](https://docs.zimmer.tadasant.com/start/first-session/)** — prompt to PR.
- **[Self-host your own](https://docs.zimmer.tadasant.com/operate/self-hosting/)** — stand up a real instance.
- **[What Zimmer is](https://docs.zimmer.tadasant.com/intro/what-zimmer-is/)** — if you're new to the idea.
- **[Known limitations](https://docs.zimmer.tadasant.com/limitations/)** — read this before you trust anything else.

## Try it locally

```bash
bundle install
cp .env.example .env          # then set ANTHROPIC_API_KEY
bin/rails db:setup
bin/dev                        # → http://localhost:3000
```

Prerequisites and the environment variables that matter are in
[Run it locally](https://docs.zimmer.tadasant.com/start/local/).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the agent instructions in
[AGENTS.md](AGENTS.md) (`CLAUDE.md` is a symlink to it). Docs live in [`docs/`](docs) and are
updated in the same PR as the behavior they describe.

```bash
bundle exec rubocop         # lint
bin/brakeman -q             # security scan
bin/rails test              # unit + integration
```

## License

MIT — see [LICENSE](LICENSE).
