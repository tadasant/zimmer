# frozen_string_literal: true

module Supervisor
  class MergeAttestationsController < Supervisor::ApplicationController
    # Signed human merge approvals, issued and received (MergeAttestations).
    #
    # Index and show only. The approval columns cannot change and a row cannot
    # be destroyed, so the record of who approved which commit cannot be edited
    # into saying something else. Rows are written only by
    # LiveConversations::AuthorizeMerge (issued) and MergeAttestations::Acceptor
    # (received).
  end
end
