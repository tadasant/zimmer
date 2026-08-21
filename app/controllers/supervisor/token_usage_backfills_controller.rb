# frozen_string_literal: true

module Supervisor
  class TokenUsageBackfillsController < Supervisor::ApplicationController
    # One row per sweep of the transcript corpus into the token-spend ledger.
    # Browsing them answers "when was history last swept, how far did it get, and
    # did it stop on an error" without a shell on the box — the same question the
    # Costs page's coverage panel answers, at row level.
  end
end
