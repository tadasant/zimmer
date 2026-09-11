# frozen_string_literal: true

# How Zimmer names one artifact out of a composed AIR catalog.
#
# AIR qualifies every artifact as `@<scope>/<id>`: the scope is `local` for the
# deployment's own indexes and `<owner>/<repo>` for anything a `github://`
# catalog contributes. The qualification is the whole point of the format —
# it is what lets a local `slack` MCP server and an upstream
# `@reframe-systems/agentic-engineering/slack` be two different artifacts rather
# than a collision.
#
# Zimmer used to ask AIR to throw the qualification away (`air resolve
# --no-scope`), which made a cross-catalog shortname collision a HARD FAILURE of
# the entire resolve — the whole catalog degraded to last-known-good until an
# operator dropped one side via `air.json#exclude` (zimmer#208). It now resolves
# qualified and reduces each qualified ID to a **canonical token** here.
#
# ## The canonical token
#
# The token is what Zimmer stores (`sessions.mcp_servers`, `catalog_skills`,
# `metadata["agent_root_key"]`, a trigger's artifact columns), validates, shows
# in a picker, and hands back to `air prepare`. It is:
#
#   * the **bare short id** when a bare reference to it is unambiguous — which
#     is every artifact in a single-scope catalog, i.e. everything Zimmer has
#     today; and
#   * the **fully-qualified `@scope/id`** otherwise.
#
# So nothing that resolves today stops resolving: every stored bare id, every
# `default_in_roots` entry, every root default array and every MCP-OAuth
# credential row keeps the exact key it already has, and qualification appears
# only on the artifact that actually needs it. There is no re-keying migration
# because there is nothing to re-key.
#
# ## Which side of a collision keeps the bare token
#
# `@local` — the deployment's own catalog. A bare name written into Zimmer's own
# database or into its own index files most plausibly means the deployment's own
# artifact, and this mirrors AIR's own "intra-catalog" rule, where a short
# reference resolves within its author's scope first. The practical consequence
# is the one that matters: composing a new upstream catalog that happens to
# share a short id can never change the meaning of a name already stored here.
#
# When a collision is between two non-local scopes, neither keeps the bare
# token and both are addressed qualified. A stored bare id in that situation
# stops resolving, and is reported by the existing stale-reference machinery
# (CatalogArtifactReferences, AirPrepareService#scrubbed_catalog_skills) rather
# than silently picking a side.
module ArtifactIdentity
  # AIR's scope for anything not contributed by a catalog provider.
  LOCAL_SCOPE = "local"

  # Mixed into the six catalog facades' entry objects (ServersConfig::Server,
  # SkillsConfig::Skill, …) so every artifact Zimmer hands to a picker, an API
  # response or an MCP tool can say which catalog it came from.
  #
  # `#name` / `#id` stay the canonical token — the value that is stored,
  # validated and posted back — and the three readers here are additive. A
  # deployment with one catalog sees `qualified_name` of `@local/<id>` and
  # `contested?` false on every artifact, which is exactly the situation the
  # canonical token is designed to leave untouched.
  module Entry
    # The fully-qualified AIR ID (`@scope/id`). Falls back to the canonical
    # token for a tree resolved before qualification was preserved — i.e. a
    # CatalogSnapshot written by an older deploy.
    attr_reader :qualified_name

    # @param token [String] the canonical token this entry is addressed by
    # @param config [Hash] the resolved entry
    def identify!(token, config)
      @canonical_token = token
      @qualified_name = (config.is_a?(Hash) && config[QUALIFIED_ID_KEY].presence) || token
      @contested = config.is_a?(Hash) && config[CONTESTED_KEY] == true
    end

    # The catalog this artifact comes from — `"local"` for the deployment's own
    # indexes, `"<owner>/<repo>"` for a `github://` catalog. nil when the tree
    # carries no qualification at all.
    def scope
      ArtifactIdentity.scope_of(qualified_name)
    end

    # The value Zimmer stores, validates and posts back — `#name` / `#id` on
    # every facade object are this. Named explicitly so that lookup can match on
    # it without knowing which accessor a given artifact type uses.
    def canonical_token
      @canonical_token
    end

    # The bare last segment, which is NOT unique across a composed catalog.
    def short_id
      ArtifactIdentity.short_id(@canonical_token)
    end

    # True when another composed catalog contributes the same short id — on BOTH
    # sides of the collision, including the one that kept the bare token. This
    # is the flag a picker shows a scope badge on, and it is false for every
    # artifact in a single-scope catalog.
    def contested?
      @contested
    end
  end

  # Where the fully-qualified AIR ID is stashed on a canonicalized entry hash.
  #
  # Carried inside the entry rather than in a parallel map so that it survives
  # the CatalogSnapshot round-trip (jsonb) for free, and so every reader that
  # already holds an entry can answer "which catalog is this from?" without a
  # second lookup. Namespaced because AIR owns the rest of the key space.
  QUALIFIED_ID_KEY = "__zimmer_qualified_id"

  # Where "another catalog contributes this short id too" is stamped on a
  # canonicalized entry hash.
  #
  # It cannot be read off the token: the side that KEEPS the bare token is
  # exactly the side whose token says nothing about the collision, and that is
  # the side a picker most needs to label. It cannot be read off the entry
  # either, so it is recorded at the one moment the whole pool is in hand.
  #
  # Absent on every entry in a single-scope catalog, which is every entry Zimmer
  # has today.
  CONTESTED_KEY = "__zimmer_contested"

  # The reference-bearing fields of a resolved AIR entry, per artifact type, and
  # the pool each one points into. Mirrors `canonicalizeReferences` /
  # `computeRootMembership` in @pulsemcp/air-core: those are the only fields
  # whose values AIR rewrites into qualified IDs, so they are the only ones
  # Zimmer rewrites back.
  #
  # Deliberately a whitelist and not "every string starting with `@`": an MCP
  # entry's `args` legitimately carries `@upstash/context7-mcp@latest`, and
  # rewriting that would break the server.
  REFERENCE_FIELDS = {
    skills: { "references" => :references }.freeze,
    hooks: { "references" => :references }.freeze,
    mcp: {}.freeze,
    references: {}.freeze,
    plugins: {
      "skills" => :skills,
      "mcp_servers" => :mcp,
      "hooks" => :hooks,
      "plugins" => :plugins
    }.freeze,
    roots: {
      "default_skills" => :skills,
      "default_mcp_servers" => :mcp,
      "default_hooks" => :hooks,
      "default_plugins" => :plugins,
      "default_references" => :references,
      "default_subagent_roots" => :roots
    }.freeze
  }.freeze

  class << self
    # Does this string carry an AIR scope?
    def qualified?(ref)
      ref.is_a?(String) && ref.start_with?("@")
    end

    # The short id of a reference — the last path segment of a qualified ID, or
    # the reference itself when it is already bare.
    #
    # @return [String, nil] nil for a structurally unusable input
    def short_id(ref)
      return nil unless ref.is_a?(String) && ref.present?
      return ref unless qualified?(ref)

      ref.split("/").last.presence
    end

    # The scope of a qualified ID (`@a/b/c` → `"a/b"`), or nil when the
    # reference is bare or malformed.
    def scope_of(ref)
      return nil unless qualified?(ref)

      scope = ref[1..].rpartition("/").first
      scope.presence
    end

    # Is this qualified ID from the deployment's own indexes?
    def local?(ref)
      scope_of(ref) == LOCAL_SCOPE
    end

    # Reduce one type's qualified-ID-keyed entries to canonical-token-keyed
    # entries, stamping each with the qualified ID it came from.
    #
    # Idempotent on already-canonical input and a no-op on input that carries no
    # qualified keys at all, because both are real: a CatalogSnapshot written by
    # an older deploy holds bare keys, and the test suite stubs bare-keyed trees.
    #
    # @param entries [Hash{String => Hash}] `air resolve` output for one type
    # @return [Hash{String => Hash}] canonical token => entry
    def canonicalize(entries)
      return {} unless entries.is_a?(Hash)

      tokens = canonical_tokens(entries.keys)
      contested = contested_short_ids(entries.keys)

      entries.each_with_object({}) do |(key, entry), out|
        next unless entry.is_a?(Hash)

        token = tokens[key]
        # A key with no usable short id, and a token a previous key already
        # took, both mean the input was not a well-formed AIR tree — a bare key
        # sitting alongside the qualified form of the same artifact, say. Keying
        # the second one under its own key keeps BOTH entries: last-write-wins
        # would silently drop one, which is the failure mode this whole change
        # exists to remove.
        next if token.blank?
        token = key if out.key?(token)

        stamped = qualified?(key) ? entry.merge(QUALIFIED_ID_KEY => key) : entry
        stamped = stamped.merge(CONTESTED_KEY => true) if contested.include?(short_id(key))
        out[token] = stamped
      end
    end

    # The canonical token each of these keys reduces to.
    #
    # @param keys [Array<String>]
    # @return [Hash{String => String}] key => canonical token
    def canonical_tokens(keys)
      by_short = keys.group_by { |key| short_id(key) }

      keys.index_with do |key|
        short = short_id(key)
        # One contender keeps the bare token: the only one, or `@local`. Only
        # one contender can be `@local`, because AIR hard-fails a duplicate
        # qualified ID.
        (by_short[short] || []).size == 1 || local?(key) ? short : key
      end
    end

    # The short ids more than one of these keys reduces to.
    #
    # @param keys [Array<String>]
    # @return [Set<String>]
    def contested_short_ids(keys)
      keys.group_by { |key| short_id(key) }.filter_map { |short, group| short if group.size > 1 }.to_set
    end

    # Rewrite an entry's reference fields from qualified IDs to the canonical
    # tokens of the pools they point into, so a root's `default_skills` names
    # skills the way the rest of Zimmer does.
    #
    # A reference that names nothing in its pool is passed through untouched:
    # AIR has already dropped the genuinely dangling ones (and Zimmer fails the
    # resolve when it does), so anything left is a shape this code does not
    # recognise, and mangling it would be worse than carrying it.
    #
    # @param entry [Hash] a canonicalized entry
    # @param type [Symbol] the artifact type the entry belongs to
    # @param tokens_by_type [Hash{Symbol => Hash{String => String}}] qualified ID
    #   => canonical token, per pool
    # @return [Hash]
    def rewrite_references(entry, type, tokens_by_type)
      fields = REFERENCE_FIELDS[type]
      return entry if fields.blank?

      fields.each_with_object(entry.dup) do |(field, pool), out|
        values = out[field]
        next unless values.is_a?(Array)

        tokens = tokens_by_type[pool] || {}
        out[field] = values.map { |ref| ref.is_a?(String) ? (tokens[ref] || ref) : ref }
      end
    end

    # Resolve a reference — a canonical token, a fully-qualified ID, or a bare
    # short id — to the canonical token that addresses it in `entries`.
    #
    # The three steps are AIR's own resolution order, narrowed to the one place
    # Zimmer differs (an ambiguous bare reference prefers `@local`, per the
    # module comment):
    #
    #   1. the reference IS a canonical token — the overwhelmingly common case,
    #      and the one that keeps every stored bare id working;
    #   2. the reference is the qualified ID of an entry whose canonical token
    #      is something else — always accepted, which is how the losing side of
    #      a collision is addressed;
    #   3. the reference is a bare short id that no token matches, because the
    #      entry that owns it is addressed qualified — resolved only when
    #      exactly one entry carries it.
    #
    # @param entries [Hash{String => Hash}] canonicalized entries for one type
    # @param ref [String]
    # @return [String, nil] the canonical token, or nil when nothing resolves
    def resolve(entries, ref)
      return nil unless ref.is_a?(String) && ref.present?
      return ref if entries.key?(ref)

      if qualified?(ref)
        match = entries.find { |_token, entry| entry.is_a?(Hash) && entry[QUALIFIED_ID_KEY] == ref }
        return match&.first
      end

      candidates = entries.keys.select { |token| short_id(token) == ref }
      candidates.size == 1 ? candidates.first : nil
    end

    # Find one artifact in a facade's own collection by any of its three legal
    # spellings — canonical token, fully-qualified `@scope/id`, or a bare short
    # id exactly one catalog contributes.
    #
    # Deliberately over the LIST a facade already built rather than over
    # AirCatalogService's raw tree: `find` and `all` must answer about the same
    # catalog, and a caller (or a test) that substitutes one has substituted
    # both. Resolving against the tree instead made `AgentRootsConfig.find`
    # blind to a stubbed `.all`.
    #
    # @param list [Array<#canonical_token, #qualified_name, #short_id>]
    # @param ref [String]
    def find(list, ref)
      return nil unless ref.is_a?(String) && ref.present?

      exact = list.find { |entry| entry.canonical_token == ref }
      return exact if exact
      return list.find { |entry| entry.qualified_name == ref } if qualified?(ref)

      # Unreachable against a consistently canonicalized list — an entry whose
      # short id matches a token that matched nothing must carry a qualified
      # token, which means its short id is contested, which means there are at
      # least two of them. Kept for the list that is NOT canonicalized: a
      # CatalogSnapshot from a different code version, or a stubbed tree.
      candidates = list.select { |entry| entry.short_id == ref }
      candidates.size == 1 ? candidates.first : nil
    end

    # Does another composed catalog contribute this entry's short id?
    #
    # Read off the stamp rather than off the token, because the side that KEEPS
    # the bare token is exactly the side whose token says nothing about the
    # collision — and that is the side AIR would call ambiguous.
    def contested?(entries, ref)
      token = resolve(entries, ref)
      return false unless token

      entry = entries[token]
      entry.is_a?(Hash) && entry[CONTESTED_KEY] == true
    end

    # The fully-qualified AIR ID for a canonicalized entry — what `air prepare`
    # has to be handed for an artifact whose bare short id it would call
    # ambiguous.
    #
    # Falls back to the token itself for an entry with no qualified ID recorded,
    # which is what a CatalogSnapshot written before this change holds.
    #
    # @return [String, nil]
    def qualified_id(entries, ref)
      token = resolve(entries, ref)
      return nil unless token

      entry = entries[token]
      (entry.is_a?(Hash) && entry[QUALIFIED_ID_KEY].presence) || token
    end

    # Canonicalize a whole resolved tree: every type's entries re-keyed to
    # canonical tokens, then every entry's reference fields rewritten to the
    # tokens of the pools they point into.
    #
    # Two passes because the second needs the first's answer for *every* type —
    # a root's `default_skills` names skills, and a plugin's `hooks` names hooks.
    #
    # @param tree [Hash{Symbol => Hash{String => Hash}}]
    # @return [Hash{Symbol => Hash{String => Hash}}]
    def canonicalize_tree(tree)
      tokens_by_type = tree.transform_values { |entries| canonical_tokens(entries.is_a?(Hash) ? entries.keys : []) }

      tree.each_with_object({}) do |(type, entries), out|
        canonical = canonicalize(entries)
        out[type] = canonical.transform_values { |entry| rewrite_references(entry, type, tokens_by_type) }
      end
    end
  end
end
