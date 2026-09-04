# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AppSettingTest < ActiveSupport::TestCase
  test "blank runtime and model are valid (no override)" do
    setting = AppSetting.new(default_runtime: nil, default_model: nil)
    assert setting.valid?
  end

  test "valid claude_code + opus pairing" do
    assert AppSetting.new(default_runtime: "claude_code", default_model: "opus").valid?
  end

  test "valid claude_code + fable pairing" do
    assert AppSetting.new(default_runtime: "claude_code", default_model: "fable").valid?
  end

  test "valid codex + gpt-5.6 series pairing" do
    assert AppSetting.new(default_runtime: "codex", default_model: "gpt-5.6-sol").valid?
    assert AppSetting.new(default_runtime: "codex", default_model: "gpt-5.6-terra").valid?
    assert AppSetting.new(default_runtime: "codex", default_model: "gpt-5.6-luna").valid?
  end

  test "rejects an unregistered runtime" do
    setting = AppSetting.new(default_runtime: "aider", default_model: nil)
    refute setting.valid?
    assert setting.errors[:default_runtime].any?
  end

  test "rejects a Claude Code runtime paired with a GPT model" do
    setting = AppSetting.new(default_runtime: "claude_code", default_model: "gpt-5.5")
    refute setting.valid?
    assert setting.errors[:default_model].any?
  end

  test "rejects a Codex runtime paired with a Claude model" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "opus")
    refute setting.valid?
    assert setting.errors[:default_model].any?
  end

  test "a model with a blank runtime is validated against the default runtime" do
    # Blank runtime resolves to claude_code, so a GPT model is invalid.
    refute AppSetting.new(default_runtime: nil, default_model: "gpt-5.5").valid?
    assert AppSetting.new(default_runtime: nil, default_model: "opus").valid?
  end

  test "resolved_default_model_for returns the configured model when valid for the runtime" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.4")
    assert_equal "gpt-5.4", setting.resolved_default_model_for("codex")
  end

  test "resolved_default_model_for falls back to the runtime catalog default when model is incompatible" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5")
    # gpt-5.5 is not valid for claude_code → claude_code's catalog default.
    assert_equal ModelCatalog.default_for("claude_code"), setting.resolved_default_model_for("claude_code")
  end

  test "resolved_default_model_for falls back to the catalog default when model is blank" do
    setting = AppSetting.new(default_runtime: "codex", default_model: nil)
    assert_equal ModelCatalog.default_for("codex"), setting.resolved_default_model_for("codex")
  end

  test "current returns a blank, unsaved record when no row exists" do
    AppSetting.delete_all
    setting = AppSetting.current
    refute setting.persisted?
    assert_nil setting.default_runtime
    assert_nil setting.default_model
  end

  test "current returns the persisted singleton row when one exists" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")
    setting = AppSetting.current
    assert setting.persisted?
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "editable returns a persistable record that inserts the first row" do
    AppSetting.delete_all
    setting = AppSetting.editable
    setting.update!(default_runtime: "codex", default_model: "gpt-5.5")
    assert_equal 1, AppSetting.count
  end

  test "only one row may exist" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")
    second = AppSetting.new(default_runtime: "claude_code", default_model: "opus")
    refute second.valid?
    assert second.errors[:base].any?
  end

  test "NULL null-object answers the read interface and defers to the catalog default" do
    assert_nil AppSetting::NULL.default_runtime
    assert_nil AppSetting::NULL.default_model
    assert_equal ModelCatalog.default_for("codex"), AppSetting::NULL.resolved_default_model_for("codex")
  end

  test "extension_states defaults to an empty hash on a fresh record" do
    assert_equal({}, AppSetting.new.extension_states)
  end

  test "an unset extension resolves to the supplied default" do
    setting = AppSetting.new
    refute setting.extension_enabled?("pty_transport")
    assert setting.extension_enabled?("pty_transport", default: true)
  end

  test "NULL null-object reports every extension as off (and honors an explicit default)" do
    assert_equal({}, AppSetting::NULL.extension_states)
    refute AppSetting::NULL.extension_enabled?("pty_transport")
    assert AppSetting::NULL.extension_enabled?("pty_transport", default: true)
  end

  test "class-level extension_enabled? is the default when no row exists" do
    AppSetting.delete_all
    refute AppSetting.extension_enabled?("pty_transport")
    assert AppSetting.extension_enabled?("pty_transport", default: true)
  end

  # ===== MCP tool search =====

  test "mcp_tool_search_enabled? defaults on for a row that has never been saved" do
    assert AppSetting.new.mcp_tool_search_enabled?
  end

  test "class-level mcp_tool_search_enabled? defaults on when no row exists" do
    AppSetting.delete_all
    assert AppSetting.mcp_tool_search_enabled?
  end

  test "class-level mcp_tool_search_enabled? reflects the persisted state" do
    AppSetting.delete_all
    AppSetting.create!(mcp_tool_search_enabled: false)
    refute AppSetting.mcp_tool_search_enabled?

    AppSetting.current.update!(mcp_tool_search_enabled: true)
    assert AppSetting.mcp_tool_search_enabled?
  end

  test "mcp_tool_search_enabled? returns the default when the column is absent" do
    # Same deploy window as the extension_states case below: new code booting
    # against a schema that predates the migration must resolve to the shipped
    # default rather than raise on the session-spawn hot path.
    setting = AppSetting.new
    setting.define_singleton_method(:has_attribute?) do |name|
      name.to_sym == :mcp_tool_search_enabled ? false : super(name)
    end

    assert setting.mcp_tool_search_enabled?
  end

  test "class-level mcp_tool_search_enabled? falls back to the default when the row can't be read" do
    # The claim the degrade makes: a database the spawn path cannot query resolves
    # to the shipped default rather than raising mid-spawn. Stubs the query, not
    # AppSetting.current — current is the thing that degrades, so stubbing it out
    # would only exercise a rescue that no longer needs to exist.
    AppSetting.stubs(:order).raises(ActiveRecord::StatementInvalid, "relation does not exist")

    assert AppSetting.mcp_tool_search_enabled?
  end

  test "one failed settings read logs once, naming the caller that asked for it" do
    # Every wrapper reads through AppSetting.current, so the degrade happens in
    # exactly one place and reports itself once. A rescue in each wrapper as well
    # would turn one failure into three log lines naming three callers — a
    # smaller copy of the four-records-for-one-failure that #924 was.
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    begin
      AppSetting.stubs(:order).raises(ActiveRecord::StatementInvalid, "relation does not exist")

      assert AppSetting.mcp_tool_search_enabled?
    ensure
      Rails.logger = original_logger
    end

    assert_equal 1, log_output.string.scan(/could not read the settings row/).length
    assert_match(/AppSetting\.mcp_tool_search_enabled\? could not read the settings row/, log_output.string)
  end

  test "a settings read that degrades to a default says so in the log" do
    # #924: the rescue this replaces was silent, so when the read failed in
    # production the only records were the downstream errors it caused. Triage had
    # to reconstruct the cause from a source trace because no log line held it.
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    begin
      AppSetting.stubs(:order).raises(ActiveRecord::StatementInvalid, "relation does not exist")

      assert_equal AppSetting::NULL, AppSetting.current
    ensure
      Rails.logger = original_logger
    end

    assert_match(/AppSetting\.current could not read the settings row/, log_output.string)
    assert_match(/ActiveRecord::StatementInvalid: relation does not exist/, log_output.string)
  end

  test "a settings read inside an aborted transaction raises instead of degrading" do
    # The #924 regression. A failed statement inside a transaction leaves Postgres
    # rejecting everything later in it, so there is no default to degrade to: the
    # caller carries on, every statement after this one fails with
    # InFailedSqlTransaction, and the real cause is gone. Surface it instead.
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        begin
          ActiveRecord::Base.connection.execute("SELECT no_such_column_anywhere")
        rescue ActiveRecord::StatementInvalid
          # The transaction is aborted now, exactly as it was in production.
        end

        AppSetting.current
      end
    end

    assert_kind_of PG::InFailedSqlTransaction, error.cause
    assert AppSetting.current.is_a?(AppSetting), "the rolled-back savepoint must leave a usable connection"
  end

  test "the NULL stand-in resolves MCP tool search to the shipped default" do
    assert AppSetting::NULL.mcp_tool_search_enabled?
  end

  test "class-level extension_enabled? reflects the persisted state" do
    AppSetting.delete_all
    setting = AppSetting.create!
    setting.set_extension_enabled("pty_transport", true)
    setting.save!
    assert AppSetting.extension_enabled?("pty_transport")

    AppSetting.current.tap { |s| s.set_extension_enabled("pty_transport", false); s.save! }
    refute AppSetting.extension_enabled?("pty_transport")
  end

  test "set_extension_enabled touches only the named key" do
    setting = AppSetting.new
    setting.set_extension_enabled("pty_transport", true)
    setting.set_extension_enabled("some_experiment", false)
    assert_equal({ "pty_transport" => true, "some_experiment" => false }, setting.extension_states)

    setting.set_extension_enabled("some_experiment", true)
    assert setting.extension_enabled?("pty_transport"), "unrelated key must be preserved"
    assert setting.extension_enabled?("some_experiment")
  end

  test "extension_enabled? coerces stored values through the boolean type" do
    setting = AppSetting.new
    setting.extension_states = { "pty_transport" => "1", "some_experiment" => "0" }
    assert setting.extension_enabled?("pty_transport")
    refute setting.extension_enabled?("some_experiment")
  end

  test "extension_enabled? returns the default when the extension_states column is absent" do
    # Simulates new code booting against a schema that predates the column's
    # migration: the lookup must degrade to the default instead of raising, so
    # the session-spawn hot path stays alive during that deploy window.
    setting = AppSetting.new
    setting.define_singleton_method(:has_attribute?) do |name|
      name.to_sym == :extension_states ? false : super(name)
    end
    refute setting.extension_enabled?("pty_transport")
    assert setting.extension_enabled?("pty_transport", default: true)
  end

  # The three fleet top-up knobs. A ceiling of 0 is the dangerous one: the test
  # FleetIdleMonitor makes is `sessions_in_hand < ceiling`, so 0 can never be
  # satisfied and the event would quietly never fire again.
  test "the fleet top-up ceiling must be at least one" do
    setting = AppSetting.new(fleet_idle_max_sessions: 0)
    assert_not setting.valid?
    assert setting.errors[:fleet_idle_max_sessions].any?

    setting.fleet_idle_max_sessions = 1
    setting.valid?
    assert_empty setting.errors[:fleet_idle_max_sessions],
      "1 is the nothing-running-and-nothing-queued behaviour and must stay reachable"
  end

  test "the fleet top-up clocks are bounded in minutes" do
    setting = AppSetting.new(fleet_idle_threshold_minutes: 0,
                             fleet_idle_min_fire_interval_minutes: 10_081)
    assert_not setting.valid?
    assert setting.errors[:fleet_idle_threshold_minutes].any?,
      "a stretch shorter than the once-a-minute sweep could not be observed"
    assert setting.errors[:fleet_idle_min_fire_interval_minutes].any?
  end

  test "a fresh row ships the documented top-up defaults" do
    AppSetting.delete_all
    setting = AppSetting.create!

    assert_equal 3, setting.fleet_idle_max_sessions
    assert_equal 5, setting.fleet_idle_threshold_minutes
    assert_equal 60, setting.fleet_idle_min_fire_interval_minutes
  end

  # A DB-less boot has to answer these without raising: FleetTopUpStatus reads
  # them straight off whatever AppSetting.current returns.
  test "the NULL object answers the fleet top-up readers with the shipped defaults" do
    assert_equal AppSetting::DEFAULT_FLEET_IDLE_MAX_SESSIONS, AppSetting::NULL.fleet_idle_max_sessions
    assert_equal AppSetting::DEFAULT_FLEET_IDLE_THRESHOLD_MINUTES, AppSetting::NULL.fleet_idle_threshold_minutes
    assert_equal AppSetting::DEFAULT_FLEET_IDLE_MIN_FIRE_INTERVAL_MINUTES,
                 AppSetting::NULL.fleet_idle_min_fire_interval_minutes
    # Both clocks too: FleetTopUpStatus reads them unconditionally, so a NULL that
    # answered only the three knobs would raise NoMethodError on the DB-less path
    # instead of degrading.
    assert_nil AppSetting::NULL.fleet_idle_since
    assert_nil AppSetting::NULL.fleet_idle_event_fired_at
  end

  # The whole point of the readers above: constructing the status object off the
  # NULL row must not raise.
  test "FleetTopUpStatus can be built from the NULL object" do
    status = FleetTopUpStatus.new(setting: AppSetting::NULL, sessions_in_hand: 0)

    assert_equal :clock_not_started, status.state
    assert status.sentence.present?
  end
end
