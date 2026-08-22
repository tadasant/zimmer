# frozen_string_literal: true

module Supervisor
  class TokenUsageFeaturesController < Supervisor::ApplicationController
    # One row per (API call, context-management feature): the estimated share of a
    # request's tokens that the injected goal block, a skill body, an MCP response
    # or the harness's own machinery accounted for. Browsing them is how you check
    # a figure on the Costs page against the request it came from — which matters
    # more here than for the usage tables, because these numbers are estimates
    # rather than measurements.
  end
end
