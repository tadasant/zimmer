# Zimmer

**Zimmer is a self-hostable orchestrator for AI coding agents.** You give it a task
and a repo; it runs a real Claude Code or Codex session in an isolated clone, streams
the transcript, and hands you back a pull request to approve — or a specific question
about why it couldn't. You stay in control of what runs and what merges.

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
