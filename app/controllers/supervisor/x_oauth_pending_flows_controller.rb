# frozen_string_literal: true

module Supervisor
  # X consents in progress, for answering "is one open, for which credential, and
  # until when" without a shell. Flows are started and finished by
  # XOauthAuthorizationsController; here they can only be looked at or cancelled.
  class XOauthPendingFlowsController < Supervisor::ApplicationController
  end
end
