# frozen_string_literal: true

# What one quota window is worth in dollars, denominated in Opus spend.
#
# Anthropic reports quota as a percentage and never as money. A percentage
# cannot be compared to anything an operator cares about: not "keep $200 back
# for priority work", not "this session burns $0.40 a minute", not "will one more
# session fit". Everything downstream of this table — the reserve, the pacing
# curve, the "$ remaining" figures on /inference — exists because this row turns
# the percentage into a quantity.
#
# == The estimator
#
# A ratio, and deliberately the simplest one that is right:
#
#     capacity = Opus-denominated spend over the window / pool utilization of it
#
# The arithmetic works out because the pool figure is an AVERAGE and the spend is
# a TOTAL. With N accounts each of capacity C, total spend is `sum(C * u_i)`,
# which is `C * N * mean(u)` — so dividing total spend by the mean utilization
# gives `N * C`, the pool's whole capacity. See QuotaCapacityCalibrator.
#
# == Why it is smoothed
#
# One observation is noisy: the 5-hour ratio divides a few hours of lumpy spend
# by an average that moves as accounts reset at different times. An exponential
# moving average keeps the estimate responsive to a real change (a plan upgrade,
# an account added to the pool) without letting a single quiet afternoon halve
# the number the scheduler decides on.
#
# == It is an estimate, and says so
#
# `sample_cost_usd` and `sample_utilization` are kept so every surface can show
# what the figure was derived from rather than presenting a modelled number as a
# measured one. Nothing here is a bill: these accounts are subscription-billed,
# and this is list-price spend used as a comparable unit.
class QuotaCapacityEstimate < ApplicationRecord
  FIVE_HOUR = "five_hour"
  WEEKLY = "weekly"

  # Each window's length. These are Anthropic's unified rate-limit windows, and
  # they are what the pacing curve divides elapsed time by.
  WINDOW_SECONDS = {
    FIVE_HOUR => 5.hours.to_i,
    WEEKLY => 7.days.to_i
  }.freeze

  WINDOW_KEYS = WINDOW_SECONDS.keys.freeze

  LABELS = { FIVE_HOUR => "5-hour", WEEKLY => "weekly" }.freeze

  # How much of a new observation lands in the estimate. 0.3 settles a step
  # change within a handful of calibration runs while flattening the swing a
  # single sample can cause.
  SMOOTHING = 0.3

  # An observation is only usable when the denominator is large enough to divide
  # by. Below this, the ratio is a small number over a smaller one and the
  # implied capacity swings by an order of magnitude between runs.
  MIN_SAMPLE_UTILIZATION = 0.05

  # …and when the numerator is real spend rather than a rounding error. A window
  # in which almost nothing ran says nothing about how big the window is.
  MIN_SAMPLE_COST_USD = 1.0

  # An estimate the calibrator has not refreshed for this long is no longer
  # trusted, and the model degrades to reasoning in percentages. The calibration
  # cron runs every 15 minutes, so this only fires when it has genuinely stopped
  # — which must show up as a visible loss of precision rather than as
  # confidently stale dollars.
  FRESHNESS_HORIZON = 24.hours

  validates :window_key, presence: true, inclusion: { in: WINDOW_KEYS }
  validates :window_key, uniqueness: true
  validates :capacity_usd, numericality: { greater_than: 0 }, allow_nil: true

  class << self
    # Both windows' estimates keyed by window, whether or not a row exists.
    # @return [Hash{String => QuotaCapacityEstimate, nil}]
    def table
      stored = where(window_key: WINDOW_KEYS).index_by(&:window_key)
      WINDOW_KEYS.index_with { |key| stored[key] }
    end

    def window_seconds(window_key) = WINDOW_SECONDS.fetch(window_key.to_s)
    def label(window_key) = LABELS.fetch(window_key.to_s)
  end

  # True when the calibration cron has refreshed this recently enough for the
  # gate and the page to denominate in dollars.
  def usable?
    capacity_usd.to_f.positive? && computed_at.present? && computed_at >= FRESHNESS_HORIZON.ago
  end

  def window_seconds = self.class.window_seconds(window_key)
  def label = self.class.label(window_key)

  # Fold one observation into the smoothed estimate. The first observation is
  # taken whole — an average of a number and nothing is just the number, and
  # seeding at a fraction of the truth would have the scheduler hold everything
  # for the first hour of a deployment's life.
  #
  # @param observed [Float] this run's capacity ratio, in USD
  # @param sample_cost_usd [Float] the numerator it came from
  # @param sample_utilization [Float] the denominator it came from
  # @param now [Time] the clock the calibration run is using, threaded through
  #   rather than re-read, so one run's two windows carry the same timestamp.
  def absorb(observed:, sample_cost_usd:, sample_utilization:, now: Time.current)
    blended = capacity_usd.to_f.positive? ? (SMOOTHING * observed) + ((1 - SMOOTHING) * capacity_usd) : observed

    assign_attributes(
      capacity_usd: blended,
      observed_capacity_usd: observed,
      sample_cost_usd: sample_cost_usd,
      sample_utilization: sample_utilization,
      observation_count: observation_count.to_i + 1,
      computed_at: now
    )
    self
  end
end
