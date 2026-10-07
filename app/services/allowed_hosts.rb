# frozen_string_literal: true

require "ipaddr"
require "uri"
# Loaded by config/environments/*.rb before Zeitwerk is set up, so neither this
# file nor app_url.rb may reference another app constant at load time.
require_relative "app_url"

# The `Host` values production and staging answer to: `config.hosts`, which turns
# on Rails' HostAuthorization (DNS-rebinding and Host-header protection). Read
# once at boot from the process environment, because `config/environments/*.rb`
# runs before the secret store can be reached. So a base URL set only in the
# Parameter Store moves the links and the OAuth issuer but not this list; name
# that host in $ZIMMER_ALLOWED_HOSTS too. `/up` is excluded by the caller,
# so kamal-proxy's health gate never depends on this list.
#
# Every Host the deployment receives, and the entry that admits it:
#
#   https://<domain> (Cloudflare, the host Caddy :443,  the host of $ZIMMER_PROD_BASE_URL /
#     on-box agent sessions pinned to the domain)        $ZIMMER_STAGING_BASE_URL, and $APP_HOST
#   http://<tailnet-ip>/... (deploy health checks and   any IP literal, v4 or v6
#     smoke tests through Caddy :80)
#   http://<tailnet-hostname>/ over the tailnet          $ZIMMER_TAILNET_HOSTNAME, bare and as
#                                                        <name>.<tailnet>.ts.net, and <name>-N
#   curl localhost:8080 on the box                      localhost
#   anything else (a second public hostname)            $ZIMMER_ALLOWED_HOSTS, comma-separated;
#                                                        ".example.com" also admits subdomains
#
# An IP literal cannot be a DNS-rebinding target, and Cloudflare only routes
# hostnames it has a record for, so admitting every IP costs nothing the edge
# would otherwise stop.
#
# `ZIMMER_ALLOWED_HOSTS=*` turns the check off, the break-glass for a Host this
# list got wrong. So does a deployment that configured no hostname at all:
# enforcing an allow-list with no domain in it would refuse every real visitor.
module AllowedHosts
  module_function

  EXTRA_KEY = "ZIMMER_ALLOWED_HOSTS"
  TAILNET_HOSTNAME_KEY = "ZIMMER_TAILNET_HOSTNAME"
  ANY_IP = [ IPAddr.new("0.0.0.0/0"), IPAddr.new("::/0") ].freeze
  LABEL = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  # @param rails_env [String] which base-URL variable to read (AppUrl::BASE_URL_KEYS)
  # @param env [#[]] the process environment (injectable for testing)
  # @return [Array<String, Regexp, IPAddr>, nil] the `config.hosts` entries, or nil
  #   to leave HostAuthorization off
  def for(rails_env, env: ENV)
    extras = env[EXTRA_KEY].to_s.split(/[\s,]+/).map { |host| host.strip.downcase }.reject(&:empty?)
    return nil if extras.include?("*")

    named = [ host_of(env[AppUrl.base_url_key(rails_env)]), host_of(env["APP_HOST"], default_scheme: true) ]
    named = named.compact.reject { |host| AppUrl.placeholder?("https://#{host}") } + extras
    return nil if named.empty?

    (named + tailnet_hosts(env[TAILNET_HOSTNAME_KEY]) + [ "localhost" ]).uniq + ANY_IP
  end

  # The hostname of a URL ("https://zimmer.example.com") or, with `default_scheme`,
  # of a bare "host[:port]" ($APP_HOST). Nil when there is none.
  def host_of(value, default_scheme: false)
    value = value.to_s.strip
    return nil if value.empty?

    value = "http://#{value}" if default_scheme && !value.include?("://")
    URI.parse(value).host&.downcase.presence
  rescue URI::InvalidURIError
    nil
  end

  # MagicDNS answers to both the bare machine name and its tailnet FQDN, and
  # Tailscale names a rebuilt droplet `<name>-1` while the stale node still holds
  # `<name>`.
  def tailnet_hosts(name)
    name = name.to_s.strip.downcase
    return [] unless name.match?(LABEL)

    label = "#{Regexp.escape(name)}(?:-\\d+)?"
    [ name, /#{label}\.[a-z0-9-]+\.ts\.net/i, /#{label}/i ]
  end
end
