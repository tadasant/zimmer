# frozen_string_literal: true

# The MCP-server list Zimmer's human-facing surfaces offer, carrying the one
# thing the catalog alone cannot say: whether Zimmer can actually start each
# server right now.
#
# Every picker and every REST list used to build its own `{name, title,
# description}` from `ServersConfig.all`, which meant offering a server whose
# `${VAR}` does not resolve as though it were as good as any other. It is not:
# `SecretsInterpolator::MissingVariableError` raises at prepare time and is not
# rescued per entry, so attaching one fails the *whole session*, not just that
# server. `get_configs` already refuses to hand an agent such a server; this is
# the same signal, for the surfaces a human reads.
#
# The readiness computation is `ConnectorStatusProbe`'s — the same one the
# Connectors page renders and `get_configs` partitions on, so the three cannot
# drift. In particular `Status#available?` is deliberately generous about the
# states that mean "Zimmer could not find out" (`:store_unavailable`,
# `:probe_failed`): they report as available, because flagging a working server
# as broken during a secret-store blip is the more expensive mistake.
class McpServerOptions
  # One probe per request (and per job), not one per caller.
  #
  # A single `PATCH /sessions/:id/mcp_servers` reaches this three times: the
  # `after_update_commit` broadcast rebuilds the metadata partial's locals, the
  # OAuth branch can park the session and rebuild them again, and the action then
  # renders its own turbo-stream locals. `ActiveSupport::CurrentAttributes` is
  # reset by the executor around every request and every job, so this is a memo
  # with exactly request lifetime — it cannot serve a caller a readiness answer
  # computed for some earlier request, which is what a TTL cache would do.
  #
  # Deliberately not a longer-lived cache. The staleness would land on the one
  # signal whose freshness is the point: someone who has just authorized a
  # connector at /connectors and come back to the form must not be told it is
  # still broken.
  class Cache < ActiveSupport::CurrentAttributes
    attribute :options
  end

  # Every catalog server as a select-list option.
  #
  # What it costs, once per request: no network call to any MCP server, one
  # indexed credential lookup per OAuth-capable entry, and secret resolution
  # through the provider chain, which holds a 60-second namespace snapshot.
  # Measured at ~50ms cold and ~14ms warm for an 18-server catalog, in 2 queries.
  #
  # @return [Array<Hash>] `{name:, title:, scope:, description:, unavailable:, unavailable_reason:, startup_timeout_sec:}`
  def self.all
    Cache.options ||= build
  end

  # @return [Array<Hash>]
  def self.build
    ConnectorStatusProbe.all.map { |status| option(status.server, status) }
  rescue => e
    # A picker that cannot be built is far worse than one without availability
    # flags: the form would offer no servers at all, which reads as an empty
    # catalog. Individual bad entries already degrade to :probe_failed inside the
    # probe, so reaching here means the shared setup failed — say nothing about
    # availability rather than claiming everything is broken.
    #
    # Narrow on purpose: a catalog that will not resolve raises in
    # `ServersConfig.all`, which the fallback calls too, so that case still
    # surfaces rather than being swallowed into a silently flagless list. What
    # this covers is the probe's own shared setup and anything unexpected above
    # the per-server rescue.
    Rails.logger.warn "[McpServerOptions] availability unavailable, falling back to catalog: #{e.class}: #{e.message}"
    ErrorReporter.report_exception(e, context: { service: "McpServerOptions" })
    ServersConfig.all.map { |server| option(server, nil) }
  end
  private_class_method :build

  # @param server [ServersConfig::Server]
  # @param status [ConnectorStatusProbe::Status, nil]
  # @return [Hash]
  def self.option(server, status)
    unavailable = status ? !status.available? : false
    {
      name: server.name,
      title: server.title,
      # Which catalog contributed this entry, and only when a second one
      # contributes the same short id. Populated exactly when `name` has had to
      # become the qualified `@scope/id`, which is when two rows in a picker
      # would otherwise both read "Slack" — see ArtifactIdentity. nil on a
      # single-catalog deployment, so nothing renders a badge today.
      scope: server.contested? ? server.scope : nil,
      description: server.description,
      unavailable: unavailable,
      unavailable_reason: unavailable ? status.unavailable_reason(markdown: false) : nil,
      # The startup budget this entry declares for itself, or nil when it
      # declares none and McpStartupTimeout::SECONDS applies. Carried here
      # because it is otherwise invisible: the value is authored in the catalog
      # repository, a declared one Zimmer refuses is only a log line, and the
      # config file it lands in sits in a session clone nobody can reach without
      # a shell. This list is rendered by /api/v1/configs and /api/v1/mcp_servers,
      # so "did my number take effect" has an answer that needs no box access.
      startup_timeout_sec: server.startup_timeout_seconds
    }
  end
  private_class_method :option
end
