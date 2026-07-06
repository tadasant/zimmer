require "test_helper"

class LogTest < ActiveSupport::TestCase
  # Test associations
  test "should belong to session" do
    log = logs(:info_log)
    assert_respond_to log, :session
    assert_kind_of Session, log.session
  end

  test "should require session association" do
    log = Log.new(content: "Test log", level: "info")
    assert_not log.valid?
    assert_raises(ActiveRecord::RecordInvalid) do
      log.save!
    end
  end

  test "should save log with valid session" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test content", level: "info")
    assert log.save
  end

  # Test attributes
  test "should persist content attribute" do
    session = sessions(:running)
    log = Log.create!(
      session: session,
      content: "Test log content",
      level: "info"
    )

    log.reload
    assert_equal "Test log content", log.content
  end

  test "should persist level attribute" do
    session = sessions(:running)
    log = Log.create!(
      session: session,
      content: "Test content",
      level: "error"
    )

    log.reload
    assert_equal "error", log.level
  end

  # Test creating logs with different levels
  test "should create log with info level" do
    session = sessions(:running)
    log = Log.create!(session: session, content: "Info message", level: "info")
    assert_equal "info", log.level
  end

  test "should create log with error level" do
    session = sessions(:running)
    log = Log.create!(session: session, content: "Error message", level: "error")
    assert_equal "error", log.level
  end

  test "should create log with debug level" do
    session = sessions(:running)
    log = Log.create!(session: session, content: "Debug message", level: "debug")
    assert_equal "debug", log.level
  end

  test "should create log with warning level" do
    session = sessions(:running)
    log = Log.create!(session: session, content: "Warning message", level: "warning")
    assert_equal "warning", log.level
  end

  # Test timestamps
  test "should have created_at timestamp" do
    log = logs(:info_log)
    assert_not_nil log.created_at
    assert_kind_of Time, log.created_at
  end

  test "should have updated_at timestamp" do
    log = logs(:info_log)
    assert_not_nil log.updated_at
    assert_kind_of Time, log.updated_at
  end

  # Test session association retrieval
  test "should retrieve correct session" do
    log = logs(:info_log)
    assert_equal sessions(:running), log.session
  end

  test "should retrieve all logs for a session" do
    session = sessions(:running)
    logs = session.logs

    assert_includes logs, logs(:info_log)
    assert_includes logs, logs(:error_log)
  end

  # Test log creation through session
  test "should create log through session association" do
    session = sessions(:running)

    assert_difference "session.logs.count", 1 do
      session.logs.create!(content: "New log", level: "info")
    end
  end

  test "should build log through session association" do
    session = sessions(:running)
    log = session.logs.build(content: "Built log", level: "info")

    assert_equal session, log.session
    assert log.save
  end

  # Test validations
  test "should require content presence" do
    session = sessions(:running)
    log = Log.new(session: session, level: "info")
    assert_not log.valid?
    assert_includes log.errors[:content], "can't be blank"
  end

  test "should validate level inclusion" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "invalid_level")
    assert_not log.valid?
    assert_includes log.errors[:level], "invalid_level is not a valid log level"
  end

  test "should accept valid info level" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "info")
    assert log.valid?
  end

  test "should accept valid error level" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "error")
    assert log.valid?
  end

  test "should accept valid debug level" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "debug")
    assert log.valid?
  end

  test "should accept valid warning level" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "warning")
    assert log.valid?
  end

  test "should not save log without content" do
    session = sessions(:running)
    log = Log.new(session: session, level: "info")
    assert_not log.save
  end

  test "should not save log with invalid level" do
    session = sessions(:running)
    log = Log.new(session: session, content: "Test", level: "fatal")
    assert_not log.save
  end
end
