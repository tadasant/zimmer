# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"

module OauthServer
  # Client ID Metadata Documents (draft-ietf-oauth-client-id-metadata-document,
  # adopted by the MCP authorization spec): a client whose `client_id` is an
  # HTTPS URL is described by the JSON document at that URL. Claude.ai's is
  # `https://claude.ai/oauth/mcp-oauth-client-metadata`.
  #
  # Fetching a URL a stranger chose is SSRF-shaped, so the fetch is held tight:
  #
  # - the URL must be https, already in normal form, with a path, and no
  #   userinfo, fragment or dot segments;
  # - every address the host resolves to must be public, and the connection is
  #   made to the address that was checked (no second lookup to rebind);
  # - no redirects are followed, the body is capped at 5 KiB, and every phase has
  #   a timeout;
  # - nothing the document points at (logo, jwks, client_uri) is ever fetched.
  #
  # A valid document is cached on its OauthServer::Client row for its
  # `Cache-Control: max-age` (at most an hour; five minutes when it says
  # nothing). A failure is never cached.
  class ClientMetadataDocument
    MAX_URL_LENGTH = 1024
    MAX_BODY_BYTES = 5 * 1024
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3
    DEFAULT_TTL = 5.minutes
    MAX_TTL = 1.hour
    USER_AGENT = "Zimmer (OAuth client metadata fetch)"

    # IPv4 ranges that are not the public internet (RFC 6890 and friends).
    BLOCKED_V4 = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.31.196.0/24 192.52.193.0/24 192.88.99.0/24
      192.168.0.0/16 192.175.48.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
      224.0.0.0/4 240.0.0.0/4
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # IPv6 is an allowlist: global unicast, minus the special-purpose blocks inside it.
    GLOBAL_V6 = IPAddr.new("2000::/3")
    BLOCKED_V6 = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].map { |cidr| IPAddr.new(cidr) }.freeze

    # Does this client_id name a metadata document rather than a DCR registration?
    # Zimmer's own client ids never contain a colon.
    def self.url_client_id?(client_id)
      client_id.to_s.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
    end

    # Why this client_id cannot be a metadata-document URL, or nil.
    def self.url_problem(client_id)
      return "is too long" if client_id.length > MAX_URL_LENGTH

      uri = URI.parse(client_id)
      return "must be an https URL" unless uri.scheme == "https"
      return "must name a host" if uri.host.blank?
      return "must not carry userinfo" if uri.userinfo
      return "must not carry a fragment" if client_id.include?("#")
      return "must have a path" if uri.path.blank? || uri.path == "/"
      return "must not contain dot path segments" if uri.path.split("/").intersect?([ ".", ".." ])
      return "must be in normal form (lowercase host, no default port)" unless normalized?(uri, client_id)

      ip = ip_literal(uri.host)
      return "must not name a non-public address" if ip && !public_address?(ip)

      nil
    rescue URI::InvalidURIError
      "is not a valid URL"
    end

    def self.normalized?(uri, raw)
      uri.host == uri.host.downcase && !raw.match?(%r{\Ahttps://[^/]+:443(/|\z)}i)
    end

    def self.ip_literal(host)
      IPAddr.new(host.delete_prefix("[").delete_suffix("]"))
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    def self.public_address?(ip)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      if ip.ipv4?
        BLOCKED_V4.none? { |range| range.include?(ip) }
      else
        GLOBAL_V6.include?(ip) && BLOCKED_V6.none? { |range| range.include?(ip) }
      end
    end

    # The client for this URL client_id: the cached row while it is fresh,
    # otherwise a fresh fetch and validation, written back to the row.
    #
    # @raise [OauthServer::Error] `invalid_client` when the URL, the fetch or the document fails
    # @return [OauthServer::Client]
    def self.resolve!(client_id)
      problem = url_problem(client_id)
      raise Error.new("invalid_client", "client_id #{problem}") if problem

      client = Client.find_by(client_id: client_id)
      return client if client && client.cimd? && !client.metadata_stale?

      new(client_id).fetch_into!(client)
    end

    def initialize(client_id)
      @client_id = client_id
      @uri = URI.parse(client_id)
    end

    def fetch_into!(client)
      body, max_age = fetch
      doc = parse_json(body)

      unless doc["client_id"] == @client_id
        raise Error.new("invalid_client", "the metadata document's client_id does not equal the URL it was fetched from")
      end

      parsed = ClientMetadata.parse!(doc, error_code: "invalid_client")
      client ||= Client.new(client_id: @client_id)
      client.assign_attributes(
        registration_type: Client::CIMD,
        client_name: parsed.client_name,
        client_uri: parsed.client_uri,
        redirect_uris: parsed.redirect_uris,
        grant_types: parsed.grant_types,
        metadata_expires_at: Time.current + max_age
      )
      client.save!
      client
    rescue ActiveRecord::RecordNotUnique
      Client.find_by!(client_id: @client_id)
    end

    private

    def fetch
      address = vetted_address
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.ipaddr = address
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.ssl_timeout = OPEN_TIMEOUT
      http.write_timeout = READ_TIMEOUT
      http.keep_alive_timeout = 0

      request = Net::HTTP::Get.new(@uri.request_uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = USER_AGENT

      body = +""
      max_age = nil
      http.start do
        http.request(request) do |response|
          unless response.code == "200"
            raise fetch_error("answered #{response.code}#{' (redirects are not followed)' if response.is_a?(Net::HTTPRedirection)}")
          end
          unless json_content_type?(response["Content-Type"])
            raise fetch_error("answered with Content-Type #{response['Content-Type'].inspect}, not JSON")
          end

          max_age = ttl_from(response["Cache-Control"])
          response.read_body do |chunk|
            body << chunk
            raise fetch_error("is larger than #{MAX_BODY_BYTES} bytes") if body.bytesize > MAX_BODY_BYTES
          end
        end
      end

      [ body, max_age ]
    rescue Error
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise fetch_error("did not answer in time")
    rescue OpenSSL::SSL::SSLError, SystemCallError, SocketError, IOError, Net::HTTPBadResponse, EOFError => e
      raise fetch_error("could not be fetched (#{e.class})")
    end

    # Resolve the host and refuse unless EVERY address is public. The connection
    # then dials the first of them directly, so the name cannot resolve
    # differently between the check and the connect.
    def vetted_address
      literal = self.class.ip_literal(@uri.host)
      addresses = literal ? [ literal ] : resolve(@uri.host)
      raise fetch_error("host did not resolve") if addresses.empty?
      raise fetch_error("host resolves to a non-public address") unless addresses.all? { |ip| self.class.public_address?(ip) }

      addresses.first.to_s
    end

    def resolve(host)
      Resolv::DNS.open do |dns|
        dns.timeouts = OPEN_TIMEOUT
        (dns.getresources(host, Resolv::DNS::Resource::IN::A) +
          dns.getresources(host, Resolv::DNS::Resource::IN::AAAA)).map { |record| IPAddr.new(record.address.to_s) }
      end
    rescue Resolv::ResolvError, IPAddr::InvalidAddressError
      []
    end

    def json_content_type?(value)
      media = value.to_s.split(";").first.to_s.strip.downcase
      media == "application/json" || media.match?(%r{\Aapplication/[a-z0-9.+-]+\+json\z})
    end

    def ttl_from(cache_control)
      directives = cache_control.to_s.downcase.split(",").map(&:strip)
      return 0.seconds if directives.intersect?(%w[no-store no-cache])

      max_age = directives.find { |d| d.start_with?("max-age=") }
      return DEFAULT_TTL if max_age.nil?

      seconds = Integer(max_age.delete_prefix("max-age="), exception: false) || 0
      [ [ seconds, 0 ].max.seconds, MAX_TTL ].min
    end

    def parse_json(body)
      doc = JSON.parse(body)
      raise Error.new("invalid_client", "the client metadata document is not a JSON object") unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError
      raise Error.new("invalid_client", "the client metadata document is not valid JSON")
    end

    def fetch_error(what)
      Error.new("invalid_client", "the client metadata document at #{@uri.host} #{what}")
    end
  end
end
