# frozen_string_literal: true

# Re-estimates what each quota window is worth in dollars.
#
# Anthropic reports quota as a percentage. This job is what makes "the 5-hour
# window is at 76%" comparable to a reserve, a burn rate, or a decision about
# whether one more session fits — see QuotaCapacityCalibrator for the estimator
# and for everything it approximates.
#
# Idempotent: each run folds one observation into a smoothed estimate keyed by
# window, so running it twice is two observations rather than a corrupted state.
# It needs no shell on the box, and /inference shows when it last ran and what it
# derived the figure from.
#
# Failures are swallowed for the same reason the sampler's are: a missing
# calibration leaves the model on a slightly older estimate, and
# QuotaCapacityEstimate::FRESHNESS_HORIZON degrades the gate to percentages if
# this has genuinely stopped rather than letting it decide on stale dollars.
class QuotaCapacityCalibrationJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    QuotaCapacityCalibrator.calibrate!.each do |observation|
      if observation.usable?
        Rails.logger.info(
          "[QuotaCapacityCalibrationJob] #{observation.window_key}: $#{observation.cost_usd.round(2)} " \
          "at #{(observation.utilization * 100).round(2)}% => $#{observation.capacity_usd.round(2)} capacity"
        )
      else
        Rails.logger.info("[QuotaCapacityCalibrationJob] #{observation.window_key} skipped: #{observation.reason}")
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[QuotaCapacityCalibrationJob] Calibration failed: #{e.class}: #{e.message}")
    nil
  end
end
