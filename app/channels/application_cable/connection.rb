module ApplicationCable
  # ActionCable rejects a WebSocket upgrade unless `Origin` equals "#{proto}://#{Host}",
  # where proto comes from Rack::Request#ssl? (ActionCable::Connection::Base#allow_request_origin?).
  #
  # Zimmer's droplets answer on plain HTTP: docker compose publishes port 80 and the
  # DigitalOcean firewall drops it at the edge, so the app is reached only over the Tailscale
  # tunnel by its MagicDNS name (http://zimmer). But production and staging also set
  # `config.assume_ssl`, whose middleware marks *every* request as TLS-terminated. So ssl?
  # is true, Rails expects "https://zimmer", the browser sends "http://zimmer", and the
  # upgrade is refused: Turbo Streams never connect and the JS consumer retries forever.
  #
  # Ignoring the scheme for the app's own host closes that gap without weakening cross-site
  # WebSocket hijacking protection: the origin's host and port must still equal the Host
  # header the request arrived on, so a third-party origin is never accepted — the only
  # origins newly admitted are the app's own, over the other scheme. Anything else still
  # falls through to ActionCable's check (including `allowed_request_origins`, and the
  # ERROR log on genuine rejections).
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

      def parsed_origin
        origin = env["HTTP_ORIGIN"].presence
        return unless origin

        uri = URI.parse(origin)
        uri if ORIGIN_SCHEMES.include?(uri.scheme) && uri.hostname.present?
      rescue URI::InvalidURIError
        nil
      end

      # "zimmer", "zimmer:3000" and "[::1]:3000" are all valid Host headers; URI#hostname
      # unwraps the brackets on the origin side, so unwrap them here too.
      def requested_host_and_port
        host = env["HTTP_HOST"].presence
        return unless host

        match = host.match(/\A(?<host>\[[^\]]+\]|[^:]+)(?::(?<port>\d+))?\z/)
        return unless match

        [ match[:host].downcase.delete_prefix("[").delete_suffix("]"), match[:port]&.to_i ]
      end
  end
end
