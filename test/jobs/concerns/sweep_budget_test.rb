# frozen_string_literal: true

require "test_helper"

class SweepBudgetTest < ActiveSupport::TestCase
  class Sweeper
    include SweepBudget

    attr_accessor :clock

    def initialize(clock = 0.0)
      @clock = clock
    end

    def monotonic_now
      @clock
    end
  end

  test "a sweeper that never opened a budget is never cut short" do
    sweeper = Sweeper.new(0.0)

    assert_not sweeper.sweep_budget_spent?

    sweeper.clock = 1_000_000.0
    assert_not sweeper.sweep_budget_spent?, "no budget means no deadline to exceed"
  end

  test "the budget is spent once the deadline is reached" do
    sweeper = Sweeper.new(100.0)
    sweeper.start_sweep_budget(60)

    assert_not sweeper.sweep_budget_spent?

    sweeper.clock = 159.9
    assert_not sweeper.sweep_budget_spent?, "still inside the window"

    sweeper.clock = 160.0
    assert sweeper.sweep_budget_spent?, "the deadline itself is spent, not just past it"

    sweeper.clock = 500.0
    assert sweeper.sweep_budget_spent?
  end

  test "start_sweep_budget accepts a duration and reopens the window" do
    sweeper = Sweeper.new(0.0)
    sweeper.start_sweep_budget(5.minutes)

    sweeper.clock = 299.0
    assert_not sweeper.sweep_budget_spent?

    sweeper.clock = 301.0
    assert sweeper.sweep_budget_spent?

    # A second run of the same sweeper starts a fresh window rather than
    # inheriting the spent one.
    sweeper.start_sweep_budget(5.minutes)
    assert_not sweeper.sweep_budget_spent?
  end
end
