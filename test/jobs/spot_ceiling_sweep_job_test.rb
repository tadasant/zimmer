# frozen_string_literal: true

require "test_helper"

class SpotCeilingSweepJobTest < ActiveSupport::TestCase
  def result(paused: 0, resumed: 0, held: 0)
    SpotSessionPause::Result.new(paused: paused, resumed: resumed, held: held)
  end

  test "the job delegates to the sweep" do
    calls = 0
    sweep = lambda do |*_args, **_kwargs|
      calls += 1
      result(paused: 2)
    end

    SpotSessionPause.stub(:sweep!, sweep) do
      SpotCeilingSweepJob.perform_now
    end

    assert_equal 1, calls, "the cron entry is the only thing that applies the ceiling to running sessions"
  end

  # The cron fires every five minutes forever, and most passes have nothing to do.
  test "a pass with nothing to do does not raise" do
    sweep = ->(*_args, **_kwargs) { result }

    SpotSessionPause.stub(:sweep!, sweep) do
      assert_nothing_raised { SpotCeilingSweepJob.perform_now }
    end
  end

  # Every environment that runs cron has to carry the entry, or the ceiling
  # simply does not exist there — the sweep is the only thing that applies it.
  test "production and staging both schedule the sweep" do
    %i[production staging].each do |env|
      scheduled = CronSchedule.for(env).values.map { |entry| entry[:class] }

      assert_includes scheduled, "SpotCeilingSweepJob", "#{env} does not schedule the spot ceiling sweep"
    end
  end
end
