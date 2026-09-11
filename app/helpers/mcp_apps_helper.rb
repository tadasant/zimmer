# frozen_string_literal: true

# View-side glue for MCP App panels. The decisions all live in McpApps; this is
# where the timeline reaches them without paying for them once per row.
module McpAppsHelper
  # One trigger per session per render. The trigger is what memoizes the settings
  # read and the per-server tool index; building a new one per row would defeat it.
  #
  # @param session [Session, nil]
  # @return [McpApps::TimelineTrigger]
  def mcp_apps_trigger(session)
    @mcp_apps_triggers ||= {}
    @mcp_apps_triggers[session&.id] ||= McpApps::TimelineTrigger.new(session)
  end

  # The frame id both ends of the lazy load have to agree on. A runtime's
  # tool-call id is not guaranteed to be a legal DOM id, so it is folded into one
  # the same way on both sides rather than interpolated raw.
  #
  # @param tool_call_id [String]
  # @return [String]
  def mcp_app_frame_id(tool_call_id)
    "mcp_app_#{tool_call_id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')}"
  end

  # `hostContext.styles.variables` — Zimmer's own palette, in the spec's
  # standardized CSS variable names, so a well-written fragment renders as part
  # of this page rather than as a foreign card dropped onto it. A fragment is
  # free to ignore them; nothing depends on it reading any of these.
  #
  # @return [Hash]
  def mcp_app_host_styles
    {
      variables: {
        "--color-background-primary" => "#ffffff",
        "--color-background-secondary" => "#f9fafb",
        "--color-background-tertiary" => "#f3f4f6",
        "--color-text-primary" => "#111827",
        "--color-text-secondary" => "#4b5563",
        "--color-text-tertiary" => "#6b7280",
        "--color-border-primary" => "#e5e7eb",
        "--color-border-secondary" => "#f3f4f6",
        "--color-ring-primary" => "#6366f1",
        "--font-sans" => "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif",
        "--font-mono" => "ui-monospace, SFMono-Regular, Menlo, monospace"
      }
    }
  end
end
