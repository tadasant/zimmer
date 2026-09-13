# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/sessions: create a session, resolve the agent root's
    # catalog defaults onto it, and queue the agent job when a prompt is given.
    #
    # A session names its target repository either with `agent_root` (a catalog
    # root, which brings its repository and its default artifacts with it) or with
    # a bare `git_root` URL, which brings nothing — the same two ways POST
    # /api/v1/sessions accepts. One of them is required. (The new-session form is
    # narrower than both: it offers the catalog's roots and nothing else.)
    #
    # A restricted connection (allowed_agent_roots) may only spawn one of its
    # allowed roots, and must use that root's exact default MCP servers — the
    # same lock the decoupled server enforced from ALLOWED_AGENT_ROOTS. It may
    # not name `plugins` at all, because a plugin bundles servers of its own and
    # would otherwise reach around that lock. For the same reason it may not name
    # `git_root`, `branch` or `subdirectory`: those choose a repository, and
    # choosing repositories is exactly what allowed_agent_roots decides.
    class StartSession < Tool
      include PrecedenceArgument

      tool_name "start_session"

      AGENT_RUNTIME_DESC = <<~TEXT.strip
        Per-spawn agent runtime override. Valid values are "claude_code" (Claude Code), "codex" (OpenAI Codex CLI) and "pi" (Pi coding agent). When omitted, the session adopts the agent_root's default_runtime, then the global session default configured on the Settings page, then "claude_code". Call get_configs to see each agent root's default_runtime and the models each runtime accepts. Pair with `config.model` to pick a model valid for the chosen runtime (e.g. "opus"/"sonnet"/"haiku"/"fable" for claude_code, "gpt-5.6-sol"/"gpt-5.6-terra"/"gpt-5.6-luna" for codex, and provider-qualified ids like "#{ModelCatalog.default_for("pi")}" for pi).
      TEXT

      PROMPT_DESC = "Initial prompt for the agent. If provided, the agent job is automatically queued. Omit for a clone-only session."

      AGENT_ROOT_DESC = "Agent root name from get_configs. The API resolves git_root, branch, subdirectory, default_model, and other defaults from the agent root configuration. Prefer it over `git_root` whenever a catalog root covers the repository, so the session inherits the correct repository, model, and settings. Either this or `git_root` is required."

      GIT_ROOT_DESC = <<~TEXT.strip
        Repository to spawn against directly, as a clone URL ("https://github.com/owner/repo.git") or a local path — for a repository no catalog agent root covers (a fork, a scratch repo, a one-off). Either this or `agent_root` is required; a call naming neither is refused.

        A `git_root` spawn inherits NO catalog defaults: it gets none of the MCP servers, skills, hooks or plugins a root would bring, so name the ones it needs. Its runtime and model resolve through the global defaults on the Settings page unless you pass `agent_runtime` / `config.model`.

        Passing both `agent_root` and `git_root` is allowed and means "this root's tooling against that repository": the git_root wins over the root's URL, and the root's other defaults still apply.

        Rejected on a connection restricted to specific agent roots — such a connection spawns only into the repositories its allowed roots name.
      TEXT

      BRANCH_DESC = "Git branch to check out. Defaults to the agent_root's default_branch, or \"main\" on a rootless `git_root` spawn. Rejected on a connection restricted to specific agent roots, which takes its branch from the allowed root's catalog entry."

      SUBDIRECTORY_DESC = "Subdirectory within the repository the session should work in, for a monorepo. Defaults to the agent_root's subdirectory, or the repository root on a rootless `git_root` spawn. Rejected on a connection restricted to specific agent roots, which takes its subdirectory from the allowed root's catalog entry."

      TITLE_DESC = <<~TEXT.strip
        STRONGLY RECOMMENDED: Always set a title — treat it as effectively required. The title appears in the Zimmer web UI and push notifications, making sessions identifiable at a glance. Compose a short, descriptive title (under 70 characters) that captures what the session is doing (e.g. "Fix login redirect loop on mobile Safari", "Add dark mode toggle to settings page"). Only omit if you truly have zero context about the session purpose, which should be extremely rare.
      TEXT

      SLUG_DESC = "URL-friendly identifier for the session. Must be unique, and cannot be all digits — " \
                  "an all-digit identifier always resolves as a session id, so such a slug would be unreachable."

      GOAL_DESC = 'Goal ID from get_configs (e.g. "open-reviewed-green-pr"). The description is automatically resolved and passed to the agent as context. A free-text sentence is also accepted; a single word that is not a known goal ID is rejected as a typo.'

      # The one sentence every list-valued parameter below repeats, because the
      # failure it prevents was a caller that had read "drop what you don't need"
      # and wrote a fresh one-element list: the root's OTHER default went with it,
      # and the skill that needed that server was still attached. Stated per
      # parameter rather than once in the tool description — an agent composing a
      # single argument reads that argument's description, not the prose above it.
      REPLACES_DEFAULTS = "REPLACES the agent root's %s — the two are never merged. " \
                          "Whatever you pass is the complete final set, so every default you do not " \
                          "name is dropped. Do not write this list from scratch: read the root's %s in " \
                          "get_configs, copy it, and subtract only what the task genuinely must not have."

      MCP_SERVERS_DESC = <<~TEXT.strip
        The session's MCP servers, by name. A non-empty list #{format(REPLACES_DEFAULTS, "default_mcp_servers", "default_mcp_servers")} Omit the parameter to take the root's defaults unchanged — the right call unless you have a reason to narrow. Pass [] to attach none of the catalog's servers; Zimmer's own zimmer-self-session is injected either way.

