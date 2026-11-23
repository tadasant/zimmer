module Supervisor
  # Read-only: a row says verified bytes are in object storage, which an edit cannot make true.
  class TranscriptCopiesController < Supervisor::ApplicationController
    def scoped_resource
      resource_class.order(id: :desc)
    end
  end
end
