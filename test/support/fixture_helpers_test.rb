# frozen_string_literal: true

require "test_helper"

# The fixture helpers' transcript path is the one thing about them that can be
# silently WRONG: a fixture written where no runtime writes, and where nothing
# reads, makes a test that passes while the code under test is broken. It read
# `<clone_path>/.claude/projects/<session.id>` for every runtime until #838 —
# a shape Claude Code, Codex and Pi all disagree with.
#
# So these tests pin the helper to the runtime's own answer rather than to a
# literal path: a literal here would be the eleventh copy of the layout, which is
# what #504 and #691 exist to stop.
#
# There is no execution_provider case to cover: `local_filesystem` is the only
# member of Session::EXECUTION_PROVIDERS, so the branch the helper used to take on
# that column had one reachable arm and one that no valid session could enter.
class FixtureHelpersTest < ActiveSupport::TestCase
  WORKING_DIRECTORY = "/home/rails/.zimmer/clones/repo-main-1-abc"

  setup do
    @fs = MockFileSystemAdapter.new
  end

  %w[claude_code codex pi].each do |runtime|
    test "#{runtime}'s transcript directory is the runtime source's own answer" do
      session = session_for(runtime)

      assert_equal TranscriptRuntime.source_for(session).transcript_directory(working_directory: WORKING_DIRECTORY),
                   transcript_directory_for_session(session)
    end
  end

  test "the directory branches on the runtime, not on the execution provider" do
    directories = %w[claude_code codex pi].map { |runtime| transcript_directory_for_session(session_for(runtime)) }

    assert_equal 3, directories.uniq.size,
                 "each runtime writes somewhere different; got #{directories.inspect}"
  end

  test "a Claude fixture is found by the source production reads it with" do
    session = session_for("claude_code")

    create_fake_transcript(session, file_system: @fs)

    source = ClaudeTranscriptSource.new(file_system: @fs)
    located = source.locate(session: session, working_directory: WORKING_DIRECTORY)

    assert located, "the production source found no transcript where the fixture was written"
    assert_equal default_transcript_content, source.read(located)
  end

  test "a session with no working directory yet has no transcript directory" do
    assert_nil transcript_directory_for_session(session_for("claude_code", metadata: {}))
  end

  test "writing a fixture for a session with no working directory says so" do
    session = session_for("claude_code", metadata: {})

    error = assert_raises(RuntimeError) { create_fake_transcript(session, file_system: @fs) }
    assert_match(/working_directory/, error.message)
  end

  private

  def session_for(runtime, metadata: { "working_directory" => WORKING_DIRECTORY }, **attributes)
    create_session(agent_runtime: runtime, metadata: metadata, **attributes)
  end
end
