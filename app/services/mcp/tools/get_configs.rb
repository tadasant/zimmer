# frozen_string_literal: true

module Mcp
  module Tools
    # The catalog an agent needs before it can call start_session. Agent roots are
    # filtered to the connection's allowed roots so a restricted connection cannot
    # even see roots it may not spawn.
    #
    # No longer a mirror of GET /api/v1/configs, which still returns every catalog
    # server flat. This surface omits the ones that cannot be attached, because a
    # list an agent reads as "your options" must not contain a trap; the REST
    # endpoint serves clients that asked for the catalog, not for a choice.
    class GetConfigs < Tool
      tool_name "get_configs"

      SECTIONS = %w[mcp_servers agent_roots models goals].freeze
      NAMES_MAX = 50
      QUERY_MAX_LENGTH = 200

      description <<~DESC
        Lists the configuration `start_session` takes: MCP servers, agent roots, runtime models, and goals.

        **Just want something done or answered? Call `quick_router` instead.** It takes a plain-language
        request and Zimmer picks the root, servers and goal itself. This tool is for hand-composing
        `start_session`.

        **The full listing is large** (every agent root with its defaults, every catalog server), so
        narrow it when you can. Every argument is optional, and with none you get everything:
        - `sections`: any of `mcp_servers`, `agent_roots`, `models`, `goals`. Only these are returned.
        - `query`: words matched case-insensitively against each server's, root's and goal's name,
          title and description; an item must contain every word. "whatsapp" answers "is there a
          WhatsApp server?" in one small call. Runtime models are not filtered by it.
        - `names`: server names, agent root names, or goal ids (whole names, case-insensitive). Use it to fetch full detail for
          the few candidates a compact or query call turned up.
        - `compact`: one line per item (name and title) instead of descriptions and defaults, and no
          usage notes. Good for a first look at what exists.

        A filtered listing says it is filtered and still states the true totals.

        Returns:
        - **MCP servers**: Servers that can be attached right now (name, title, description), plus a
          short roster of catalog servers that currently cannot start and why
        - **Agent roots**: Preconfigured repository settings with defaults (git_root, branch, mcp_servers, skills, goal)
        - **Runtime models**: Selectable models grouped by agent runtime, including default, auth requirements, and the reasoning-effort levels (and default level) each model takes
        - **Goals**: Available session completion criteria (id, name, description)

        Read the full (non-compact) entry for an agent root before calling start_session with it.
      DESC

      input_schema({
        type: "object",
        properties: {
          sections: {
            type: "array",
            items: { type: "string", enum: SECTIONS },
            description: "Return only these sections. Omit for all four."
          },
          query: {
            type: "string",
            description: "Case-insensitive words to match against name, title and description of servers, " \
                         "agent roots and goals. Every word must appear. Runtime models are not filtered."
          },
          names: {
            type: "array",
            items: { type: "string" },
            description: "Server names, agent root names or goal ids (whole names, case-insensitive) to return in full. " \
                         "Items in a returned section that are not named are left out."
          },
          compact: {
            type: "boolean",
            description: "One line per item (name and title), no descriptions, defaults or usage notes."
          }
        },
        required: []
      })

      def call(args)
        @filter = Filter.parse(args)
        lines = catalog_health_lines
        lines.concat(@filter.banner_lines)

        rendered = []
        rendered << mcp_server_section_lines if @filter.section?("mcp_servers")
        rendered << agent_root_section_lines if @filter.section?("agent_roots")
        rendered << model_section_lines if @filter.section?("models")
        rendered << goal_section_lines if @filter.section?("goals")
        rendered.each_with_index do |section, index|
          lines << "---" << "" if index.positive?
          lines.concat(section)
        end

        lines.concat(usage_note_lines) unless @filter.compact?

        lines.join("\n")
      end

      # What a call asked for, and how each list item is tested against it. With
      # no arguments every predicate is true and #active? is false, which is what
      # keeps the unfiltered listing exactly as it was.
      class Filter
        attr_reader :sections, :terms, :names

        def self.parse(args)
          sections = args["sections"]
          unless sections.nil?
            raise ToolError, "The \"sections\" parameter must be an array." unless sections.is_a?(Array)

            sections = sections.map { |s| s.to_s.strip }.reject(&:empty?).uniq
            unknown = sections - SECTIONS
            raise ToolError, "Unknown section(s): #{unknown.join(', ')}. Valid sections: #{SECTIONS.join(', ')}" if unknown.any?
          end

          query = args["query"]
          raise ToolError, "The \"query\" parameter must be a string." unless query.nil? || query.is_a?(String)

          query = query.to_s.strip
          raise ToolError, "query is too long (maximum #{QUERY_MAX_LENGTH} characters)" if query.length > QUERY_MAX_LENGTH

          names = args["names"]
          unless names.nil?
            raise ToolError, "The \"names\" parameter must be an array." unless names.is_a?(Array)

            names = names.map { |n| n.to_s.strip }.reject(&:empty?).uniq
            raise ToolError, "Too many names (maximum #{NAMES_MAX})" if names.size > NAMES_MAX
          end

          compact = args["compact"]
          raise ToolError, "The \"compact\" parameter must be a boolean." unless [ nil, true, false ].include?(compact)

          new(sections: sections.presence, query: query, names: names.presence, compact: compact == true)
        end

        def initialize(sections:, query:, names:, compact:)
          @sections = sections
          @query = query
          @terms = query.downcase.split
          @names = names
          @name_keys = names&.map(&:downcase)
          @compact = compact
        end

        def section?(section)
          @sections.nil? || @sections.include?(section)
        end

        def compact?
          @compact
        end

        # Whether anything narrows the items within a section.
        def narrowing?
          @terms.any? || !@names.nil?
        end

        def active?
          narrowing? || !@sections.nil? || @compact
        end

        # @param name [String] the item's identifier — what `names` matches exactly
        # @param texts [Array<String, nil>] everything `query` searches, the name included
        def match?(name, *texts)
          return false if @name_keys && !@name_keys.include?(name.to_s.downcase)
          return true if @terms.empty?

          haystack = [ name, *texts ].compact.join("\n").downcase
          @terms.all? { |term| haystack.include?(term) }
        end

        def banner_lines
          return [] unless active?

          parts = []
          parts << "sections: #{@sections.join(', ')}" if @sections
          parts << "query: \"#{@query}\"" if @terms.any?
          parts << "names: #{@names.join(', ')}" if @names
          parts << "compact" if @compact
          [ "*Filtered listing (#{parts.join('; ')}). Counts below are the true totals; call `get_configs` " \
            "with no arguments for everything.*", "" ]
        end
      end

      private

      def mcp_server_section_lines
        lines = [ "## MCP Servers", "" ]
        available, unavailable = partitioned_servers
        if available.empty? && unavailable.empty?
          return lines << "*No MCP servers available.*" << ""
        end

        shown_available = available.select { |status| server_match?(status) }
        shown_unavailable = unavailable.select { |status| server_match?(status) }

        if @filter.narrowing?
          lines.concat(filtered_server_header_lines(shown_available, available, unavailable))
          lines.concat(server_entry_lines(shown_available))
        else
          lines.concat(available_server_lines(available, unavailable.size))
        end
        lines.concat(unavailable_server_lines(shown_unavailable, of: unavailable.size))
      end

      def server_match?(status)
        @filter.match?(status.server_name, status.title, status.server.description)
      end

      # A narrowed listing still says how big the whole catalog is, so "no match"
      # cannot be read as "no servers".
      def filtered_server_header_lines(shown, available, unavailable)
        total = available.size + unavailable.size
        if shown.empty?
          unusable = unavailable.count { |status| server_match?(status) }
          note = unusable.positive? ? "; #{unusable} unavailable #{unusable == 1 ? 'match is' : 'matches are'} listed below" : ""
          [ "*No usable server matches the filter (#{available.size} usable of #{total} in the catalog#{note}).*", "" ]
        else
          [ "Showing #{shown.size} of #{available.size} usable server#{'s' unless available.size == 1} " \
            "(#{total} in the catalog), filtered:", "" ]
        end
      end

      def agent_root_section_lines
        roots = allowed_roots
        lines = [ "## Agent Roots", "" ]
        return lines << "*No agent roots configured.*" if roots.empty?

        noun = roots.size == 1 ? "repository" : "repositories"
        shown = roots.select do |root|
          @filter.match?(root.name, root.display_name, root.description, root.url)
        end
        if !@filter.narrowing?
          lines << "Found #{roots.size} preconfigured #{noun}:" << ""
        elsif shown.empty?
          return lines << "*No agent root matches the filter (#{roots.size} preconfigured #{noun}).*" << ""
        else
          lines << "Showing #{shown.size} of #{roots.size} preconfigured #{noun}, filtered:" << ""
        end

        if @filter.compact?
          shown.each { |root| lines << "- `#{root.name}` — #{root.display_name.presence || root.name}" }
          lines << ""
        else
          shown.each { |root| lines.concat(format_root(root)) }
        end
        lines
      end

      def model_section_lines
        lines = [ "## Runtime Models", "" ]
        ModelCatalog.runtimes.each do |runtime|
          if @filter.compact?
            lines << "- `#{runtime}` (#{RuntimeRegistry.label_for(runtime)}): default " \
                     "`#{ModelCatalog.default_for(runtime)}`; models #{format_models(runtime)}"
            next
          end

          lines << "### #{RuntimeRegistry.label_for(runtime)}"
          lines << "- **Runtime:** `#{runtime}`"
          lines << "- **Default Model:** `#{ModelCatalog.default_for(runtime)}`"
          lines << "- **Models:** #{format_models(runtime)}"
          lines.concat(effort_lines(runtime))
          lines << ""
        end
        lines << "" if @filter.compact?
        lines
      end

      def goal_section_lines
        goals = GoalsConfig.all
        lines = [ "## Goals", "" ]
        return lines << "*No goals defined.*" if goals.empty?

        shown = goals.select do |goal|
          data = goal.to_h.with_indifferent_access
          @filter.match?(data[:id], data[:name], data[:description])
        end
        if !@filter.narrowing?
          lines << "Found #{goals.size} goal#{'s' unless goals.size == 1}:" << ""
        elsif shown.empty?
          return lines << "*No goal matches the filter (#{goals.size} defined).*" << ""
        else
          lines << "Showing #{shown.size} of #{goals.size} goal#{'s' unless goals.size == 1}, filtered:" << ""
        end

        shown.each do |goal|
          data = goal.to_h.with_indifferent_access
          if @filter.compact?
            lines << "- `#{data[:id]}` — #{data[:name]}"
            next
          end

          lines << "### #{data[:name]}"
          lines << "- **ID:** `#{data[:id]}`"
          lines << "- **Description:** #{data[:description]}"
          # What GoalCheck reads back for this goal — the same list GET /configs carries.
          lines << "- **Checks:** #{data[:checks].map { |check| "`#{check}`" }.join(', ')}" if data[:checks].present?
          lines << ""
        end
        lines << "" if @filter.compact?
        lines
      end

      def usage_note_lines
        lines = [ "---", "", "### Usage Notes", "" ]
        # The trap the per-root `Default …` lines above cannot show on their own:
        # they read as "what this root comes with", which is true only until the
        # caller names a list of its own. https://github.com/tadasant/zimmer/pull/310
        # keeps explicit-replaces-defaults deliberately, so the warning has to
        # arrive here — before the agent composes the list, not after it has
        # spawned a session missing a server one of its skills needed.
        lines << "- **A list you pass to `start_session` is the final set — it REPLACES the root's " \
                 "defaults, it is not added to them.** Omit `mcp_servers`/`skills`/`hooks`/`plugins` " \
                 "and the session takes that root default in full; pass a list and it gets exactly " \
                 "that list, with every default you did not name dropped silently. Copy the root's " \
                 "`Default …` line above and subtract from it — never write a fresh list from what " \
                 "the task seems to need. A dropped MCP server is the one that bites: a root's " \
                 "default skill can depend on a root's default server, and the skill still loads " \
                 "without it, so the session fails mid-task at the point of use"
        lines << "- Use `name` values from **MCP Servers** in `start_session` `mcp_servers` parameter"
        lines << "- Servers under **Unavailable** are in the catalog but cannot start — they are not " \
                 "missing, and registering a replacement for one is wrong. Leave them out of " \
                 "`mcp_servers`; a root default marked `(unavailable)` is the same trap reached from " \
                 "the other side. (On a connection restricted to specific agent roots the defaults " \
                 "must be passed exactly, so an unavailable default cannot be dropped — expect that " \
                 "spawn to fail, and say which server caused it)"
        lines << "- Use `git_root` from **Agent Roots** to start sessions with preconfigured defaults"
        lines << "- Use **Runtime Models** to choose a `config.model` value that belongs to the selected `agent_runtime`"
        lines << "- Use a model's **Effort levels** to set `config.effort` in `start_session` (e.g. " \
                 "`config: { model: \"fable\", effort: \"xhigh\" }` — \"xhigh\" is extra-high). Omit it and the " \
                 "model's default applies. A model with no effort line takes none, and a level it does not list is refused"
        lines << "- If an **Agent Root** has a `default_subdirectory`, pass it as `subdirectory` in `start_session` — do not set `subdirectory` to arbitrary internal paths"
        lines << "- Skills are the one list where the usual move is to add rather than subtract: start from " \
                 "the root's **Default Skills** and append. They are cheap text files with no blast " \
                 "radius, so dropping a default should be rare and deliberate"
        lines << "- Use `id` values from **Goals** in `start_session` `goal` parameter"
        # Read by the session that is about to CHOOSE a child's scope and tools,
        # which is the only place the answer is still cheap. A child that finds
        # out it was given the wrong root, or is missing a server, can now say so
        # (`action_session` -> `message_parent`) instead of filing an issue — but
        # only a parent that knows to expect that message acts on it.
        lines << "- A session you spawn can report back to you with `action_session` `message_parent` when the " \
                 "scope or the tools you gave it were wrong for the job — reason `wrong_scope` (it belongs to a " \
                 "different agent root) or `missing_tools` (it needs an MCP server, credential or privilege it " \
                 "was not given). That report arrives as your next prompt, or on your queue if you are mid-turn, " \
                 "and you are the only one who receives it: re-delegate to the right root, or re-spawn with the " \
                 "server it named. Getting the lists above right is what avoids it"
        lines
      end

      # Every catalog server, split by whether a session could actually attach
      # it. The split is ConnectorStatusProbe's — the same computation the
      # Connectors page renders one row at a time — so the page and this tool
      # cannot come to different conclusions about the same server.
      #
      # @return [Array(Array<ConnectorStatusProbe::Status>, Array<ConnectorStatusProbe::Status>)]
      def partitioned_servers
        @partitioned_servers ||= ConnectorStatusProbe.all.partition(&:available?)
      end

      def unavailable_server_names
        @unavailable_server_names ||= partitioned_servers.last.map(&:server_name).to_set
      end

      # The options. Only servers that can start are here, because this list is
      # read as "what you may pass to start_session" and an entry that cannot
      # start is not an option — it is a trap.
      def available_server_lines(available, unavailable_count)
        return [ "*Every catalog server is currently unavailable — see below.*", "" ] if available.empty?

        total = available.size + unavailable_count
        header = "Found #{available.size} usable server#{'s' unless available.size == 1}"
        if unavailable_count.positive?
          other = unavailable_count == 1 ? "the other 1 is unavailable" : "the other #{unavailable_count} are unavailable"
          header += " (of #{total} in the catalog; #{other}, listed below)"
        end

        [ "#{header}:", "" ] + server_entry_lines(available)
      end

      def server_entry_lines(statuses)
        lines = []
        if @filter.compact?
          statuses.each { |status| lines << "- `#{status.server_name}` — #{status.title}" }
          return lines.empty? ? lines : lines << ""
        end

        statuses.each do |status|
          lines << "### #{status.title}"
          lines << "- **Name:** `#{status.server_name}`"
          # Only for a server whose short id a second composed catalog also
          # contributes, where the heading above is not unique and `Name` is
          # already the qualified `@scope/id`. Saying which catalog it came from
          # is what lets an agent pick the right one deliberately; on a
          # single-catalog deployment nothing is contested and this never
          # renders. See ArtifactIdentity.
          lines << "- **Catalog:** `#{status.server.scope}`" if status.server.contested?
          lines << "- **Description:** #{status.server.description}"
          lines << ""
        end
        lines
      end

      # The roster, and the reason it exists at all: an agent that simply cannot
      # see a server has no way to tell it apart from one that was never
      # configured, and goes off to register a duplicate. Naming them — without
      # re-describing them — answers "it exists, it is broken, leave it alone".
      def unavailable_server_lines(unavailable, of:)
        return [] if unavailable.empty?

        one = unavailable.one?
        lines = [ "### Unavailable", "" ]
        lines << "Showing #{unavailable.size} of #{of}, filtered." if unavailable.size != of
        lines << "#{unavailable.size} catalog #{one ? 'server' : 'servers'} cannot be attached right " \
                 "now. #{one ? 'It exists' : 'They exist'} — do not register a replacement — but do " \
                 "not pass #{one ? 'it' : 'them'} to `start_session`. Each line says why, and the " \
                 "reasons fail differently: an unresolved `${VAR}` raises at spawn and fails the " \
                 "whole session rather than just that server, while a server awaiting OAuth parks it " \
                 "for a human to authorize at /connectors."
        lines << ""
        unavailable.each do |status|
          lines << "- `#{status.server_name}` — unavailable: #{status.unavailable_reason}"
        end
        lines << ""
        lines
      end

      # Prepended when catalog resolution failed, so an agent can tell a broken
      # catalog from an empty one before it acts on the lists below. Without it,
      # `ServersConfig.all` and `allowed_roots` rescue CatalogError to `[]` and
      # this tool reports "No MCP servers available" — indistinguishable from a
      # fresh install, which is #112's defect on the agent side of the wall.
      #
      # Deliberately narrower than the operator-facing banner on the session
      # form. The banner prints `air resolve`'s stderr with the credentials
      # Zimmer holds scrubbed out of it (AirCatalogService#record_failure) —
      # which lowers the blast radius of that text without making it safe to
      # echo onto an agent channel, since it cannot scrub a credential Zimmer
      # never issued. What an agent needs in order not to act wrongly is the
      # fact and its age, not the text. Same fact, different fidelity,
      # different audience.
      def catalog_health_lines
        failure = AirCatalogService.resolve_failure
        return [] unless failure

        lines = [ "## ⚠️ Catalog resolution is failing", "" ]
        if AirCatalogService.degraded?
          stamp = AirCatalogService.last_known_good_at
          lines << "The lists below come from the last catalog that resolved successfully" \
                   "#{" (#{stamp.utc.iso8601})" if stamp}, not from the current one. Anything added or " \
                   "changed since then is missing here."
        else
          lines << "Resolution failed with no previously cached catalog to fall back on, so the lists " \
                   "below are empty **because of the failure**, not because nothing is configured. Do " \
                   "not read an empty list as an empty catalog, and expect `start_session` to fail " \
                   "until resolution is repaired."
        end
        lines << ""
        lines << "Reported at #{failure[:at].utc.iso8601}. The underlying `air resolve` error is on the " \
                 "session form and in the application logs."
        lines << "" << "---" << ""
      end

      def allowed_roots
        roots = AgentRootsConfig.all
        return roots unless context.restricted?
        roots.select { |root| context.allowed_agent_roots.include?(root.name) }
      end

      def format_root(root)
        data = root.to_h.with_indifferent_access
        lines = [ "### #{data[:display_name].presence || data[:name]}" ]
        lines << "- **Name:** `#{data[:name]}`"
        lines << "- **Catalog:** `#{root.scope}`" if root.contested?
        lines << "- **Git Root:** `#{data[:url]}`"
        lines << "- **Description:** #{data[:description]}"
        lines << "- **Default Branch:** `#{data[:default_branch]}`" if data[:default_branch].present?
        lines << "- **Default Subdirectory:** `#{data[:subdirectory]}`" if data[:subdirectory].present?
        # A root's defaults are copied wholesale into start_session, so an
        # unavailable one is the same trap as an unavailable option — reached by
        # a different route. Marked rather than removed: what the root declares
        # is a fact about the root, and silently editing it would leave an agent
        # unable to tell a default that was dropped from one that was never there.
        if data[:default_mcp_servers].present?
          defaults = data[:default_mcp_servers].map do |name|
            unavailable_server_names.include?(name) ? "`#{name}` (unavailable)" : "`#{name}`"
          end
          lines << "- **Default MCP Servers (omit `mcp_servers` to take all of these):** #{defaults.join(', ')}"
        end
        lines << "- **Default Goal:** `#{data[:default_goal]}`" if data[:default_goal].present?
        if data[:default_skills].present?
          lines << "- **Default Skills:** #{data[:default_skills].map { |s| "`#{s}`" }.join(', ')}"
        end
        # Hooks and plugins are rendered for the same reason the servers and skills
        # are: `start_session` tells a caller narrowing one of these lists to copy
        # the root's defaults from here and subtract, and a default it cannot read
        # is one it writes a list without.
        if data[:default_hooks].present?
          lines << "- **Default Hooks:** #{data[:default_hooks].map { |h| "`#{h}`" }.join(', ')}"
        end
        if data[:default_plugins].present?
          lines << "- **Default Plugins:** #{data[:default_plugins].map { |p| "`#{p}`" }.join(', ')}"
        end
        lines << "- **Default Model:** `#{data[:default_model]}`" if data[:default_model].present?
        lines << ""
        lines
      end

      # One line per model that takes a `config.effort`, so a router can match
      # "Fable on extra-high reasoning" to a model and a level without guessing.
      def effort_lines(runtime)
        options = ModelCatalog.effort_options_by_runtime.fetch(runtime, {})
        return [ "- **Effort levels:** none — this runtime takes no `config.effort`" ] if options.empty?

        [ "- **Effort levels** (`config.effort`, lowest to highest; models not listed take none):" ] +
          options.map do |model, opts|
            "  - `#{model}`: #{opts[:levels].map { |level| "`#{level}`" }.join(', ')} (default `#{opts[:default]}`)"
          end
      end

      def format_models(runtime)
        ModelCatalog.models_for(runtime).map do |model|
          notes = []
          notes << "default" if model[:default]
          notes << "requires OAuth" if model[:requires_oauth]
          if model[:source] == "added"
            notes << "added"
            notes << "not in the installed CLI's model list" if model[:cli_listed] == false
          end
          "`#{model[:id]}`#{notes.any? ? " (#{notes.join(', ')})" : ""}"
        end.join(", ")
      end
    end
  end
end
