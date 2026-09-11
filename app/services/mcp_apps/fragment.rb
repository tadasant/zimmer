# frozen_string_literal: true

module McpApps
  # One `ui://` fragment: the HTML a view is, plus the CSP its resource declared.
  #
  # `Fragment.for` is the read path. It is the ONLY call this feature makes on the
  # way to a first render, it is read-only (`resources/read`), and it is cached —
  # a view is a static document that changes when the server ships a new one, not
  # per tool call, so re-reading it for every panel would be a request per row.
  class Fragment
    class UnavailableError < StandardError; end

    TTL = 5.minutes

    # A view is a document. Anything an order of magnitude past a large one is a
    # server misbehaving, and it would be inlined into a response either way.
    MAX_HTML_BYTES = 1024 * 1024

    attr_reader :uri, :html, :csp, :mime_type

    def initialize(uri:, html:, csp: {}, mime_type: nil)
      @uri = uri
      @html = html
      @csp = csp
      @mime_type = mime_type
    end

    # @return [McpApps::ContentSecurityPolicy]
    def content_security_policy
      @content_security_policy ||= ContentSecurityPolicy.new(csp)
    end

    class << self
      # Read a fragment from the server the session is attached to.
      #
      # @param connection [McpApps::ServerConnection]
      # @param uri [String] a `ui://` resource URI
      # @raise [UnavailableError] when the server did not return a usable view
      # @return [Fragment]
      def for(connection, uri)
        unless uri.to_s.start_with?(McpApps::UI_SCHEME)
          raise UnavailableError, "#{uri.inspect} is not a ui:// resource"
        end

        payload = Rails.cache.fetch(cache_key(connection, uri), expires_in: TTL) do
          read(connection, uri)
        end

        new(uri: uri, html: payload["html"], csp: payload["csp"], mime_type: payload["mimeType"])
      end

      private

      def cache_key(connection, uri)
        [ "mcp_apps", "fragment", connection.server_name, Digest::SHA256.hexdigest(uri.to_s) ]
      end

      def read(connection, uri)
        client = connection.client
        result = client.resources_read(uri)
        content = Array(result["contents"]).find do |entry|
          entry.is_a?(Hash) && entry["text"].is_a?(String)
        end

        raise UnavailableError, "#{uri} returned no text content" if content.nil?

        html = content["text"]
        if html.bytesize > MAX_HTML_BYTES
          raise UnavailableError, "#{uri} is #{html.bytesize} bytes; the cap is #{MAX_HTML_BYTES}"
        end

        {
          "html" => html,
          "mimeType" => content["mimeType"],
          "csp" => csp_for(client, content, uri)
        }
      rescue Client::Error => e
        raise UnavailableError, e.message
      end

      # The CSP travels on the resource's `_meta`, and servers put it in one of
      # two places: on the content block `resources/read` returns, or only on the
      # resource's `resources/list` entry. Read the block first — it is already in
      # hand — and fall back to the listing, because a fragment whose declared
      # domains are missed does not render half-broken, it renders blank.
      def csp_for(client, content, uri)
        meta = McpApps.ui_meta(content)
        return meta["csp"] if meta["csp"].is_a?(Hash)

        listed = client.resources_list.find { |resource| resource.is_a?(Hash) && resource["uri"] == uri }
        csp = McpApps.ui_meta(listed)["csp"]
        csp.is_a?(Hash) ? csp : {}
      rescue Client::Error
        {}
      end
    end
  end
end
