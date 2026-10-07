# frozen_string_literal: true

module WebAuth
  # What the web sign-in gate is told by the deployment, and nothing else.
  #
  # Every value resolves through SecretProviders.chain — the Parameter Store
  # first, then Rails credentials, then the process environment — so turning
  # the gate on is a secret-store write, not a code change and not a box login.
  #
  # ## On, off, and the half-configured middle
  #
  # The gate is ON exactly when ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID resolves. That
  # one variable is the deployment's statement of intent:
  #
  #   * Nothing set -> OFF. The web UI asks nobody to sign in, and the network
  #     perimeter is the only wall.
  #   * Client ID set, but the secret or the allowed domains missing -> ON and
  #     MISCONFIGURED. Nobody can sign in, and the login page names what is
  #     missing. It fails closed on purpose: once a deployment has said it wants
  #     a wall, a typo must not quietly leave the UI open.
  #
  # ## Reads are cached, and survive a store outage
  #
  # The gate asks on every web request, so the answer is memoized per process
  # for CACHE_TTL. Every successful read is also written to Rails.cache, without
  # the client secret. When the store cannot be reached, a process keeps the
  # last answer it saw; a process that has seen none (one that booted during
  # the outage) uses the one in Rails.cache, with sign-in itself paused because
  # the secret is not there. Only with neither does it raise Unavailable, and
  # the gate answers 503 rather than guess whether the wall should be up.
  class Configuration
    CLIENT_ID = "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID"
    CLIENT_SECRET = "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_SECRET"
    ALLOWED_DOMAINS = "ZIMMER_WEB_AUTH_ALLOWED_DOMAINS"
    SECOND_FACTOR = "ZIMMER_WEB_AUTH_SECOND_FACTOR"
    SESSION_DAYS = "ZIMMER_WEB_AUTH_SESSION_DAYS"
    TRUSTED_DEVICE_DAYS = "ZIMMER_WEB_AUTH_TRUSTED_DEVICE_DAYS"
    SECOND_FACTOR_RESET_BEFORE = "ZIMMER_WEB_AUTH_SECOND_FACTOR_RESET_BEFORE"

    VARIABLES = [
      CLIENT_ID, CLIENT_SECRET, ALLOWED_DOMAINS, SECOND_FACTOR,
      SESSION_DAYS, TRUSTED_DEVICE_DAYS, SECOND_FACTOR_RESET_BEFORE
    ].freeze

    # A signed-in browser stays signed in while it is used at least this often.
    DEFAULT_SESSION_DAYS = 90
    # A browser that passed the second factor skips it on later Google sign-ins
    # for this long.
    DEFAULT_TRUSTED_DEVICE_DAYS = 365

    # `totp`: Zimmer asks for an authenticator code after Google.
    # `google`: Zimmer asks for nothing more and relies on the Workspace's own
    # 2-Step Verification policy, which it cannot verify.
    SECOND_FACTOR_MODES = %w[totp google].freeze

    CACHE_TTL = 60.seconds
    LAST_KNOWN_CACHE_KEY = "web_auth/configuration/last_known"

    class Unavailable < StandardError; end

    class << self
      # @return [WebAuth::Configuration]
      # @raise [Unavailable] when the store has never answered this process
      def current
        cached, cached_at = mutex.synchronize { [ @cached, @cached_at ] }
        return cached if cached && monotonic_now - cached_at < CACHE_TTL.to_i

        # The read happens outside the mutex: it can be a network call, and
        # holding the lock through it would queue every Puma thread behind it.
        fresh = read_from_store(fallback: cached)
        mutex.synchronize do
          @cached = fresh
          @cached_at = monotonic_now
        end
        fresh
      end

      # Tests drop the memo so the next read is fresh.
      def reset!
        mutex.synchronize { @cached = nil }
      end

      private

      def read_from_store(fallback:)
        values = VARIABLES.index_with { |name| SecretProviders.chain.get(name) }
        remember_last_known(values)
        new(values)
      rescue StandardError => e
        Rails.logger.warn("[web_auth] configuration read failed: #{e.class}: #{e.message}")
        return fallback if fallback

        last_known = read_last_known
        raise Unavailable, "the secret store did not answer (#{e.class})" if last_known.nil?

        new(last_known, store_unavailable: true)
      end

      # Never fatal: the cache is the fallback's fallback.
      def remember_last_known(values)
        Rails.cache.write(LAST_KNOWN_CACHE_KEY, values.except(CLIENT_SECRET))
      rescue StandardError
        nil
      end

      def read_last_known
        value = Rails.cache.read(LAST_KNOWN_CACHE_KEY)
        value.is_a?(Hash) ? value : nil
      rescue StandardError
        nil
      end

      def mutex = (@mutex ||= Mutex.new)

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # @param values [Hash{String => String, nil}] variable name -> resolved value
    # @param store_unavailable [Boolean] true when these values are the last
    #   known ones from Rails.cache because the store did not answer
    def initialize(values, store_unavailable: false)
      @values = values.transform_values { |v| v.to_s.strip.presence }
      @store_unavailable = store_unavailable
      @second_factor_reset_before = parse_time(@values[SECOND_FACTOR_RESET_BEFORE])
    end

    def enabled? = client_id.present?

    def client_id = @values[CLIENT_ID]

    def client_secret = @values[CLIENT_SECRET]

    # Lowercased, de-duplicated Google Workspace domains, e.g. ["tadasant.com"].
    def allowed_domains
      @values[ALLOWED_DOMAINS].to_s.split(/[\s,]+/).map { |d| d.strip.downcase.delete_prefix("@") }.compact_blank.uniq
    end

    def domain_allowed?(domain)
      domain.present? && allowed_domains.include?(domain.to_s.downcase)
    end

    # What a configured-on gate is missing, in words for the login page. Empty
    # when the gate can actually sign someone in.
    def problems
      return [] unless enabled?

      problems = []
      if @store_unavailable
        problems << "the secret store is not answering, so sign-in cannot finish until it does"
      elsif client_secret.blank?
        problems << "#{CLIENT_SECRET} is not set"
      end
      problems << "#{ALLOWED_DOMAINS} names no domain" if allowed_domains.empty?
      if @values[SECOND_FACTOR] && !SECOND_FACTOR_MODES.include?(@values[SECOND_FACTOR].downcase)
        problems << "#{SECOND_FACTOR} must be one of #{SECOND_FACTOR_MODES.join(", ")}"
      end
      if @values[SECOND_FACTOR_RESET_BEFORE] && @second_factor_reset_before.nil?
        problems << "#{SECOND_FACTOR_RESET_BEFORE} is not an ISO 8601 time"
      end
      problems
    end

    def usable? = enabled? && problems.empty?

    def second_factor_mode = (@values[SECOND_FACTOR] || "totp").downcase

    # Anything but an explicit `google` requires TOTP, so a typo in the mode
    # fails closed rather than switching the second factor off.
    def totp_required? = second_factor_mode != "google"

    def session_ttl = positive_days(SESSION_DAYS, DEFAULT_SESSION_DAYS)

    def trusted_device_ttl = positive_days(TRUSTED_DEVICE_DAYS, DEFAULT_TRUSTED_DEVICE_DAYS)

    # Any second factor confirmed before this instant is void: its owner sets up
    # a new one at their next sign-in. The recovery path for a lost authenticator
    # and lost recovery codes, reachable with a secret-store write and no shell.
    # Safe to leave set: an enrollment made after it is unaffected.
    #
    # An unparseable value is listed in `problems`, which stops new sign-ins and
    # names it on the login page, rather than being quietly ignored.
    #
    # @return [Time, nil]
    attr_reader :second_factor_reset_before

    # Where Google sends the browser back. Must be registered, exactly, on the
    # Google Cloud OAuth client.
    def redirect_uri
      "#{AppUrl.base_url}/auth/google/callback"
    end

    private

    def parse_time(raw)
      raw.present? ? Time.iso8601(raw) : nil
    rescue ArgumentError
      nil
    end

    def positive_days(name, default)
      days = Integer(@values[name] || default, exception: false)
      (days && days.positive? ? days : default).days
    end
  end
end
