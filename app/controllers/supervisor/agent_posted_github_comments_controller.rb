# frozen_string_literal: true

module Supervisor
  class AgentPostedGithubCommentsController < Supervisor::ApplicationController
    # Records of the GitHub comments Zimmer's own sessions posted, as observed in
    # their transcripts. Browsing them answers "why didn't that comment wake the
    # session" — the poller's counterpart to this is the comment's `dispatch_state`
    # in custom_metadata.
  end
end
