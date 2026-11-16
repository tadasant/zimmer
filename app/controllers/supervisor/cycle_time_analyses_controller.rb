# frozen_string_literal: true

module Supervisor
  class CycleTimeAnalysesController < Supervisor::ApplicationController
    # Every Cycle Time row, eligible or not, with the reason a hierarchy did not
    # count and the version of the analyzer that wrote it — the raw view behind
    # /cycle_times, for checking what the sweep has covered.
    #
    # Index and show only. A row is derived data: CycleTimes::Analyzer writes it
    # and CycleTimeSweepJob recomputes it, so a hand edit would be overwritten.
  end
end
