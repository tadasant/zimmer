# frozen_string_literal: true

module Sessions
  # The one implementation of "change which MCP servers / skills / hooks /
  # plugins a session has".
  #
  # Four catalog attributes × three surfaces is twelve ways to ask for the same
  # thing, and every axis that is hand-copied across them drifts: whether the
  # runtime config is regenerated, whether the OAuth probe runs, whether the
  # write is retried, which constants bound the list. All of that is the
  # *operation*, and it lives here. Each surface keeps only its own
  # authorization and its own response rendering.
  #
  #   Sessions::UpdateCatalogSelection.call(
  #     session: session,
  #     attribute: :mcp_servers,   # or :catalog_skills / :catalog_hooks / :catalog_plugins
  #     values: %w[github linear],
  #     actor: :web                # or :api / :mcp — decides the log sentence only
  #   )
  #
  # ## Regeneration policy: this never rewrites the session's runtime config
  #
  # A catalog-selection change is persisted and nothing else. It takes effect the
  # next time the session's runtime config is prepared — its next turn, a
  # restart, or an unarchive — all three of which already run
  # `AirPrepareService#prepare!` against the clone.
  #
  # Regenerating here would be redundant at best and wrong at worst:
  #
  # - It cannot reach a *running* agent. MCP servers are launched by the CLI at
  #   process start, so rewriting `.mcp.json` under a live process changes
  #   nothing about that process's tools — it only writes into a clone the agent
  #   is working in.
  # - It is redundant for an *idle* session. `AgentSessionJob` re-runs
  #   `prepare!` at the top of every follow-up turn precisely to sync skills,
  #   hooks and MCP config, and `UnarchiveSessionService` does the same.
  # - It is a shell-out (npm, `air prepare`) inside an HTTP request, and only
  #   half of what a prepare entails: `AgentSessionJob` also persists
  #   `injected_mcp_servers` from the result, so a regeneration driven from a
  #   request would leave the session's recorded injections diverged from what
  #   AIR had just written into the clone.
  #
  # The OAuth probe is a separate question and is *not* deferred: it reads the
  # catalog and the credential store rather than the clone's `.mcp.json`, so it
  # answers "will this session need you to authorize something?" as soon as the
  # selection changes, which is the whole reason the web UI runs it.
  class UpdateCatalogSelection
    include DatabaseRetry

    # Which attributes can carry an MCP server into the session, and therefore
    # need the OAuth probe. Skills and hooks bundle no servers.
    OAUTH_PROBED_ATTRIBUTES = %i[mcp_servers catalog_plugins].freeze

    # How each surface names itself in the session's log feed.
    ACTOR_SUFFIXES = { web: "", api: " via API", mcp: " via MCP" }.freeze

    Result = Struct.new(
      :ok,
      :session,
      :attribute,
      :values,
      :added,
      :removed,
      :servers_needing_oauth,
      :error,
      :error_code,
      :invalid,
      keyword_init: true
    ) do
      def ok? = ok
      def oauth_required? = servers_needing_oauth.present?
    end

    class << self
      def call(session:, attribute:, values:, actor:)
        new(session: session, attribute: attribute, values: values, actor: actor).call
      end

      # Normalize one catalog list without touching a session: drop blanks, trim
      # and truncate each id, then reject anything the catalog does not know.
      #
      # Split out because triggers stamp the same three lists onto the sessions
      # they spawn (see Mcp::Tool#validated_catalog_list!), and the cap, the
      # truncation and the unknown-id rejection have to be the same rule there.
      #
      # @return [Array(Array<String>, Array<String>)] the normalized ids, and the
      #   subset of them the catalog does not know (empty when everything is valid)
      def normalize(attribute, values)
        spec = spec_for(attribute)
        normalized = Array(values).reject(&:blank?).map do |value|
          value.to_s.strip.first(Session::MAX_CATALOG_SELECTION_ID_LENGTH)
        end
        [ normalized, normalized.reject { |id| spec[:config].constantize.exists?(id) } ]
      end

      # The ids a caller could legally have sent, for an error message that is
      # actionable on its own (a rename like `pr` → `open-pr` is then obvious).
      # The three catalog artifacts key on `id`; a Server keys on `name`.
      def valid_ids(attribute)
        spec_for(attribute)[:config].constantize.all.map { |entry|
          entry.respond_to?(:id) ? entry.id : entry.name
        }.sort
      end

      def spec_for(attribute)
        Session::CATALOG_SELECTIONS.fetch(attribute.to_sym) do
          raise ArgumentError, "Unknown catalog selection attribute: #{attribute.inspect}"
        end
      end
    end

    def initialize(session:, attribute:, values:, actor:)
      @session = session
      @attribute = attribute.to_sym
      @spec = self.class.spec_for(@attribute)
      @raw_values = values
      @actor = actor.to_sym
    end

    def call
      return too_many_error unless Array(@raw_values).length <= @spec[:max]

      values, invalid = self.class.normalize(@attribute, @raw_values)
      return invalid_error(invalid) if invalid.any?

      old_values = @session.public_send(@attribute) || []

      # Clearing the list has to be recorded as deliberate, or McpServerBackfill
      # reads the empty column as an accident and restores the root's defaults
      # the next time the config is regenerated.
      @session.record_explicit_mcp_servers(values) if @attribute == :mcp_servers

      # The write is retried the way the web copies always retried it, and the
      # REST and MCP copies did not. A dropped PG connection is a transport
      # failure, not a rejected request, so it comes back as its own error code
      # for the surface to answer 503 to rather than as a validation failure.
      begin
        persisted = with_db_retry { @session.update(@attribute => values) }
      rescue *DatabaseRetry::RETRYABLE_EXCEPTIONS => e
        return database_unavailable_error(e)
      end
      return update_failed_error(values) unless persisted

      added = values - old_values
      removed = old_values - values

      # A deliberate removal is not an unexplained loss — forget its status so
      # later config regenerations don't report it as one.
      @session.forget_mcp_server_status!(removed) if @attribute == :mcp_servers

      log_change(added, removed)

      Result.new(
        ok: true,
        session: @session,
        attribute: @attribute,
        values: values,
        added: added,
        removed: removed,
        servers_needing_oauth: resolve_oauth,
        invalid: []
      )
    end

    private

    # Probe the servers this session would use, and put the session into the
    # state the OAuth UI reads when any of them need authorizing.
    #
    # Runs for `mcp_servers` and `catalog_plugins` only — a plugin can bundle MCP
    # servers (Session#derive_mcp_servers_from_plugins), skills and hooks cannot.
    def resolve_oauth
      return [] unless OAUTH_PROBED_ATTRIBUTES.include?(@attribute)

      needing = McpOauthProbe.new(@session).servers_needing_oauth
      needing.any? ? escalate_oauth(needing) : clear_stale_oauth_metadata
      needing
    end

    # Everything after the write is best-effort: the selection is already saved,
    # and losing the Authorize banner to a database blip is better than reporting
    # a write that happened as one that did not.
    def best_effort
      yield
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn "[Sessions::UpdateCatalogSelection] post-write step failed (non-fatal): #{e.message}"
      nil
    end

    def escalate_oauth(needing)
      # Never on a running session. The escalation exists to surface Authorize
      # buttons on a session that cannot proceed, and `fail!` accepts `running`
      # — so escalating one would kill a live turn over a change the session's
      # already-spawned process cannot even see. The metadata is skipped with the
      # transition rather than written on its own, because both banners key on
      # `failed?` and would render nothing from it; AgentSessionJob's pre-spawn
      # gate re-detects the requirement before the next turn. The caller is still
      # told which servers need authorizing — only the parking waits.
      return if @session.running?

      best_effort do
        @session.reload
        @session.update!(
          metadata: (@session.metadata || {}).merge(
            "failure_reason" => "oauth_required",
            "oauth_required_servers" => needing
          )
        )
        @session.fail! if @session.may_fail?

        @session.logs.create!(
          content: "OAuth authorization required for: #{needing.map { |s| s[:server_name] }.join(', ')}",
          level: "warning"
        )
      end
    end

    def clear_stale_oauth_metadata
      return unless @session.metadata&.dig("failure_reason") == "oauth_required"

      best_effort do
        @session.reload
        @session.update!(metadata: (@session.metadata || {}).except("failure_reason", "oauth_required_servers"))
      end
    end

    def log_change(added, removed)
      changes = []
      changes << "added: #{added.join(', ')}" if added.any?
      changes << "removed: #{removed.join(', ')}" if removed.any?
      return if changes.empty?

      best_effort do
        @session.logs.create!(
          content: "#{@spec[:label].upcase_first} updated#{ACTOR_SUFFIXES.fetch(@actor, '')} (#{changes.join('; ')})",
          level: "info"
        )
      end
    end

    def too_many_error
      failure(
        code: :too_many,
        message: "Too many #{@spec[:label]} (maximum #{@spec[:max]})"
      )
    end

    def invalid_error(invalid)
      failure(
        code: :invalid_entries,
        message: "Invalid #{@spec[:label]}: #{invalid.join(', ')}",
        invalid: invalid
      )
    end

    def database_unavailable_error(error)
      Rails.logger.error "[Sessions::UpdateCatalogSelection] database unavailable for session #{@session.id}: #{error.message}"
      failure(
        code: :database_unavailable,
        message: "The operation couldn't be completed due to high server activity. Please try again."
      )
    end

    def update_failed_error(values)
      failure(code: :update_failed, message: @session.errors.full_messages.join(", "), values: values)
    end

    def failure(code:, message:, invalid: [], values: nil)
      Result.new(
        ok: false,
        session: @session,
        attribute: @attribute,
        values: values,
        added: [],
        removed: [],
        servers_needing_oauth: [],
        error: message,
        error_code: code,
        invalid: invalid
      )
    end
  end
end
