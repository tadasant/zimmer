# frozen_string_literal: true

module RootData
  # Which namespace a call to the `root_data` tools reads and writes — resolved
  # from the calling session, server-side, and never from a tool argument.
  #
  #   session_id (stamped on the MCP URL by RuntimeConfigPostProcessor)
  #     → the session's `metadata["agent_root_key"]`
  #     → that root in the catalog
  #     → its optional `data_namespace`, else its canonical name
  #
  # The router root's deprecated alias (`zimmer-router`) resolves to the
  # preferred root (`zimmer-orchestrator`), config and name both, so sessions
  # created under either name share one store.
  #
  # Refuses rather than guesses. In particular it never falls back to matching
  # the session's git_root/subdirectory against the catalog the way
  # AgentRootsConfig.find_for_session does: several roots share one repository,
  # so that fallback would hand one root's data to another. And a root the
  # catalog cannot find is refused too — its `data_namespace` is unknowable, and
  # guessing its name could write into the wrong namespace.
  class Namespace
    class Unresolvable < StandardError; end

    # What a catalog-declared `data_namespace` may look like.
    PATTERN = /\A[a-z0-9][a-z0-9._-]{0,99}\z/

    Resolved = Data.define(:namespace, :root, :session)

    def self.for_session_id(session_id)
      new.for_session_id(session_id)
    end

    def for_session_id(session_id)
      if session_id.nil?
        raise Unresolvable, "This MCP connection names no calling session, so there is no agent root to scope " \
                            "the data to. Root data is reachable only from an agent session whose Zimmer MCP entry " \
                            "Zimmer wrote (it stamps `session_id` onto the URL)."
      end

      session = Session.find_by(id: session_id)
      raise Unresolvable, "This MCP connection names session #{session_id}, which does not exist." unless session

      key = session.metadata&.dig("agent_root_key")
      if key.blank?
        raise Unresolvable, "Session #{session.id} was not started from an agent root, so it has no root data " \
                            "namespace."
      end

      root = resolve_root(key)
      unless root
        raise Unresolvable, "Session #{session.id}'s agent root \"#{key}\" is not in the catalog, so its data " \
                            "namespace cannot be resolved. Nothing was read or written."
      end

      Resolved.new(namespace: namespace_for(root), root: root, session: session)
    end

    private

    def resolve_root(key)
      roots = AgentRootsConfig.all
      root = ArtifactIdentity.find(roots, key)
      router_names = AgentRootsConfig::ROUTER_ROOT_NAMES
      return root unless router_names.include?(root ? root.name : key)

      # The router's names: the preferred one's config wins whenever the catalog
      # carries it, whichever name the session was created under.
      router_names.lazy.filter_map { |name| ArtifactIdentity.find(roots, name) }.first
    end

    # The default is the root's SHORT id, not its canonical token: the token
    # becomes `@scope/id` the moment another composed catalog contributes the
    # same short id, and a namespace that moved with it would orphan the root's
    # data. A root that wants its store pinned against a rename declares
    # `data_namespace`.
    def namespace_for(root)
      declared = root.data_namespace
      namespace = declared.nil? ? canonical_name(root.short_id || root.name) : declared

      unless namespace.is_a?(String) && namespace.match?(PATTERN)
        raise Unresolvable, "Agent root \"#{root.name}\" resolves to data namespace #{namespace.inspect}, which is not " \
                            "a valid namespace (lowercase letters, digits, '.', '_' and '-', at most 100 characters). " \
                            "Declare a valid data_namespace on the root. Nothing was read or written."
      end

      namespace
    end

    def canonical_name(name)
      AgentRootsConfig::ROUTER_ROOT_NAMES.include?(name) ? AgentRootsConfig::ROUTER_ROOT_NAMES.first : name
    end
  end
end
