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
  #   * Nothing set (every deployment before this shipped) -> OFF. The web UI
  #     behaves exactly as it did, so deploying this code changes nothing.
  #   * Client ID set, but the secret or the allowed domains missing -> ON and
  #     MISCONFIGURED. Nobody can sign in, and the login page names what is
  #     missing. It fails closed on purpose: once a deployment has said it wants
  #     a wall, a typo must not quietly leave the UI open.
  #
  # ## Reads are cached per process
  #
  # The gate asks on every web request, so the answer is memoized for
  # CACHE_TTL. A store that cannot be reached keeps the last answer this
  # process saw. A process that has never seen one raises Unavailable, and the
  # gate answers 503 rather than guess whether the wall should be up.
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

    class Unavailable < StandardError; end

    class << self
      # @return [WebAuth::Configuration]
      # @raise [Unavailable] when the store has never answered this process
      def current
        mutex.synchronize do
          if @cached.nil? || monotonic_now - @cached_at >= CACHE_TTL.to_i
            begin
              @cached = new(VARIABLES.index_with { |name| SecretProviders.chain.get(name) })
              @cached_at = monotonic_now
            rescue StandardError => e
              Rails.logger.warn("[web_auth] configuration read failed: #{e.class}: #{e.message}")
              raise Unavailable, "the secret store did not answer (#{e.class})" if @cached.nil?

              # Keep serving the last answer, and try again after the TTL.
              @cached_at = monotonic_now
            end
          end
          @cached
        end
      end

      # Tests and the catalog-refresh path drop the memo so the next read is fresh.
      def reset!
        mutex.synchronize { @cached = nil }
      end

      private

      def mutex = (@mutex ||= Mutex.new)

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # @param values [Hash{String => String, nil}] variable name -> resolved value
    def initialize(values)
      @values = values.transform_values { |v| v.to_s.strip.presence }
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
      problems << "#{CLIENT_SECRET} is not set" if client_secret.blank?
      problems << "#{ALLOWED_DOMAINS} names no domain" if allowed_domains.empty?
      if @values[SECOND_FACTOR] && !SECOND_FACTOR_MODES.include?(@values[SECOND_FACTOR].downcase)
        problems << "#{SECOND_FACTOR} must be one of #{SECOND_FACTOR_MODES.join(", ")}"
      end
      problems
    end

    def usable? = enabled? && problems.empty?

    def second_factor_mode = (@values[SECOND_FACTOR] || "totp").downcase

    def totp_required? = second_factor_mode == "totp"

    def session_ttl = positive_days(SESSION_DAYS, DEFAULT_SESSION_DAYS)

    def trusted_device_ttl = positive_days(TRUSTED_DEVICE_DAYS, DEFAULT_TRUSTED_DEVICE_DAYS)

    # Any second factor confirmed before this instant is void: its owner sets up
    # a new one at their next sign-in. The recovery path for a lost authenticator
    # and lost recovery codes, reachable with a secret-store write and no shell.
    # Safe to leave set: an enrollment made after it is unaffected.
    #
    # @return [Time, nil]
    def second_factor_reset_before
      raw = @values[SECOND_FACTOR_RESET_BEFORE]
      return nil if raw.blank?

      Time.iso8601(raw)
    rescue ArgumentError
      Rails.logger.warn("[web_auth] ignoring #{SECOND_FACTOR_RESET_BEFORE}=#{raw.inspect}: not an ISO 8601 time")
      nil
    end

    # Where Google sends the browser back. Must be registered, exactly, on the
    # Google Cloud OAuth client.
    def redirect_uri
      "#{AppUrl.base_url}/auth/google/callback"
    end

    private

    def positive_days(name, default)
      days = Integer(@values[name] || default, exception: false)
      (days && days.positive? ? days : default).days
    end
  end
end
