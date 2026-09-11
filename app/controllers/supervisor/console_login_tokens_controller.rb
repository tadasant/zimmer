# frozen_string_literal: true

module Supervisor
  class ConsoleLoginTokensController < Supervisor::ApplicationController
    # The console_login_tokens table as rows: who was minted a login, whether it
    # was exchanged, from where. Minting and revoking happen on
    # POST /console_login_tokens; this is the generic read-only view every table gets.
    private

    def default_sorting_attribute = :created_at

    def default_sorting_direction = :desc
  end
end
