# frozen_string_literal: true

require "test_helper"

# The initializer itself runs at boot and is a no-op in `test`, so these exercise
# the predicate it is built on rather than re-running the block: that the list of
# environments allowed to page is one list, shared by the SDK configuration and by
# the boot-time check, and that the check's own guards are the ones it claims.
#
# The behaviour that matters — a deployed environment missing either half of the
# alerting path says so at boot instead of dropping pages silently — is the reason
# this file exists at all; the initializer replaced
# config/initializers/alert_service_health_check.rb, which checked a service that
# no longer exists.
class ObsReportingHealthCheckTest < ActiveSupport::TestCase
  test "the alerting environments are the deployed ones" do
    assert_equal %w[production staging], ErrorReporter::ALERTING_ENVIRONMENTS
  end

  test "the environments that page are frozen, so nothing can widen them at runtime" do
    assert ErrorReporter::ALERTING_ENVIRONMENTS.frozen?
  end

  test "test is not an alerting environment, so a test run cannot page" do
    assert_not_includes ErrorReporter::ALERTING_ENVIRONMENTS, "test"
    assert_not_includes ErrorReporter::ALERTING_ENVIRONMENTS, "development"
  end

  test "the initializer exists and names both halves of the alerting path" do
    source = Rails.root.join("config/initializers/obs_reporting_health_check.rb").read

    assert_includes source, "SENTRY_DSN_BACKEND",
      "the GlitchTip half must be checked — an unset DSN means no structured events"
    assert_includes source, "OTEL_LOGS_EXPORTER_ENDPOINT",
      "the log half must be checked — an unset endpoint means no ERROR record ships, so nothing pages"
    assert_includes source, "ErrorReporter::ALERTING_ENVIRONMENTS",
      "the check must read the same list the SDK is configured with, not a second copy"
  end

  test "reporting is a no-op unless the SDK is initialized, whatever the environment" do
    # The other half of "a test run cannot page": even inside an alerting
    # environment, ErrorReporter refuses before it reaches Sentry.
    ErrorReporter.stub(:reporting_enabled?, false) do
      assert_nil ErrorReporter.report_message("should not send", level: :error)
      assert_nil ErrorReporter.report_exception(StandardError.new("should not send"))
    end
  end
end
