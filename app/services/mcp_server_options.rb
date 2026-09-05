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
#
# What it costs: one `ConnectorStatusProbe.all` per call — no network call to
# any MCP server, one indexed credential lookup per OAuth-capable entry, and
# secret resolution through the provider chain, which holds a 60-second
# namespace snapshot. Measured at ~14ms warm for an 18-server catalog. Callers
# that render more than one picker in a request should call this once and pass
# the result down rather than calling it per picker.
class McpServerOptions
  # Every catalog server as a select-list option.
  #
  # @return [Array<Hash>] `{name:, title:, description:, unavailable:, unavailable_reason:}`
  def self.all
    ConnectorStatusProbe.all.map { |status| option(status.server, status) }
  rescue => e
    # A picker that cannot be built is far worse than one without availability
    # flags: the form would offer nothing at all. Individual bad entries already
    # degrade to :probe_failed inside the probe, so reaching here means the whole
    # computation failed — fall back to the catalog and say nothing about
    # availability rather than claiming everything is broken.
    Rails.logger.warn "[McpServerOptions] availability unavailable, falling back to catalog: #{e.class}: #{e.message}"
    ServersConfig.all.map { |server| option(server, nil) }
  end

  # @param server [ServersConfig::Server]
  # @param status [ConnectorStatusProbe::Status, nil]
  # @return [Hash]
  def self.option(server, status)
    {
      name: server.name,
      title: server.title,
      description: server.description,
      unavailable: status ? !status.available? : false,
      unavailable_reason: status&.available? == false ? status.unavailable_reason(markdown: false) : nil
    }
  end
  private_class_method :option
end
