# frozen_string_literal: true

# The "Provenance context on demand" experiment is over, and the answer was "go
# further": a session's provenance — its lineage graph and the human-message
# record — is no longer injected into a turn at all, in either shape. It is
# served by the `get_session_provenance` MCP tool, whose description carries the
# caveats the injected blocks used to state.
#
# Both branches of the switch are gone, so the column goes with them. The
# `session_experimental_flags` rows written under `provenance_via_mcp` are left
# in place: they honestly record what those sessions ran under, and the Costs
# page simply stops rendering a section for a key the registry no longer knows.
class RemoveProvenanceViaMcpEnabledFromAppSettings < ActiveRecord::Migration[8.0]
  def change
    remove_column :app_settings, :provenance_via_mcp_enabled, :boolean, default: true, null: false
  end
end
