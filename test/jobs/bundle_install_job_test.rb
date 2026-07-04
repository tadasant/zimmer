# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class BundleInstallJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @working_directory = Dir.mktmpdir
    # Create a Gemfile so the job runs
    File.write(File.join(@working_directory, "Gemfile"), "source 'https://rubygems.org'\n")
  end

  teardown do
    FileUtils.rm_rf(@working_directory) if @working_directory && Dir.exist?(@working_directory)
  end

  test "job completes successfully when bundle install succeeds" do
    # Use Mocha to stub Open3.capture3
    mock_status = mock
    mock_status.stubs(:success?).returns(true)
    Open3.stubs(:capture3).returns([ "", "", mock_status ])

    assert_difference -> { @session.logs.count }, 1 do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end

    log = @session.logs.last
    assert_equal "info", log.level
    assert_match(/completed successfully/, log.content)
  end

  test "job logs warning when bundle install fails" do
    # Use Mocha to stub Open3.capture3
    mock_status = mock
    mock_status.stubs(:success?).returns(false)
    Open3.stubs(:capture3).returns([ "", "Could not find gem 'foo'", mock_status ])

    assert_difference -> { @session.logs.count }, 1 do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end

    log = @session.logs.last
    assert_equal "warning", log.level
    assert_match(/failed/, log.content)
  end

  test "job does nothing if Gemfile does not exist" do
    # Remove the Gemfile
    File.delete(File.join(@working_directory, "Gemfile"))

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  test "job does nothing if session does not exist" do
    assert_nothing_raised do
      BundleInstallJob.perform_now(999999, @working_directory)
    end
  end

  test "job does nothing if session is archived" do
    @session.update!(status: :archived)

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  test "job does nothing if session is failed" do
    @session.update!(status: :failed)

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  test "job is discarded on errors without raising" do
    # Stub to raise an error during bundle install
    Open3.stubs(:capture3).raises(StandardError.new("Unexpected error"))

    # Job should complete without raising (because of discard_on)
    assert_nothing_raised do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end
end
