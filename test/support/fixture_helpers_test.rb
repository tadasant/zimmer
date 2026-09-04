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

  # Every registered runtime, not a hardcoded three, so a runtime added to
  # RuntimeRegistry is covered here the day it is registered.
  RuntimeRegistry.registered_runtimes.each do |runtime|
    test "#{runtime}'s transcript directory is the runtime source's own answer" do
      session = session_for(runtime)

      assert_equal TranscriptRuntime.source_for(session).transcript_directory(working_directory: WORKING_DIRECTORY),
                   transcript_directory_for_session(session)
    end
  end

  # The delegation assertions above cannot fail on a helper that hands the seam
  # the wrong INPUT, and they read as tautologies on their own. These two pin the
  # properties the old shape actually got wrong: one path for every runtime, and
  # Claude's transcripts placed inside the clone.
  test "the runtime decides the layout — the runtimes do not share one path" do
    claude, codex, pi = %w[claude_code codex pi].map { |runtime| transcript_directory_for_session(session_for(runtime)) }

    assert_not_equal claude, codex
    assert_not_equal claude, pi
    assert_not_equal codex, pi
  end

  test "Claude's transcripts live under HOME, not inside the clone" do
    directory = transcript_directory_for_session(session_for("claude_code"))

    assert_not directory.start_with?(WORKING_DIRECTORY),
               "Claude Code writes to ~/.claude/projects/<sanitized-cwd>, not into the working directory"
    assert directory.start_with?(File.join(File.expand_path("~"), ".claude", "projects"))
  end

  test "a Claude fixture is found by the source production reads it with" do
    session = session_for("claude_code")

    create_fake_transcript(session, file_system: @fs)

    source = ClaudeTranscriptSource.new(file_system: @fs)
    located = source.locate(session: session, working_directory: WORKING_DIRECTORY)

    assert located, "the production source found no transcript where the fixture was written"
    assert_equal default_transcript_content, source.read(located)
  end

  # Session#working_directory is the input, so the helper honors the same key
  # precedence the controllers do — including the clone_path fallback for sessions
  # recorded before working_directory existed.
  test "a session with only a clone_path resolves from that clone path" do
    session = session_for("claude_code", metadata: { "clone_path" => WORKING_DIRECTORY })

    assert_equal transcript_directory_for_session(session_for("claude_code")),
                 transcript_directory_for_session(session)
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
