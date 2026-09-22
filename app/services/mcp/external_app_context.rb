# frozen_string_literal: true

module Mcp
  # The connection a Zimmer plugin's key opens on `POST /mcp/external_app`.
  #
  # Its tool list is fixed and does not come from Mcp::Registry at all: the
  # query string's `tool_groups` and `allowed_agent_roots` are never read, so no
  # URL can widen it. The plugin's two tools are not in Mcp::Registry::ALL_TOOLS
  # either, so no `/mcp` connection can register them — and each refuses to run
  # without an ExternalApp on its context.
  class ExternalAppContext < Context
    TOOLS = %w[
      Mcp::Tools::ExternalAppListTriggers
      Mcp::Tools::ExternalAppInvokeTrigger
    ].freeze

    attr_reader :external_app

    def initialize(external_app:, base_url: nil, caller_fingerprint: nil)
      raise ArgumentError, "an ExternalAppContext needs an ExternalApp" unless external_app.is_a?(ExternalApp)

      super(tool_groups: nil, base_url: base_url, caller_fingerprint: caller_fingerprint)
      @external_app = external_app
      @tool_groups = []
      @allowed_agent_roots = []
    end

    def tools
      @tools ||= TOOLS.map(&:constantize)
    end

    # Restricted to no agent root at all: nothing on this connection spawns by root.
    def restricted?
      true
    end
  end
end
