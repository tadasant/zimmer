---
name: zimmer-change-ai-artifact
title: Change a Zimmer AI Artifact
description: >
  Add or change an AI artifact in this repo — a skill, agent root, MCP server,
  plugin, hook, or reference. Zimmer ships a SELF-CONTAINED AIR catalog: the
  top-level artifact indexes wired by `air.json` are the catalog, resolved
  offline with no network and no private GitHub catalogs. Covers where each
  artifact type lives, how `default_in_roots` makes an artifact default-on, the
  resolution invariants the whole test suite depends on, and how to verify a
  change before pushing. An artifact change is NOT an app bug — do not go
  looking for one in `app/`.
user-invocable: true
---

# Change a Zimmer AI Artifact

Zimmer resolves its agent artifacts through the **AIR CLI** (`@pulsemcp/air-cli`,
pinned by `AirPrepareService::AIR_CLI_VERSION`). Unlike deployments that point AIR
at remote GitHub catalogs, **Zimmer's catalog is self-contained**: every artifact
index lives in this repo and resolves fully offline. That is a deliberate
property — do not introduce a `catalogs: ["github://..."]` source without a very
good reason, and never one that requires private access.

## Where things live

`air.json` (dev/test) and `air.production.json` (the in-image config used in
production/staging) wire six artifact types to top-level indexes:

| Type | Index | Bodies |
| --- | --- | --- |
| Skills | `skills/skills.json` | `skills/<id>/SKILL.md` |
| Agent roots | `roots.json` | — (roots are pure metadata) |
| MCP servers | `mcp.json` | — |
| Plugins | `plugins/plugins.json` | `plugins/<id>/.plugin/plugin.json` |
| Hooks | `hooks/hooks.json` | `hooks/<id>/` |
| References | `references/references.json` | `references/<file>.md` |

The Rails side reads all six through one seam — `AirCatalogService`, which shells
out to `air resolve --json --no-scope --git-protocol https` and caches the parsed
tree (60s TTL). `SkillsConfig`, `AgentRootsConfig`, `PluginsConfig`,
`ReferencesConfig` are thin readers over it. **Never parse the JSON indexes
directly from app code** — go through `AirCatalogService`.

## Adding a skill

1. Create the body: `skills/<skill-id>/SKILL.md`, with YAML frontmatter
   (`name`, `title`, `description`, `user-invocable`).
2. Register it in `skills/skills.json`:

   ```json
   "my-skill": {
     "id": "my-skill",
     "title": "My Skill",
     "description": "What it does and when to reach for it.",
     "path": "my-skill",
     "user_invocable": true,
     "default_in_roots": ["zimmer"]
   }
   ```

   `path` is **relative to `skills/skills.json`** — AIR absolutizes it on resolve.

3. Only **Zimmer-specific** skills belong here. Generic workflow skills (`pr`,
   `wait-for-ci`, `analyze-agent-transcript`, …) come from the orchestrator's own
   default skill set. Duplicating one here creates a shortname collision, and AIR
   **hard-fails the entire resolve** on a cross-scope collision — which takes down
   catalog resolution for every session, not just yours.

## `default_in_roots` — how an artifact becomes default-on

Zimmer uses AIR's **inverted root-membership** model. Membership is declared on
the *artifact*, not the root: an artifact names the roots it is a default of via
`default_in_roots`, and AIR runs an inversion pass at resolve time that computes
each root's effective defaults (`default_skills`, `default_mcp_servers`,
`default_plugins`, `default_subagent_roots`).

So `"default_in_roots": ["zimmer"]` on a skill is what makes AIR inject that skill
automatically into every session on the `zimmer` root. You do **not** hand-edit a
`default_skills` array on the root — it does not exist in `roots.json` and is
computed.

Two consequences worth internalizing:

- **The named root must exist in `roots.json`.** A `default_in_roots` pointing at
  an unknown root is a dangling reference (see the next section).
