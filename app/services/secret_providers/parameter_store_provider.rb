# frozen_string_literal: true

module SecretProviders
  # Google Parameter Manager + Secret Manager, read through a whole-namespace
  # snapshot.
  #
  # Freshness contract:
  #
  #   * A ROTATED value is visible within the snapshot TTL (60s).
  #   * A NEWLY ADDED name is visible within the negative TTL (10s): a miss
  #     triggers one out-of-band refresh, rate-limited so that a `${VAR}` which
  #     genuinely does not exist cannot turn every lookup into a store round trip.
  #
  # ## Why this reads more than one namespace
  #
  # `ParameterStore::Namespace`'s scope segment was renamed, and the fold from a
  # path to a GCP resource id is lossy, so the data cannot be renamed in place —
  # it is copied to the new path and the old one deleted (see
  # {ParameterStore::NamespaceMigration}). The code deploy and the data move are
  # separate events, in an order nobody controls, and this chain's contract is
  # that a miss is not an error: a resolver reading only the new namespace before
  # the data moved would report every secret as unset, with the Connectors page
  # the sole place it showed. So it reads BOTH, canonical first, and
  # {#namespace_for} says which one answered.
  class ParameterStoreProvider
    LABEL = "Zimmer's Google Parameter Store"

    # Fixed badge string — see SecretProviders::Env::BADGE. "GSM" rather than
    # "Parameter Manager" because the value itself lives in Google Secret
    # Manager; the parameter only points at it.
    BADGE = "GSM"

    NEGATIVE_TTL = 10.seconds

    attr_reader :client, :namespaces

    # @param namespaces [Array<String>] in precedence order; the first is the
    #   canonical one, which is the only one anything writes to.
    def initialize(client, namespaces: ParameterStore::Namespace.read_namespaces)
      @client = client
      @namespaces = Array(namespaces).freeze
      raise ArgumentError, "a Parameter Store provider needs at least one namespace" if @namespaces.empty?

      @last_miss_refresh_at = nil
      # The cache key is the whole list, and the loader resolves the list in one
      # pass over the project: reading two namespaces costs what reading one did.
      @cache = ParameterStore::SnapshotCache.new { |key| client.resolve_all(key) }
    end

    def name = "parameter_store"
    def label = LABEL
    def badge = BADGE

    # @param variable [String, nil] when given, the title names the namespace
    #   that ACTUALLY answered for it rather than the canonical one — which is
    #   how a half-migrated store is visible from the Connectors page.
    def badge_title(variable = nil)
      answered = variable.nil? ? nil : namespace_for(variable)

      "Google Secret Manager — #{answered || namespace} in #{project_id}"
    end

    # The canonical namespace: written to, and the one a human is pointed at.
    def namespace = @namespaces.first

    # The pre-rename namespaces, still read. Empty once the old read path is
    # dropped, which is a change to Namespace.read_namespaces and nothing else.
    def legacy_namespaces = @namespaces.drop(1)

    # @return [String, nil] nil only when the store answered and does not hold it.
    # @raise [ParameterStore::StoreError, ParameterStore::AuthError] when the
    #   store could not be consulted at all and no snapshot is held.
    def get(variable) = entry_for(variable)&.last

    def has?(variable) = !entry_for(variable).nil?

    # Which namespace holds `variable` — the canonical one, or a pre-rename one
    # it has not been migrated out of yet.
    #
    # @return [String, nil] nil when nothing holds it.
    def namespace_for(variable) = entry_for(variable)&.first

    # The names still sitting in a pre-rename namespace, whether or not the
    # canonical namespace also holds them. This is the migration's progress
    # readout, and it is free: the snapshot already covers both.
    #
    # @return [Array<String>] sorted; names, never values.
    # A refused name counts as still sitting there: it is a parameter at the old
    # path, and the question this answers is whether the pre-rename read path can
    # be dropped. Leaving it out would let the banner say the namespace is empty
    # while it still holds a parameter.
    def legacy_variables
      snapshot = @cache.get(@namespaces)
      legacy_namespaces
        .flat_map { |ns| (snapshot[ns]&.keys || []) + undecodable_in(snapshot, ns) }
        .uniq.sort
    end

    # The names the store HOLDS and this Zimmer refuses to serve, because their
    # envelope declares a value encoding it does not implement, or does not match
    # the one it declares (see {ParameterStore::GcpClient#decoded_value}).
    #
    # These read exactly like a name that was never seeded — the chain falls
    # through to the next provider, and the row says `Unresolved` — so without
    # this list an operator has no way to tell the two apart. Free, like
    # {#legacy_variables}: the snapshot already carries it.
    #
    # A name refused in ONE namespace but served from another is not listed: it
    # resolves normally, and naming it would send an operator after a value that
    # works. That is the ordinary state mid-migration, where a stale pre-rename
    # copy sits behind a good canonical one.
    #
    # @return [Array<String>] sorted; names, never values.
    def undecodable_variables
      snapshot = @cache.get(@namespaces)
      return [] unless snapshot.is_a?(ParameterStore::GcpClient::Snapshot)

      snapshot.undecodable.values.flatten.uniq
        .reject { |variable| @namespaces.any? { |ns| snapshot[ns]&.key?(variable) } }
        .sort
    end

    # The full canonical path a variable occupies (or would occupy) in the store.
    # The Connectors page shows this; it is an address, not a secret.
    def path_for(variable)
      "#{namespace}#{variable}"
    end

    def project_id = client.project_id
    def location = client.location

    # What this credential can actually do, memoized with a short TTL so the
    # Connectors page can show it without probing on every render.
    #
    # @return [ParameterStore::Capabilities]
    def capabilities
      ttl = @capabilities&.probed? ? ParameterStore::Capabilities::TTL : ParameterStore::Capabilities::FAILURE_TTL
      if @capabilities.nil? || @capabilities_at.nil? || Time.current - @capabilities_at >= ttl
        @capabilities = ParameterStore::Capabilities.probe(client)
        @capabilities_at = Time.current
      end
      @capabilities
    end

    # The snapshot is whole-namespace, so a single name cannot be dropped in
    # isolation — and dropping the lot is the right thing anyway.
    def invalidate(_variable = nil)
      @cache.invalidate(@namespaces)
      @last_miss_refresh_at = nil
    end

    private

    def undecodable_in(snapshot, namespace)
      return [] unless snapshot.is_a?(ParameterStore::GcpClient::Snapshot)

      snapshot.undecodable[namespace] || []
    end

    # @return [Array(String, String), nil] the namespace that answered and the
    #   value it held, in {#namespaces} precedence order.
    def entry_for(variable)
      hit = find(@cache.get(@namespaces), variable)
      return hit unless hit.nil?

      return nil unless refresh_for_miss?

      @last_miss_refresh_at = Time.current
      # Forced: the snapshot is fresh by definition here (see refresh_for_miss?),
      # it just does not hold this name yet.
      @cache.refresh(@namespaces, force: true)
      find(@cache.peek(@namespaces) || {}, variable)
    end

    def find(snapshot, variable)
      @namespaces.each do |namespace|
        value = snapshot[namespace]&.[](variable)
        return [ namespace, value ] unless value.nil?
      end
      nil
    end

    def refresh_for_miss?
      return false if @cache.age(@namespaces) < NEGATIVE_TTL
      return true if @last_miss_refresh_at.nil?

      Time.current - @last_miss_refresh_at >= NEGATIVE_TTL
    end
  end
end
