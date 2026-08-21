# frozen_string_literal: true

module OutcomeAnalyses
  # The three catalog artifacts an analysis session is assembled from, in one
  # place so none of them is a literal scattered through the code.
  #
  # The skill is the one that matters: `analyze-transcript-outcomes` is authored
  # in the AIR catalog, not here, and Session validates catalog_skills against
  # the catalog at creation time. So Zimmer treats it as a name it *hopes* to
  # find — `analyzer_skills` drops it when the catalog does not have it yet, and
  # the Outcomes ledger says so in a banner rather than failing every Analyze
  # click with a validation error. Each value can be overridden by environment
  # variable for a deployment whose catalog names them differently.
  module Config
    module_function

    # The catalog skill that teaches a session how to decompose a transcript and
    # classify each Segment's outcome.
    def skill_id
      ENV.fetch("OUTCOME_ANALYSIS_SKILL_ID", "analyze-transcript-outcomes")
    end

    # The least-privileged MCP server that carries `save_outcome_analysis`. The
    # tool lives in the `sessions` tool group, which is exactly what this server
    # is scoped to (`/mcp?tool_groups=sessions`).
    def mcp_server_name
      ENV.fetch("OUTCOME_ANALYSIS_MCP_SERVER", "zimmer-sessions")
    end

    # Analysis reads a transcript over MCP; it does not need the analyzed
    # session's repository. The generic root keeps the clone small and keeps
    # these sessions out of any product root's lane.
    def agent_root
      ENV.fetch("OUTCOME_ANALYSIS_AGENT_ROOT", "general-agent")
    end

    def skill_available?
      SkillsConfig.exists?(skill_id)
    rescue StandardError => e
      Rails.logger.warn("[OutcomeAnalyses] Could not resolve skill #{skill_id}: #{e.class}: #{e.message}")
      false
    end

    def mcp_server_available?
      ServersConfig.exists?(mcp_server_name)
    rescue StandardError => e
      Rails.logger.warn("[OutcomeAnalyses] Could not resolve MCP server #{mcp_server_name}: #{e.class}: #{e.message}")
      false
    end

    def agent_root_available?
      AgentRootsConfig.find(agent_root).present?
    rescue StandardError
      false
    end

    # Reasons an Analyze click cannot produce a usable analysis session, in prose
    # the ledger renders directly. Empty means everything resolved.
    def unavailable_reasons
      reasons = []
      unless agent_root_available?
        reasons << "Agent root \"#{agent_root}\" is not in the catalog — analysis sessions cannot be spawned."
      end
      unless mcp_server_available?
        reasons << "MCP server \"#{mcp_server_name}\" is not in the catalog — spawned sessions will have no way to save their analysis."
      end
      unless skill_available?
        reasons << "Skill \"#{skill_id}\" is not in the catalog yet. Analyses still spawn, and the prompt carries the full contract, " \
                   "but the session runs without the skill's guidance until the catalog entry lands."
      end
      reasons
    end
  end
end