- The same mechanism is why `roots.json`'s `catalog-mgmt-*` roots declare
  `"default_in_roots": ["catalog-management"]` and the `catalog-management` root
  ends up with `default_subagent_roots` it never declares.

## The invariant that will bite you: no dangling references

`AirCatalogService#run_air_resolve!` treats a resolve that exits 0 but drops an
unresolvable reference as a **failure**. AIR prints
`... references unknown <type> "<id>". ... Dropping the reference.` on stderr and
still exits 0; Zimmer detects that string and raises `CatalogError` rather than
persisting a structurally-incomplete tree (which would silently strip roots'
defaults and overwrite the last-known-good snapshot).

Practically: if you reference a skill, MCP server, hook, plugin, reference, or
root **that does not exist**, catalog resolution goes degraded, the app serves a
stale snapshot, and **the test suite fails globally** — `test/test_helper.rb`
pre-warms the catalog at boot before forking its parallel workers. A wave of
unrelated `ActiveRecord::RecordInvalid` failures in session-creating tests is the
classic symptom.

Note the asymmetry: AIR validates *references between entries*, but does **not**
validate that a skill's `path` directory exists on disk. A registered skill with
no `SKILL.md` resolves clean and fails silently at injection time. Always create
the body.

## Verify before you push

Resolve the catalog exactly the way the app does:

```bash
AIR=~/.cache/air-cli/node_modules/.bin/air   # or /opt/air-cli/node_modules/.bin/air
AIR_CONFIG=$PWD/air.json $AIR resolve --json --no-scope --git-protocol https \
  > /tmp/resolve.json 2>/tmp/resolve.err
echo "exit=$?"; cat /tmp/resolve.err          # MUST be empty — any "Dropping the reference" is a failure
```

Then assert the shape you expect:

```bash
ruby -rjson -e '
  j = JSON.parse(File.read("/tmp/resolve.json"))
  j.each { |type, entries| puts "#{type}: #{entries.size}" }
  puts "zimmer default_skills: #{j["roots"]["zimmer"]["default_skills"].inspect}"
'
```

Every artifact type must be non-empty, `resolve.err` must be silent, and your new
skill must appear in the `zimmer` root's computed `default_skills`.

Also confirm each registered skill actually has a body:

```bash
ruby -rjson -e '
  JSON.parse(File.read("skills/skills.json")).each do |id, e|
    body = File.join("skills", e["path"], "SKILL.md")
    puts "#{File.exist?(body) ? "OK  " : "MISS"} #{id} -> #{body}"
  end
'
```

Then run the config-service tests, which assert on real catalog contents:

```bash
bin/rails test test/services/air_catalog_service_test.rb \
               test/services/agent_roots_config_test.rb \
               test/services/skills_config_test.rb \
               test/services/plugins_config_test.rb \
               test/services/references_config_test.rb
```

## Things that reach into the indexes by path

Moving or renaming an index is not just an `air.json` edit — a couple of build-time
consumers read a file path directly:

- `bin/preinstall-mcp-packages` reads `mcp.json` to pre-install MCP npm/python
  packages.
- `Dockerfile.base` `COPY`s `mcp.json` into the base image for that step.

Grep before you move anything:

```bash
git grep -n "mcp.json\|skills.json\|roots.json\|air.json" -- ':!vendor' ':!node_modules'
```

## This is not an app bug

An artifact change is a data/config change. If a session got the wrong skills or
MCP servers, the fix is almost always in these indexes — not in `app/services/`.
Reach for `app/` only when the *resolution machinery itself* is wrong
(`AirCatalogService`, `AgentRootsConfig`, `SkillsConfig`, `AirPrepareService`).

## Related

- `docs/MCP_CONFIGURATION.md` + `docs/mcp.schema.json` — the MCP entry schema.
- `docs/ADDING_AN_AGENT_HARNESS.md` — adding a runtime (a different axis entirely).
- `skills/zimmer-run-tests` — the suite, and why a bad catalog breaks all of it.
