# frozen_string_literal: true

module Supervisor
  class SessionTokenUsagesController < Supervisor::ApplicationController
    # One row per Anthropic API call an agent session made, keyed on the API's own
    # `request_id`. Browsing them answers "what did this session actually spend, call
    # by call" — the row-level view behind the Costs page's rollups.
  end
end
