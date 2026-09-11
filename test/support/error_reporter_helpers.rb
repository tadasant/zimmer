# frozen_string_literal: true

# Captures what Zimmer would have reported to GlitchTip during a block, without
# initializing the Sentry SDK.
#
# `ErrorReporter` is the seam every operational alert passes through — directly
# (`report_message` / `report_exception`) or via `StructuredLogger#error`, which
# routes to it. Stubbing the seam is how a test asserts "this condition pages"
# without depending on a DSN.
#
# It deliberately does NOT capture the ERROR *log record*, which is the other half
# of a page (the record ships over OTLP and trips the Grafana rule on Zimmer's
# error logs). Use `capture_log_entries` from LogCaptureHelpers for that half; a
# test that cares which severity a condition emits at needs both.
module ErrorReporterHelpers
  # A single captured report.
  #
  # @!attribute message [String] the message for a `report_message`, or the
  #   exception's message for a `report_exception`
  # @!attribute exception [Exception, nil] present only for `report_exception`
  # @!attribute context [Hash] the `context:` the call site passed
  # @!attribute level [Symbol] :error unless the call site said otherwise
  Report = Struct.new(:message, :exception, :context, :level, :fingerprint, keyword_init: true) do
    def exception? = !exception.nil?
  end

  # @yield [Array<Report>] the (growing) list of reports, for assertions inside
  #   the block as well as after it
  # @return [Array<Report>] every report raised during the block, in order
  def capture_error_reports
    reports = []

    message_stub = lambda do |message, context: {}, level: :error|
      reports << Report.new(message: message, exception: nil, context: context, level: level)
      nil
    end

    exception_stub = lambda do |exception, context: {}, level: :error, fingerprint: nil|
      reports << Report.new(
        message: exception.message, exception: exception,
        context: context, level: level, fingerprint: fingerprint
      )
      nil
    end

    ErrorReporter.stub(:report_message, message_stub) do
      ErrorReporter.stub(:report_exception, exception_stub) do
        yield reports if block_given?
      end
    end

    reports
  end

  # The reports whose message is exactly `message`.
  def error_reports_titled(reports, message)
    reports.select { |report| report.message == message }
  end
end
