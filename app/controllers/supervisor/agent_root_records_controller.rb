# frozen_string_literal: true

module Supervisor
  class AgentRootRecordsController < Supervisor::ApplicationController
    # Every agent root's persistent records, across namespaces. Index and show
    # only: writes go through RootData::Store (the `root_data` MCP tools), which
    # enforces the caps and keeps the counters in step.
  end
end
