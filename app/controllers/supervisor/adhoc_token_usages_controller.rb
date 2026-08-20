# frozen_string_literal: true

module Supervisor
  class AdhocTokenUsagesController < Supervisor::ApplicationController
    # Inference Zimmer's own code made outside any session — session titles, push
    # summaries, the CLI status probe. Small next to session spend, and the place a
    # runaway app-internal call shows up.
  end
end
