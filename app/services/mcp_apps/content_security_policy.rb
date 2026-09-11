# frozen_string_literal: true

module McpApps
  # The Content-Security-Policy header served with a fragment, derived from what
  # the fragment's own resource declared in `_meta.ui.csp`.
  #
  # The spec gives a resource four lists, each naming origins it needs for one
  # purpose: `connectDomains` (fetch/XHR/WebSocket), `resourceDomains` (scripts,
  # styles, images, fonts, media), `frameDomains` (nested iframes) and
  # `baseUriDomains` (`<base href>`). A host is expected to turn those into a
  # policy and to apply a restrictive one when the resource declares nothing.
  #
  # Three things about this implementation are deliberate and are the reason it is
  # a header rather than a `<meta>` tag or an iframe attribute:
  #
  # **It is a response header.** The spike rendered the fragment with `srcdoc`,
  # which makes the document inherit the *parent* page's policy — Zimmer's — so
  # there was no place to put a fragment-specific one. Serving the fragment from
  # its own endpoint is what makes a per-fragment policy possible at all.
  #
  # **`sandbox` is in the policy, not only on the iframe.** The `sandbox`
  # attribute is applied by the embedder, so it protects the framed case and
  # nothing else: a URL that serves third-party HTML is a same-origin script
  # execution primitive the moment somebody opens it directly. The CSP `sandbox`
  # directive is applied by the document itself, however it was loaded, and puts
  # it in an opaque origin either way. That is what makes "separate origin" true
  # rather than merely intended.
  #
  # **Nothing is allowed that was not asked for.** `default-src 'none'` is the
  # base, and each directive is widened only by the list that names it. A
  # resource with no `csp` metadata gets inline script and style (a fragment with
  # no inline script is not a fragment) plus `data:` images, and no network of any
  # kind.
  class ContentSecurityPolicy
    # Schemes an origin entry may use. Anything else in the list is dropped: a
    # `javascript:` or `data:` entry in `connectDomains` is not an origin, and a
    # scheme-relative `//evil.example` would widen the policy to both schemes.
    ALLOWED_SCHEMES = %w[https:// http://].freeze

    # A cap on how much the resource may widen its own policy. The number is not
    # load-bearing for security — every entry is already an origin the operator's
    # allowlisted server chose — but an unbounded list would let a server write a
    # response header of arbitrary size through Zimmer.
    MAX_DOMAINS_PER_DIRECTIVE = 32

    # What the iframe is allowed to do, in both the header directive and the
    # element attribute.
    #
    # One token. No `allow-same-origin`, which is the token that would collapse
    # the opaque origin back into Zimmer's and hand the fragment
    # `document.cookie` plus a same-origin `fetch` of every page in this app. No
    # `allow-popups` or `allow-forms` either: a view opens a link by asking the
    # host to (`ui/open-link`, which Zimmer answers with a marked-up
    # `noopener,noreferrer` window), and `form-action 'none'` below already means
    # a form has nowhere to submit to. Scripting is the only capability a
    # fragment genuinely needs, because scripting is what a fragment IS.
    SANDBOX_TOKENS = %w[allow-scripts].freeze

    attr_reader :csp

    # @param csp [Hash, nil] the resource's `_meta.ui.csp`
    def initialize(csp)
      @csp = csp.is_a?(Hash) ? csp : {}
    end

    # @return [String] the value for the `Content-Security-Policy` header
    def header_value
      directives.map { |name, sources| "#{name} #{sources.join(' ')}" }.join("; ")
    end

    # The `sandbox` attribute for the embedding iframe. Identical to the header's
    # sandbox tokens by construction — two spellings of one decision.
    #
    # @return [String]
    def self.iframe_sandbox
      SANDBOX_TOKENS.join(" ")
    end

    private

    def directives
      {
        "default-src" => %w['none'],
        # Inline script and style are the fragment itself; `unsafe-eval` is not
        # granted, so a fragment cannot build code from a string it was handed.
        "script-src" => [ "'unsafe-inline'", *resource_domains ],
        "style-src" => [ "'unsafe-inline'", *resource_domains ],
        "img-src" => [ "data:", "blob:", *resource_domains ],
        "font-src" => [ "data:", *resource_domains ],
        "media-src" => [ "data:", "blob:", *resource_domains ],
        # The spec's own "block dangerous features" line. A plugin document is
        # not subject to script-src at all, so this is not covered by anything
        # above it.
        "object-src" => %w['none'],
        "connect-src" => connect_domains.presence || %w['none'],
        "frame-src" => frame_domains.presence || %w['none'],
        "child-src" => frame_domains.presence || %w['none'],
        # A form POST is a navigation, and a navigation out of the sandbox is the
        # one exfiltration channel `connect-src` does not cover.
        "form-action" => %w['none'],
        "base-uri" => base_uri_domains.presence || %w['none'],
        # The fragment is framed by Zimmer and by nobody else. Redundant with the
        # opaque origin for scripting purposes, and not redundant at all for
        # clickjacking a fragment that renders a real control.
        "frame-ancestors" => %w['self'],
        "sandbox" => SANDBOX_TOKENS
      }
    end

    def resource_domains = domains("resourceDomains")
    def connect_domains = domains("connectDomains")
    def frame_domains = domains("frameDomains")
    def base_uri_domains = domains("baseUriDomains")

    def domains(key)
      values = csp[key]
      return [] unless values.is_a?(Array)

      values.filter_map { |value| normalize_origin(value) }.uniq.first(MAX_DOMAINS_PER_DIRECTIVE)
    end

    # An entry has to be a plain `scheme://host[:port]` with no path, no
    # wildcard scheme and nothing that could terminate the directive it lands in.
    # `https://*.example.com` is accepted — a host wildcard is legal CSP and is
    # how a CDN is named.
    def normalize_origin(value)
      origin = value.to_s.strip
      return nil if origin.empty?
      # A URL scheme is case-insensitive, so `HTTPS://cdn.example.com` is a legal
      # thing for a server to write — and dropping it silently renders the view
      # blank rather than wrong, which is the harder failure to diagnose.
      return nil unless ALLOWED_SCHEMES.any? { |scheme| origin.downcase.start_with?(scheme) }
      return nil if origin.match?(/[\s;,'"]/)

      host = origin.split("//", 2).last.to_s
      return nil if host.empty?
      return nil if host.include?("/")
      return nil unless host.match?(/\A(?:\*\.)?[A-Za-z0-9.\-]+(?::\d+)?\z/)

      origin
    end
  end
end