Dropping a default silently is how sessions lose a capability they were built around: a root's skill can depend on a root's server (an upload skill on a filesystem server, say), and the skill still loads when the server is gone — the session then fails at the point of use, mid-task, with no workaround. If you are unsure whether a default is needed, keep it.

Example: an agent root defaulting to ["github-development", "slack"] and a task that needs no Slack takes mcp_servers: ["github-development"] — the full default list minus the one server, not a list written from the task's needs.

On a connection restricted to specific agent roots you cannot narrow at all: pass the root's defaults exactly, or omit the parameter.
      TEXT

      SKILLS_DESC = <<~TEXT.strip
        The session's skills, by name. A non-empty list #{format(REPLACES_DEFAULTS, "default_skills", "default_skills")} Omit the parameter to take the root's default_skills unchanged; pass [] for no skills.

        Add extras beyond the defaults freely. Removing a default skill should be rare and intentional — only when you have a specific reason, like replacing one with a more capable variant covering the same ground. Skills are lightweight text files with no blast radius, so keeping all defaults costs nothing. Example: ["discovery-classify", "publish-and-pr"]
      TEXT

      PLUGINS_DESC = <<~TEXT.strip
        The session's plugins, by name. Plugins extend agent capabilities with additional integrations, and can bundle skills, hooks, and MCP servers of their own. A non-empty list #{format(REPLACES_DEFAULTS, "default_plugins", "default_plugins")} Omit the parameter to take the root's default_plugins unchanged; pass [] for no plugins. Example: ["my-plugin"]

