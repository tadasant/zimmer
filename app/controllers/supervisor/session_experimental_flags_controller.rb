# frozen_string_literal: true

module Supervisor
  class SessionExperimentalFlagsController < Supervisor::ApplicationController
    # One row per (session, experimental setting): what the setting was when the
    # session first ran and when it last ran. Browsing them is how you check a
    # cohort on the Costs page against the sessions behind it — and, when a
    # comparison looks too good, how you see whether its labels were observed or
    # inferred from dates.
  end
end
