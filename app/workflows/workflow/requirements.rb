# frozen_string_literal: true

module Workflow
  # What a workflow's runs need from the catalog — ApplicationWorkflow.requires
  # builds one. Every field is a catalog NAME, never a credential: the
  # orchestrator turns names into equipment at spawn, as it does for a trigger's
  # own columns.
  class Requirements < Data.define(:agent_root, :mcp_servers, :skills, :goal)
    def initialize(agent_root: nil, mcp_servers: [], skills: [], goal: nil)
      super(
        agent_root: agent_root&.to_s.presence,
        mcp_servers: Array(mcp_servers).map(&:to_s).freeze,
        skills: Array(skills).map(&:to_s).freeze,
        goal: goal&.to_s.presence
      )
    end

    # Every declared name the catalog cannot resolve, one readable line each.
    # Empty is the only acceptable answer for a registered workflow, and
    # test/workflows/workflow_catalog_references_test.rb holds every one to it —
    # so a PR that removes a catalog entry a workflow needs fails CI, instead of a
    # fire healing around it in production.
    #
    # @return [Array<String>]
    def unresolved_catalog_references
      unresolved = []
      unresolved << "agent root #{agent_root.inspect}" if agent_root && !AgentRootsConfig.exists?(agent_root)
      unresolved.concat(mcp_servers.reject { |server| ServersConfig.exists?(server) }.map { |server| "MCP server #{server.inspect}" })
      unresolved.concat(skills.reject { |skill| SkillsConfig.exists?(skill) }.map { |skill| "skill #{skill.inspect}" })
      unresolved << "goal #{goal.inspect}" if goal && !GoalsConfig.exists?(goal)
      unresolved
    end

    # What a session running this workflow in `root` is equipped with, as the
    # keywords Session.create_from_agent_root! takes.
    #
    # A UNION with the root's defaults, not an override: the root's baseline plus
    # what the procedure additionally needs. That is the safe default and an open
    # question on #18 — a workflow that wants a narrower surface than its root
    # cannot have one. Hooks and plugins are not declarable, so they stay the
    # root's defaults. The goal is passed as its catalog id, which AgentSessionJob
    # resolves to the goal's text at spawn.
    #
    # @param root [AgentRootsConfig::AgentRoot]
    # @return [Hash]
    def session_equipment(root)
      {
        mcp_servers: ((root.default_mcp_servers || []) + mcp_servers).uniq,
        catalog_skills: ((root.default_skills || []) + skills).uniq,
        goal: goal
      }
    end
  end
end
