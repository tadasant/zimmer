# frozen_string_literal: true

# SecurityTelemetry counts in Rails.cache, which is a :null_store in the test
# env and keeps nothing. Wrap the requests under test in
# `with_security_telemetry` to count them in a real MemoryStore, then read the
# report it returns.
#
# The swap is of the global store, so any other cache user inside the block
# (rate limits, cooldowns) caches for real for its duration too. Counts other
# tests left pending in this process are discarded first, so the report holds
# only what the block recorded.
module SecurityTelemetryTestHelpers
  # @return [Hash] SecurityTelemetry.report taken inside the block's store
  def with_security_telemetry
    original = Rails.cache
    SecurityTelemetry.discard_pending!
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
    SecurityTelemetry.report
  ensure
    SecurityTelemetry.discard_pending!
    Rails.cache = original
  end
end
