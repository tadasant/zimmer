module ApplicationCable
  # ActionCable accepts a WebSocket upgrade when Origin equals "#{proto}://#{Host}", taking
  # proto from Rack::Request#ssl? (ActionCable::Connection::Base#allow_request_origin?).
  #
  # Zimmer's droplets answer on plain HTTP — compose publishes port 80, the DigitalOcean
  # firewall drops it at the edge, and the app is reached over the Tailscale tunnel by its
  # MagicDNS name — yet production and staging set `config.assume_ssl`, whose middleware marks
  # every request as TLS-terminated. So ssl? is true for a request that arrived over http://,
  # ActionCable expects an https:// origin, and the app rejects its own clients.
  #
  # Matching the origin's host and port against the Host header, and ignoring the scheme,
  # restores ActionCable's same-origin-as-host semantics for a deployment that has no TLS.
  # It admits nothing a plain-HTTP Rails app would not already admit, but note what that
  # baseline is worth: same-origin-as-host trusts the Host header, and this app leaves
  # `config.hosts` empty, so HostAuthorization does not constrain it. A cable connection
  # carries no identity (no `identified_by`) and Turbo's streams require an HMAC-signed
  # stream name, so an origin that slipped through would gain an anonymous socket and no
  # data. Setting `config.hosts` is the proper complement — see
  # https://github.com/tadasant/zimmer/issues/24.
  #
  # Every other origin still falls through to ActionCable's own check, which honors
  # `allowed_request_origins` and logs the rejection.
  class Connection < ActionCable::Connection::Base
    ORIGIN_SCHEMES = %w[http https].freeze

    private
      def allow_request_origin?
        same_host_origin? || super
      end

      def same_host_origin?
        return false unless server.config.allow_same_origin_as_host

        origin = parsed_origin
        return false unless origin

        host, port = requested_host_and_port
        return false unless host

        origin.hostname.downcase == host && origin.port == (port || origin.default_port)
      end

      # URI#hostname unwraps IPv6 brackets and drops any userinfo, so "http://zimmer@evil.com"
      # resolves to evil.com rather than zimmer.
      def parsed_origin
        origin = env["HTTP_ORIGIN"].presence
        return unless origin

        uri = URI.parse(origin)
        uri if ORIGIN_SCHEMES.include?(uri.scheme) && uri.hostname.present?
      rescue URI::InvalidURIError
        nil
      end

      # "zimmer", "zimmer:3000" and "[::1]:3000" are all valid Host headers. Rack::Request#port
      # is no help here: with no port in the Host header it derives one from the scheme, which
      # assume_ssl has already falsified to 443.
      def requested_host_and_port
        host = env["HTTP_HOST"].presence
        return unless host

        match = host.match(/\A(?<host>\[[^\]]+\]|[^:]+)(?::(?<port>\d+))?\z/)
        return unless match

        [ match[:host].downcase.delete_prefix("[").delete_suffix("]"), match[:port]&.to_i ]
      end
  end
end
