# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Sessions::RefreshTranscriptTest < ActiveSupport::TestCase
  LINE_ONE = JSON.generate({ type: "user", message: { role: "user", content: "one" } })
  LINE_TWO = JSON.generate({ type: "assistant", message: { role: "assistant", content: "two" } })

  setup do
    @tmpdir = Dir.mktmpdir("refresh-transcript")
    @session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :running,
      metadata: { "working_directory" => @tmpdir }
    )
    @file = File.join(@tmpdir, "main.jsonl")
  end

  teardown { FileUtils.rm_rf(@tmpdir) }

  # Point the lookup at a real file in a temp directory, so the read itself goes
  # through the runtime's TranscriptSource the way production's does.
  def stage_transcript(content)
    File.write(@file, content)
    Sessions::RefreshTranscript.any_instance.stubs(:transcript_directory).returns(@tmpdir)
    Sessions::RefreshTranscript.any_instance.stubs(:main_transcript_file).returns(@file)
  end

  # --- the happy path ---------------------------------------------------------

  test "stores the transcript, its broadcast_message_count and one timeline row" do
    stage_transcript("#{LINE_ONE}\n#{LINE_TWO}\n")

    result = Sessions::RefreshTranscript.call(@session, actor: :web)

    assert result.refreshed?
    assert_equal 2, result.message_count
    @session.reload
    assert_equal "#{LINE_ONE}\n#{LINE_TWO}\n", @session.transcript
    assert_equal 2, @session.metadata["broadcast_message_count"]
    assert_equal [ "Transcript refreshed manually from filesystem (2 messages)" ],
      @session.logs.where("content LIKE 'Transcript refreshed%'").pluck(:content)
  end

  # The strings every door always wrote; they are the timeline people read.
  test "names the door it came through on the timeline" do
    expected = {
      [ :web, false ] => "Transcript refreshed manually from filesystem (1 messages)",
      [ :web, true ] => "Transcript refreshed via bulk refresh (1 messages)",
      [ :api, false ] => "Transcript refreshed via API (1 messages)",
      [ :api, true ] => "Transcript refreshed via API bulk refresh (1 messages)",
      [ :mcp, false ] => "Transcript refreshed via MCP (1 messages)",
      [ :mcp, true ] => "Transcript refreshed via MCP bulk refresh (1 messages)"
    }
    stage_transcript("#{LINE_ONE}\n")

    expected.each do |(actor, bulk), content|
      @session.logs.delete_all
      Sessions::RefreshTranscript.call(@session.reload, actor: actor, bulk: bulk)

      assert_equal [ content ], @session.logs.pluck(:content), "for actor: #{actor}, bulk: #{bulk}"
    end
  end

  test "counts only lines that parse as JSON" do
    stage_transcript("#{LINE_ONE}\nnot json\n\n#{LINE_TWO}\n")

    assert_equal 2, Sessions::RefreshTranscript.call(@session, actor: :api).message_count
  end

  test "rejects an unknown actor rather than writing an unlabelled row" do
    assert_raises(KeyError) { Sessions::RefreshTranscript.call(@session, actor: :cron) }
  end

  # --- nothing to read --------------------------------------------------------

  test "a session with no working directory has no transcript directory" do
    @session.update!(metadata: {})

    result = Sessions::RefreshTranscript.call(@session, actor: :web)

    assert_equal :no_transcript_directory, result.outcome
    assert_not result.refreshed?
    assert_nil @session.reload.transcript
  end

  test "a directory that does not exist has no transcript file" do
    Sessions::RefreshTranscript.any_instance.stubs(:transcript_directory).returns(File.join(@tmpdir, "gone"))

    assert_equal :no_transcript_file, Sessions::RefreshTranscript.call(@session, actor: :mcp).outcome
  end

  test "a directory with no main transcript in it has no transcript file" do
    Sessions::RefreshTranscript.any_instance.stubs(:transcript_directory).returns(@tmpdir)
    Sessions::RefreshTranscript.any_instance.stubs(:main_transcript_file).returns(nil)

    assert_equal :no_transcript_file, Sessions::RefreshTranscript.call(@session, actor: :api).outcome
    assert_equal 0, @session.logs.count
  end

  # --- skip_unchanged ---------------------------------------------------------

  test "with skip_unchanged, a byte-identical transcript is left alone" do
    @session.update!(transcript: "#{LINE_ONE}\n")
    stage_transcript("#{LINE_ONE}\n")

    result = nil
    assert_no_difference -> { @session.logs.count } do
      result = Sessions::RefreshTranscript.call(@session, actor: :mcp, bulk: true, skip_unchanged: true)
    end

    assert_equal :unchanged, result.outcome
    assert_nil @session.reload.metadata["broadcast_message_count"]
  end

  test "without skip_unchanged, a byte-identical transcript is still written and re-counted" do
    @session.update!(transcript: "#{LINE_ONE}\n")
    stage_transcript("#{LINE_ONE}\n")

    result = Sessions::RefreshTranscript.call(@session, actor: :web)

    assert result.refreshed?
    assert_equal 1, @session.reload.metadata["broadcast_message_count"]
  end

  # --- the regression guard ---------------------------------------------------

  test "a filesystem transcript shorter than the stored one never overwrites it" do
    @session.update!(transcript: "#{LINE_ONE}\n#{LINE_TWO}\n")
    stage_transcript("#{LINE_ONE}\n")

    result = Sessions::RefreshTranscript.call(@session, actor: :api, bulk: true, skip_unchanged: true)

    assert_equal :regression, result.outcome
    assert_equal 1, result.message_count
    assert_equal "#{LINE_ONE}\n#{LINE_TWO}\n", @session.reload.transcript
    assert_equal 0, @session.logs.count
  end

  # --- the re-keyed branch (#1047) --------------------------------------------
  #
  # The REST API's bulk sweep was the one refresh that skipped the splice. Every
  # door reaches it now, so it is asserted on that door.

  test "stores the spliced text, not the raw file, when the file is a re-keyed branch" do
    stage_transcript("#{LINE_TWO}\n")
    RekeyedTranscriptBranch.expects(:continue)
      .with(session: @session, transcript_path: @file, content: "#{LINE_TWO}\n")
      .returns("#{LINE_ONE}\n#{LINE_TWO}\n")

    result = Sessions::RefreshTranscript.call(@session, actor: :api, bulk: true, skip_unchanged: true)

    assert result.refreshed?
    assert_equal "#{LINE_ONE}\n#{LINE_TWO}\n", @session.reload.transcript
  end

  # --- the database -----------------------------------------------------------

  test "retries a dropped connection and succeeds when it comes back" do
    stage_transcript("#{LINE_ONE}\n")
    Sessions::RefreshTranscript.any_instance.stubs(:sleep)
    attempts = 0
    original = @session.method(:merge_metadata!)
    @session.define_singleton_method(:merge_metadata!) do |*args, **kwargs|
      attempts += 1
      raise ActiveRecord::ConnectionNotEstablished, "gone" if attempts == 1

      original.call(*args, **kwargs)
    end

    result = Sessions::RefreshTranscript.call(@session, actor: :mcp)

    assert result.refreshed?
    assert_equal 2, attempts
  end

  test "a database that stays unavailable is an outcome, not an exception" do
    stage_transcript("#{LINE_ONE}\n")
    Sessions::RefreshTranscript.any_instance.stubs(:sleep)
    @session.stubs(:merge_metadata!).raises(ActiveRecord::ConnectionNotEstablished, "gone")

    result = Sessions::RefreshTranscript.call(@session, actor: :web)

    assert result.database_unavailable?
    assert_not result.refreshed?
    assert_equal Sessions::RefreshTranscript::DATABASE_UNAVAILABLE_MESSAGE, result.error
  end

  # Each surface already has its own rescue, and they disagree on purpose about
  # what an unexpected error looks like, so this does not flatten them into one.
  test "anything else propagates to the surface that asked" do
    stage_transcript("#{LINE_ONE}\n")
    @session.stubs(:merge_metadata!).raises(ArgumentError, "boom")

    assert_raises(ArgumentError) { Sessions::RefreshTranscript.call(@session, actor: :api) }
  end
end
