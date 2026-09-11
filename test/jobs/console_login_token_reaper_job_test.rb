# frozen_string_literal: true

require "test_helper"

class ConsoleLoginTokenReaperJobTest < ActiveJob::TestCase
  test "deletes rows expired more than RETENTION ago and leaves the rest" do
    now = Time.current
    live, _t = ConsoleLoginToken.mint!(principal: "live", now: now)
    expired_recently, _t = ConsoleLoginToken.mint!(principal: "recent", now: now - 2.days)
    old, _t = ConsoleLoginToken.mint!(principal: "old", now: now - ConsoleLoginToken::RETENTION - 1.hour)

    ConsoleLoginTokenReaperJob.perform_now

    assert ConsoleLoginToken.exists?(live.id)
    assert ConsoleLoginToken.exists?(expired_recently.id)
    assert_not ConsoleLoginToken.exists?(old.id)
  end

  test "is a singleton sweep on the default queue" do
    assert_equal "default", ConsoleLoginTokenReaperJob.new.queue_name
    assert_includes ConsoleLoginTokenReaperJob.ancestors, SingletonSweep
  end
end
