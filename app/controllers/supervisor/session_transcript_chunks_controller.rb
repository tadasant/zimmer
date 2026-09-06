module Supervisor
  class SessionTranscriptChunksController < Supervisor::ApplicationController
    # Read-only: the dashboard declares no FORM_ATTRIBUTES, because a chunk is one
    # slice of an append-only log and hand-editing it would corrupt the transcript
    # rather than repair it.
    def scoped_resource
      resource_class.order(session_id: :desc, seq: :asc)
    end
  end
end
