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
  class ParameterStoreProvider
    LABEL = "Zimmer's Google Parameter Store"

    # Fixed badge string — see SecretProviders::Env::BADGE. "GSM" rather than
    # "Parameter Manager" because the value itself lives in Google Secret
    # Manager; the parameter only points at it.
    BADGE = "GSM"

    NEGATIVE_TTL = 10.seconds

    attr_reader :client, :namespace

    def initialize(client, namespace: ParameterStore::Namespace.static_namespace)
      @client = client
      @namespace = namespace
      @last_miss_refresh_at = nil
      @cache = ParameterStore::SnapshotCache.new { |key| client.resolve(key) }
    end

    def name = "parameter_store"
    def label = LABEL
    def badge = BADGE

    def badge_title
      "Google Secret Manager — #{namespace} in #{project_id}"
    end

    # @return [String, nil] nil only when the store answered and does not hold it.
    # @raise [ParameterStore::StoreError, ParameterStore::AuthError] when the
    #   store could not be consulted at all and no snapshot is held.
    def get(variable)
      hit = @cache.get(namespace)[variable]
      return hit unless hit.nil?

      return nil unless refresh_for_miss?

      @last_miss_refresh_at = Time.current
      @cache.refresh(namespace)
      @cache.peek(namespace)&.[](variable)
    end

    def has?(variable) = !get(variable).nil?

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
      @cache.invalidate(namespace)
      @last_miss_refresh_at = nil
    end

    private

    def refresh_for_miss?
      return false if @cache.age(namespace) < NEGATIVE_TTL
      return true if @last_miss_refresh_at.nil?

      Time.current - @last_miss_refresh_at >= NEGATIVE_TTL
    end
  end
end