On a connection restricted to specific agent roots this parameter is rejected outright, [] included — because a plugin bundles MCP servers, and those are locked to the root's defaults. Omit it.
      TEXT

      HOOKS_DESC = <<~TEXT.strip
        The session's catalog hook IDs. Hooks are shell commands the agent runtime fires on lifecycle events, so a hook that is noise for the task is worth dropping. A non-empty list #{format(REPLACES_DEFAULTS, "default_hooks", "default_hooks")} Omit the parameter to take the root's default_hooks unchanged; pass [] to select none.

        Selecting no hooks is not the same as running with none: a plugin can bundle hooks of its own, and those are added on top of this list — to drop a hook a selected plugin bundles, narrow `plugins` too. Example: ["git-push-ci-reminder"]
      TEXT

      CONFIG_DESC = <<~TEXT.strip
        Additional configuration as a JSON object. Use `config.model` to choose the agent model for this session (e.g. {"model": "gpt-5.6-terra"} for a codex runtime, {"model": "fable"} for claude_code, or {"model": "#{ModelCatalog.default_for("pi")}"} for pi). The model must be valid for the resolved agent_runtime; call get_configs to see each agent root's default_model. When omitted, the session uses the agent root's default_model, then the global session default configured on the Settings page, then the runtime's catalog default; a model that is not valid for the resolved runtime is replaced by that fallback. An explicit config.model always takes precedence.
      TEXT

      CUSTOM_METADATA_DESC = <<~TEXT.strip
        User-defined metadata as a JSON object. Useful for tracking tickets, projects, etc.

        One key Zimmer itself reads: **`replaces_session`** — the id of a session this one is being created to REPLACE, with a free-text `replaces_reason` beside it. Set both whenever you spawn a session to redo work another session could not do (it failed before its first turn, its clone was broken, it was mis-scoped). Zimmer stamps the replaced session with a back-reference so a human reading it can see where the work went, and its automated recovery sweeps then decline to resume that session — without which the sweep resumes it hours later and it re-does the work you handed over (zimmer#801). It has no effect on any session a human resumes by hand.
      TEXT

      PARENT_SESSION_ID_DESC = <<~TEXT.strip
        ID of the session spawning this one. Records the spawn edge that the dependency graph uses and that the session hierarchy is built from: the new session sees the human messages recorded anywhere in its hierarchy, each marked with the session it was authored in, so a human's original intent reaches the session doing the work. Set this whenever you start a session on behalf of work you were asked to do — a router composing a spawn prompt is a machine author, so without the edge the new session has no record of the human who set the work in motion.
      TEXT

      SCHEDULING_CLASS_DESC = <<~TEXT.strip
        Spot/priority class for THIS session, overriding whatever its origin would give it. `priority` starts whenever it is ready; `spot` starts only while a Claude Code account is under both quota targets and a session slot is free, and otherwise waits and starts later (it is deferred, never cancelled). Omit this and the session inherits its parent's explicit class if there is one, and otherwise derives from its genesis — which for a spawn under a `slack` parent means priority. Pass "spot" when you are spawning long, unattended, low-urgency work (a big batch, a sweep, a backfill) that nobody is waiting on, so it does not compete with work a human is watching. Read the current policy with `get_spot_policy`.
      TEXT

      # The three arguments that choose a repository and a tree within it. A
      # restricted connection may name none of them; see enforce_no_repository_override!.
      REPOSITORY_ARGS = %w[git_root branch subdirectory].freeze

      PRECEDENCE_DESC = PrecedenceDocs::START_SESSION

      PLACE_DESC = PrecedenceDocs::PLACE

      IDEMPOTENCY_KEY_DESC = <<~TEXT.strip
        Names THIS create attempt so it is safe to retry. **Generate a fresh UUID** and pass it. If the call errors — including a gateway timeout, where the session may well have been created before the response was lost — call start_session again with the SAME key: Zimmer returns the session the first call made instead of creating a second one, and never queues a second agent. Without a key there is no way to tell a create that never landed from one whose response was lost, and retrying spawns a duplicate. Max #{Session::IDEMPOTENCY_KEY_MAX_LENGTH} characters. Do NOT derive the key from the task, an issue number, or a date: keys share one global namespace, so two callers that independently derive "issue-577-fix" would collide and the second one's session would silently never be created — a duplicate is at least visible, a missing session is not. The key is not a fingerprint of the arguments either: reusing one returns the first session whatever you pass, so use a fresh UUID for each new unit of work.
      TEXT

      AUTO_COMPACT_WINDOW_DESC = <<~TEXT.strip
        Optional per-session auto-compact (context) window override, in tokens. **You should generally rely on the default of 200,000** — omit this parameter and the API default applies. Only override in the rare situation where the spawned session is suffering from compaction thrashing because it doesn't have enough space to work — in that case, retry with `1000000` (1 million tokens). Compaction thrashing is currently the only known reason to set this preemptively.
      TEXT

      description <<~DESC
        Start a new agent session in the Zimmer.

        **IMPORTANT:** Before starting a session, call get_configs to discover available agent roots, MCP servers, goals, and their defaults.

        **Returns:** The created session with its ID, status, and configuration.

        **Behavior:**
        - If a prompt is provided, the agent job is automatically queued to start
        - If no prompt is provided, creates a clone-only session that can be started later with action_session

        **Naming the target repository — `agent_root` OR `git_root`, and one of them is required.** Prefer `agent_root`: naming a preconfigured agent root resolves git_root, branch, subdirectory and default_model from its catalog entry, and carries that root's default MCP servers, skills, hooks and plugins. For a repository no root covers — a fork, a scratch repo, someone's one-off project — pass `git_root` (a clone URL or local path), optionally with `branch` and `subdirectory`. A `git_root` spawn inherits no catalog defaults at all, so it starts with no MCP servers, skills, hooks or plugins beyond what you name, and its runtime and model come from the global defaults on the Settings page unless you pass them. Pass both and the `git_root` wins over the root's URL while the root's other defaults still apply, which is how you run a root's tooling against a fork. A call that names neither is refused — it cannot be turned into a session.

        On a connection restricted to specific agent roots, `git_root`, `branch` and `subdirectory` are rejected outright: that restriction is a fence around which repositories the connection may spawn into, and its repository coordinates come from the allowed root's catalog entry exactly.

        **Defaults from Agent Roots — a list you pass REPLACES the root's defaults, it is never merged with them.** The agent root defines `default_mcp_servers`, `default_skills`, `default_hooks`, `default_plugins`, and optionally a `default_goal`. For each of `mcp_servers`, `skills`, `plugins`, and `hooks` there are **three** distinct requests, not two:

        - **Omit the parameter** → the session takes that root default in full. This is the safe default; prefer it unless you have a specific reason to narrow.
        - **Pass `[]`** → the session gets NONE of that artifact. Omitted and `[]` are two different requests.
        - **Pass a non-empty list** → the session gets EXACTLY that list. Every root default you did not name is dropped, silently.

        So a list you pass has to be the **complete final set**. Call get_configs, copy the root's `default_*` list, and subtract from it — never compose a fresh list from what the task seems to need, because a default you simply didn't think of goes missing.

        - **MCP servers:** This is where a dropped default bites hardest, because a root's skill can depend on a root's server and the skill still loads without it. Narrow for least privilege by passing `default_mcp_servers` minus what the task must not have, or `[]` when it needs none. When this connection is restricted to specific agent roots you cannot add or remove servers at all: the list you pass must match the root's defaults exactly, and `[]` is rejected unless the root has no defaults.
        - **Plugins:** A plugin bundles MCP servers of its own, added on top of `mcp_servers`, so on a connection restricted to specific agent roots this parameter is rejected outright — `[]` included. Omit it and the session takes the root's `default_plugins`.
        - **Skills:** Add beyond `default_skills` freely. Removing a default skill should be rare and intentional — only when you have a specific reason, like replacing a skill with a more capable variant that covers the same ground. Skills are lightweight text files with no blast radius, so keeping all defaults costs nothing.
        - **Hooks:** Drop one from `default_hooks` when it fires on work this session won't do (a CI-reminder hook on a docs-only task, say) by passing the narrowed list, or `[]` to select none. Selecting no hooks is not the same as running with none: a plugin bundles hooks of its own, and those are added on top of the list you pass, so dropping a hook a selected plugin bundles means narrowing `plugins` as well.

        **Runtime and model selection:** Pass `agent_runtime` to override which agent runtime the session uses — `claude_code` (Claude Code), `codex` (OpenAI Codex CLI) or `pi` (Pi coding agent). Pass `config: { model: "..." }` to choose the model (e.g. `opus`/`sonnet`/`haiku`/`fable` for claude_code, `gpt-5.6-sol`/`gpt-5.6-terra`/`gpt-5.6-luna` for codex, `#{ModelCatalog.default_for("pi")}` for pi). Both are optional: when omitted, resolution falls through the agent root's `default_runtime`/`default_model`, then the global session defaults set on the Settings page, then the hardcoded defaults. Call get_configs to discover each root's defaults and pick a model that is valid for the chosen runtime.

        **Scheduling class:** Pass `scheduling_class: "spot"` for long, unattended work nobody is waiting on, so it yields to work a human is watching when the Claude Code quota gets tight. Omit it and the session takes its parent's explicit class, or its genesis's default.

        **Precedence:** Spot sessions start in precedence order, highest first, on an absolute scale (100000 comes before 50). Omit `precedence` in the ordinary case: a session you spawn is placed one point above the session in `parent_session_id`, which keeps a tree of work together. Set it when this work genuinely outranks — or is genuinely less urgent than — the rest of the spot queue. To spawn straight into the HEAD of the spot queue, pass `place: "top_of_spot"` rather than a number — the server resolves it against the live queue in this same call, which reading the current top and passing a value above it cannot do without a race.

        **Retries and timeouts — pass `idempotency_key`:** this create is safe to retry only if you name the attempt. Pass an `idempotency_key` unique to the unit of work; repeating the call with the same key returns the session the first call created and queues no second agent. This matters because the call can fail *after* the session is created: a gateway timeout is returned by the proxy in front of Zimmer, so it carries no session id and cannot tell you whether the write landed — and in every observed case it had. So:

        - **With an `idempotency_key`:** on any error, including a timeout, retry with the same key. You get the existing session back, or a new one if the first call really did not land. That is the guarantee; you do not need to go looking. The replayed result reports whether an agent job is queued on that session — if it says none is, the session exists but never started, and `action_session` with `restart` starts it.
        - **Without one:** do NOT retry — a retry duplicates the session, the clone, and the agent's quota slot. Call `quick_search_sessions` with the title you passed and check whether the session already exists.

        **Use cases:**
        - Start a new agent task on a repository
        - Create a session to work on a specific branch
        - Set up an agent with specific MCP servers and skills enabled
        - Create a session with custom metadata for tracking
      DESC

      input_schema({
        type: "object",
        properties: {
          agent_runtime: { type: "string", description: AGENT_RUNTIME_DESC },
          prompt: { type: "string", description: PROMPT_DESC },
          agent_root: { type: "string", description: AGENT_ROOT_DESC },
          git_root: { type: "string", description: GIT_ROOT_DESC },
          branch: { type: "string", description: BRANCH_DESC },
          subdirectory: { type: "string", description: SUBDIRECTORY_DESC },
          title: { type: "string", description: TITLE_DESC },
          slug: { type: "string", description: SLUG_DESC },
          goal: { type: "string", description: GOAL_DESC },
          mcp_servers: { type: "array", items: { type: "string" }, description: MCP_SERVERS_DESC },
          skills: { type: "array", items: { type: "string" }, description: SKILLS_DESC },
          plugins: { type: "array", items: { type: "string" }, description: PLUGINS_DESC },
          hooks: { type: "array", items: { type: "string" }, description: HOOKS_DESC },
          config: { type: "object", description: CONFIG_DESC },
          custom_metadata: { type: "object", description: CUSTOM_METADATA_DESC },
          parent_session_id: { type: "integer", description: PARENT_SESSION_ID_DESC },
          scheduling_class: {
            type: "string",
            enum: SessionGenesis::CLASSES,
            description: SCHEDULING_CLASS_DESC
          },
          precedence: { type: "integer", description: PRECEDENCE_DESC },
          place: { type: "string", enum: SessionPrecedence::PLACES, description: PLACE_DESC },
          idempotency_key: { type: "string", description: IDEMPOTENCY_KEY_DESC },
          auto_compact_window: { type: "integer", description: AUTO_COMPACT_WINDOW_DESC }
        },
        required: []
      })

      def call(args)
        agent_root_name = args["agent_root"].presence
        enforce_root_constraints!(agent_root_name, args)

        # Answered before any of the create work — the retry this exists for is a
        # caller that already got its session and does not know it, so the cheap
        # lookup is the whole response. Placed after the restriction check so a
        # restricted connection still has to name one of its allowed roots to get
        # here. It is not a read-scope: the returned session may belong to any
        # root, exactly as `get_session` in this same tool group already reads any
        # session by id.
        idempotency_key = args["idempotency_key"].presence
        replayed = Sessions::IdempotentCreate.existing(idempotency_key)
        return format_session(replayed, reused: true) if replayed

        # Below the replay, unlike the restriction check above it: this one is a
        # contract check rather than a fence, and a caller retrying a lost response
        # with the same key gets its session back whatever it passes — the promise
        # IDEMPOTENCY_KEY_DESC makes, and what the REST endpoint does.
        require_spawn_target!(agent_root_name, args)

        session = Session.new(session_attributes(args))
        # A router spawning downstream work passes parent_session_id, and that
        # session belongs to the same line of work as its parent — assign_genesis
        # inherits it. Only a parentless spawn, which nothing connects to a human,
        # is classified `api`.
        session.genesis = SessionGenesis::API if session.parent_session_id.blank?
        # Recorded before save so the job starting moments later can tell a
        # deliberate "no MCP servers" from a column that landed empty by accident
        # and would otherwise be healed back to the root's defaults.
        session.record_explicit_mcp_servers(session.mcp_servers) if explicit_list?(args, "mcp_servers")
        resolve_spawn_defaults!(session, agent_root_name, args)

        # The lookup above answers the sequential retry; this answers the
        # concurrent one, where the first call is still inside its INSERT when
        # the second arrives. Either way a reused result means the agent job was
        # already queued by the call that won, so nothing more happens here —
        # queueing a second one is the duplicate this whole path exists to avoid.
        result = Sessions::IdempotentCreate.save(session, idempotency_key)
        raise ActiveRecord::RecordInvalid, session unless result
        return format_session(result.session, reused: true) if result.reused?

        if session.prompt.present?
          job = AgentSessionJob.enqueue_new_session(session.id)
          session.update(job_id: job.job_id)
        end

        # Say, in the result, that one of this session's servers cannot start.
        # A warning rather than a refusal: readiness is Zimmer's local view of a
        # moment, and ConnectorStatusProbe deliberately reports "could not find
        # out" as usable — making it authoritative here would let a Parameter
        # Store blip block spawning. It matters most on a restricted connection,
        # which is required to pass its root's defaults exactly and so has no
        # legal way to drop an unavailable one; refusing there would make the
        # root unspawnable, while a warning still names the server and the fix.
        format_session(session, warning: McpServerReadiness.warn_for_session(session))
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, "Invalid agent_root: #{e.message}"
      end

      private

      # A restricted connection must name an allowed root, take that root's
      # repository coordinates as the catalog declares them, AND take that root's
      # MCP servers exactly — no additions, no removals. Both the direct route to
      # a server (`mcp_servers`) and the indirect one (`plugins`) are held to it.
      def enforce_root_constraints!(agent_root_name, args)
        return unless context.restricted?

        # Before enforce_allowed_root!, so a restricted connection that passed a
        # raw git_root is told that git_root is the problem rather than being sent
        # off to add an agent_root that would not have helped.
        enforce_no_repository_override!(args)
        enforce_allowed_root!(agent_root_name)

        root = AgentRootsConfig.find(agent_root_name)
        unless root
          raise ToolError, "Agent root \"#{agent_root_name}\" is in the allowed list but was not found in the configuration. " \
                           "Available agent roots: #{AgentRootsConfig.names.join(', ')}"
        end

        enforce_default_mcp_servers!(root, args)
        enforce_default_plugins!(root, args)
      end

      # What `allowed_agent_roots` fences is which repositories — with which MCP
      # servers — a connection may spawn into. Until `git_root` existed here,
      # naming an allowed root settled that on its own, because a root was the only
      # way to name a repository at all. `git_root` is a second way to name one, and
      # `branch`/`subdirectory` move an allowed root's checkout to a tree its catalog
      # entry does not point at, so on a restricted connection all three are refused
      # outright — with or without an agent_root beside them. A restricted spawn's
      # repository coordinates come from the allowed root's catalog entry, exactly,
      # which is the answer this tool already gives for that root's MCP servers and
      # plugins. A root that should spawn against a different repository or branch is
      # a root to configure that way, not a per-call override.
      def enforce_no_repository_override!(args)
        named = REPOSITORY_ARGS.select { |key| args[key].present? }
        return if named.empty?

        raise ToolError, "#{named.map { |key| "\"#{key}\"" }.to_sentence} #{named.one? ? 'is' : 'are'} not allowed when this " \
                         "connection is restricted to specific agent roots: the restriction is a fence around which " \
                         "repositories this connection may spawn into, and a restricted session takes its repository, " \
                         "branch and subdirectory from its agent root's catalog entry. Omit #{named.one? ? 'it' : 'them'} " \
                         "and pass an allowed agent_root instead. Allowed agent roots: #{context.allowed_agent_roots.join(', ')}."
      end

      # The tool has two ways to name a target repository and needs one of them.
      # Without this check a call that named neither fell through to Session's
      # unconditional git_root presence validation and came back as a bare
      # RecordInvalid naming a field the schema did not even have (#265).
      def require_spawn_target!(agent_root_name, args)
        return if agent_root_name.present? || args["git_root"].present?

        raise ToolError, "Name a target repository: pass `agent_root` (a catalog root from get_configs, which brings " \
                         "its repository and its default MCP servers, skills, hooks and plugins with it) or `git_root` " \
                         "(a repository URL or local path to spawn against directly, with no catalog defaults). " \
                         "Available agent roots: #{AgentRootsConfig.names.join(', ')}."
      end

      # An omitted mcp_servers means "take the root's defaults" (that is what
      # Sessions::ResolveSpawnDefaults does), so it is only a deviation to check when
      # the caller actually named a list. This gate stays `key?` rather than the
      # `is_a?(Array)` used elsewhere: a restricted connection that sends an
      # explicit null already fails here, and loosening that would widen what a
      # restricted connection may spawn.
      def enforce_default_mcp_servers!(root, args)
        return unless args.key?("mcp_servers")

        requested = string_array(args["mcp_servers"])
        defaults = root.default_mcp_servers || []
        return if defaults.sort == requested.sort

        raise ToolError, "Agent root \"#{root.name}\" must use its exact default MCP servers. " \
                         "Expected: [#{format_list(defaults)}], but got: [#{format_list(requested)}]. " \
                         "You cannot add or remove MCP servers when this connection is restricted to specific agent roots."
      end

      # Plugins can bundle MCP servers (see Session#derive_mcp_servers_from_plugins),
      # so on a restricted connection naming them at launch is a bypass of the
      # same agent-root MCP lock enforce_default_mcp_servers! applies: the
      # connection refused `mcp_servers: [..., "playwright-custom"]` gets that
      # server anyway through `plugins: ["screenshots-videos"]`. Skills and hooks
      # carry no such server expansion, so only plugins inherit the guard — the
      # reasoning action_session already encodes for change_plugins and
      # action_trigger for catalog_plugins.
      #
      # The gate is `key?`, so an explicit `[]` is refused too even though it
      # adds no servers. That costs a restricted caller the ability to drop a
      # root's default plugins, and is deliberate: a restricted connection takes
      # its root's servers exactly as configured, in either direction, which is
      # already how mcp_servers reads here and is the same answer the two
      # change-time surfaces give. A root that should spawn without its plugins
      # is a root to configure that way, not a per-call narrowing.
      def enforce_default_plugins!(root, args)
        return unless args.key?("plugins")

        raise ToolError, "The \"plugins\" parameter is not allowed when this connection is restricted to " \
                         "specific agent roots. Plugins can add MCP servers, which are locked to the defaults " \
                         "configured for each allowed agent root. Omit it and the session takes agent root " \
                         "\"#{root.name}\"'s default plugins: [#{format_list(root.default_plugins || [])}]."
      end

      def session_attributes(args)
        attrs = {}
        attrs[:agent_runtime] = args["agent_runtime"] if args["agent_runtime"].present?
        attrs[:git_root] = args["git_root"] if args["git_root"].present?
        attrs[:branch] = args["branch"] if args["branch"].present?
        attrs[:subdirectory] = args["subdirectory"] if args["subdirectory"].present?
        attrs[:prompt] = args["prompt"] if args["prompt"].present?
        attrs[:title] = args["title"] if args["title"].present?
        attrs[:slug] = args["slug"] if args["slug"].present?
        attrs[:auto_compact_window] = args["auto_compact_window"] unless args["auto_compact_window"].nil?
        attrs[:goal] = resolved_goal(args["goal"]) if args["goal"].present?
        # Gate on "the caller named a list", not on "the list has entries" — the
        # same test change_mcp_servers applies (action_session.rb). `[].present?`
        # is false, so a presence gate drops an explicit empty array before it
        # ever reaches the session, and the caller silently gets the root's
        # defaults instead of the none it asked for.
        attrs[:mcp_servers] = string_array(args["mcp_servers"]) if explicit_list?(args, "mcp_servers")
        attrs[:catalog_skills] = string_array(args["skills"]) if explicit_list?(args, "skills")
        attrs[:catalog_plugins] = string_array(args["plugins"]) if explicit_list?(args, "plugins")
        attrs[:catalog_hooks] = string_array(args["hooks"]) if explicit_list?(args, "hooks")
        attrs[:config] = args["config"] if args["config"].is_a?(Hash)
        attrs[:custom_metadata] = args["custom_metadata"] if args["custom_metadata"].is_a?(Hash)
        attrs[:parent_session_id] = args["parent_session_id"] unless args["parent_session_id"].nil?
        attrs[:scheduling_class] = scheduling_class(args) if args["scheduling_class"].present?
        attrs[:precedence] = resolved_precedence(args) if precedence_given?(args)
        attrs[:idempotency_key] = args["idempotency_key"] if args["idempotency_key"].present?
        attrs
      end

      # An explicit class beats the genesis-derived default and beats a parent's,
      # which is the whole point of the argument: a router working under a `slack`
      # parent can still spawn one long batch as spot without demoting every other
      # session that shares that genesis.
      def scheduling_class(args)
        value = args["scheduling_class"].to_s
        unless SessionGenesis::CLASSES.include?(value)
          raise ToolError, "Unknown scheduling_class: #{value}. Valid: #{SessionGenesis::CLASSES.join(', ')}"
        end

        value
      end

      # Goals are passed to the agent as prose, so a goal ID is swapped for its
      # description; a free-text sentence is passed through verbatim. A single
      # word the catalog does not know is a mistyped id, and is refused rather
      # than handed to the agent as the goal.
      def resolved_goal(goal)
        raise ToolError, GoalsConfig.unknown_id_message(goal) if GoalsConfig.unknown_id?(goal)

        GoalsConfig.find(goal.to_s.strip)&.description || goal
      end

      # The runtime, the model, and — when a root was named — the repository fields
      # and catalog defaults, resolved through the chain this tool shares with
      # every other spawn surface (POST /api/v1/sessions, the new-session form,
      # Session.create_from_agent_root!):
      #
      #   tool argument  →  agent root's declared value  →  AppSetting (the global
      #   base default set on the Settings page)  →  the hardcoded default
      #
      # A rootless spawn has no root tier, so it falls straight through to the
      # Settings-page defaults rather than to the column default — the same
      # resolution the REST endpoint gives a bare `git_root`. It always leaves an
      # explicit model in config, so the spawn never depends on a runtime-side one.
      #
      # @param args [Hash] the raw tool arguments, needed to tell an omitted
      #   artifact list (take the root's defaults) from an explicit `[]` (take none).
      def resolve_spawn_defaults!(session, agent_root_name, args)
        Sessions::ResolveSpawnDefaults.call(
          session,
          agent_root_name: agent_root_name,
          explicit_runtime: args["agent_runtime"].present?,
          explicit_branch: args["branch"].present?,
          explicit_lists: {
            mcp_servers: explicit_list?(args, "mcp_servers"),
            skills: explicit_list?(args, "skills"),
            hooks: explicit_list?(args, "hooks"),
            plugins: explicit_list?(args, "plugins")
          }
        )
      end

      # @param reused [Boolean] true when this call created nothing and is handing
      #   back the session an earlier call with the same idempotency_key made. Said
      #   in the heading rather than a footnote: a caller retrying a timeout is
      #   deciding whether it now has one session or two, and that is the answer.
      # @param warning [String, nil] an MCP-server readiness warning to append
      #   (McpServerReadiness). Never returned for a replay: the caller is being
      #   handed a session it already made, and nothing about it changed here.
      def format_session(session, reused: false, warning: nil)
        lines = [
          reused ? "## Existing Session Returned (idempotency_key matched)" : "## Session Started Successfully",
          "",
          "- **ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Status:** #{session.status}"
        ]
        lines << "- **Slug:** #{session.slug}" if session.slug.present?

        if reused
          lines << "- **Job ID:** #{session.job_id}" if session.job_id.present?
          lines << ""
          lines << "*A session with this `idempotency_key` already existed, so no new session was created " \
                   "and no second agent job was queued. This is the session your earlier call made.*"
          # Reported rather than assumed. The winning call queues the agent job a
          # moment after the row commits, so a worker killed in between leaves a
          # session that is real, has a prompt, and will never start on its own.
          # A replay that stayed silent would hand that session back as if it were
          # running — the same unobservable failure one layer along.
          if session.prompt.present? && session.job_id.blank?
            lines << ""
            lines << "**No agent job is queued on this session.** It was created but never started — " \
                     'use action_session with the "restart" action to start it.'
          end
          return lines.join("\n")
        end

        if session.job_id.present?
          lines << "- **Job ID:** #{session.job_id}"
          lines << ""
          lines << "*The agent job has been queued and will start shortly.*"
        else
          lines << ""
          lines << '*No prompt was provided. Use action_session with "follow_up" or "restart" action to start the agent.*'
        end

        if warning.present?
          lines << ""
          lines << "**⚠️ #{warning}**"
        end

        lines.join("\n")
      end

      def string_array(value)
        Array(value).map(&:to_s)
      end

      # True when the caller actually named this artifact list, empty or not.
      # An array is the only thing that counts as naming one, which is the same
      # test change_mcp_servers uses (action_session.rb) — so launch-time and
      # change-time agree on what an explicit `[]` means.
      def explicit_list?(args, key)
        args[key].is_a?(Array)
      end

      def format_list(list)
        list.empty? ? "(none)" : list.join(", ")
      end
    end
  end
end
