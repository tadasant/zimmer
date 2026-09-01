# frozen_string_literal: true

require "test_helper"

# A client asking an HTML-only web action for JSON (#453).
#
# Production emitted exactly two of these in fourteen days — TriggersController#show
# and ConnectorsController#index — and each one paged a human. Both actions fall
# through to implicit render with no `respond_to` block and no JSON template, so
# Rails raises ActionController::UnknownFormat.
#
# The status was never the defect: UnknownFormat carries a `rescue_responses`
# mapping to :not_acceptable, so an unrescued one already came back 406. The defect
# is the record — unrescued, the exception reaches ActionDispatch::DebugExceptions,
# which logs it at ERROR, and one ERROR record pages `#alerts`. So every test here
# asserts on the log entries as well as the status; a version of this file that
# checked only `assert_response :not_acceptable` would have passed before the fix.
#
# Two controllers, not one. The value of the fix is the blanket `rescue_from` on
# ApplicationController covering every HTML-only descendant at once, and a single
# route cannot show that.
class UnknownFormatTest < ActionDispatch::IntegrationTest
  test "a web trigger show asked for JSON is a 406, not an ERROR record" do
    trigger = triggers(:enabled_slack_trigger)

    entries = capture_log_entries do
      get trigger_path(trigger), headers: { "Accept" => "application/json" }
    end

    assert_response :not_acceptable
    assert_empty response.body
    assert_no_error_records entries
    assert_info_record entries, "GET #{trigger_path(trigger)}"
  end

  # The recurrence, and the one that makes the blanket handler's claim testable:
  # a second, unrelated HTML-only action covered by the same handler.
  test "the connectors index asked for JSON is a 406, not an ERROR record" do
    entries = capture_log_entries do
      get connectors_path, headers: { "Accept" => "application/json" }
    end

    assert_response :not_acceptable
    assert_empty response.body
    assert_no_error_records entries
    assert_info_record entries, "GET #{connectors_path}"
  end

  test "the INFO record carries the fields triage needs" do
    trigger = triggers(:enabled_slack_trigger)

    entries = capture_log_entries do
      get trigger_path(trigger),
        headers: { "Accept" => "application/json", "User-Agent" => "probe/1.0" }
    end

    line = info_record(entries)
    assert_match %r{\AUnrenderable format 406: GET #{Regexp.escape(trigger_path(trigger))} }, line
    # The field the two production records were identified by. Without it a
    # `respond_to` block missing a branch and an HTML-only action read identically.
    assert_match "action=TriggersController#show", line
    assert_match 'formats=["application/json"]', line
    assert_match(/ip=\S+/, line)
    assert_match 'user_agent="probe/1.0"', line
  end

  # Rails' own answer for this exception is already 406 via `rescue_responses`, and
  # a reader could reasonably conclude the handler is redundant. It is not: with the
  # exception unrescued the 406 is rendered by DebugExceptions, which logs the ERROR
  # record that pages. Pinning the severity is what keeps the handler from being
  # "simplified" back out.
  test "the format miss is not recorded at any severity above INFO" do
    entries = capture_log_entries do
      get connectors_path, headers: { "Accept" => "application/json" }
    end

    # Scoped to entries that name the event, not to every entry in the request: an
    # unrelated deprecation WARN from somewhere in /connectors would otherwise fail
    # this with a message pointing at the wrong thing.
    above_info = entries.select do |severity, message|
      %w[WARN ERROR FATAL ANY].include?(severity) &&
        (message.include?("UnknownFormat") || message.include?("Unrenderable format"))
    end

    assert_empty above_info,
      "a content-negotiation miss is a client error and must not reach a severity the alert counts"
  end

  test "an unacceptable format on a POST route is a 406 too" do
    # Not just implicit render on a GET: the handler is on ApplicationController, so
    # it covers a `respond_to` block that has no branch for the negotiated format.
    trigger = triggers(:enabled_slack_trigger)

    entries = capture_log_entries do
      post toggle_trigger_path(trigger), headers: { "Accept" => "application/pdf" }
    end

    assert_response :not_acceptable
    assert_no_error_records entries
  end

  # The other half of the fix: normal browsers are untouched.
  test "the same actions still render HTML" do
    trigger = triggers(:enabled_slack_trigger)

    get trigger_path(trigger)
    assert_response :success
    assert_equal "text/html", response.media_type

    get connectors_path
    assert_response :success
    assert_equal "text/html", response.media_type
  end

  # The trap in the whole fix, and the reason this test is behavioural rather than a
  # look at the rescue_handlers registry: ActionController::MissingExactTemplate is a
  # SUBCLASS of UnknownFormat, and rescue_from matches subclasses. A registry
  # assertion would pass while the handler silently swallowed it, because the
  # registry never lists subclasses in the first place.
  #
  # An action with no template in any format is a forgotten view — a server defect on
  # a real user's page load, not a client asking for the wrong format — so it has to
  # stay at ERROR. Issue the request and read the severity; nothing else proves it.
  test "an action with no template at all stays a loud ERROR, not a quiet 406" do
    with_routing do |routes|
      routes.draw { get "missing_template_probe", to: "missing_template_probe#show" }

      entries = capture_log_entries do
        get "/missing_template_probe"
      end

      errors = entries.select { |severity, _| severity == "ERROR" }
      assert_equal 1, errors.size,
        "a forgotten template must still page: #{entries.map(&:inspect).join("\n")}"
      assert_match "MissingExactTemplate", errors.first.last
      assert_empty entries.select { |_, message| message.start_with?("Unrenderable format 406:") },
        "a forgotten template must not be re-logged as a client-side format miss"
    end
  end

  # The blast radius of a blanket `rescue_from`. The JSON API is a separate
  # hierarchy (ActionController::API) and Administrate is a third, so neither
  # inherits this handler — and a format error on the API surface still surfaces.
  test "the handler does not reach the API or Administrate hierarchies" do
    refute Api::BaseController <= ApplicationController
    refute Supervisor::ApplicationController <= ApplicationController
  end

  private

  def info_record(entries)
    record = entries.find { |severity, message| severity == "INFO" && message.start_with?("Unrenderable format 406:") }
    assert record, "expected an INFO record for the format miss, got:\n#{entries.map(&:inspect).join("\n")}"
    record.last
  end

  def assert_info_record(entries, request_line)
    assert_includes info_record(entries), request_line
  end

  def assert_no_error_records(entries)
    errors = entries.select { |severity, _| severity == "ERROR" }
    assert_empty errors, "a content-negotiation miss must not emit an ERROR record: #{errors.inspect}"
  end
end

# The subject of the missing-template test above. It descends from
# ApplicationController — which is the whole point, since the handler under test is
# declared there — and has no template anywhere, in any format.
class MissingTemplateProbeController < ApplicationController
  def show; end
end
