# frozen_string_literal: true

# Helpers for creating test fixtures and test data.
# Provides utilities to create sessions, transcripts, and other common test data
# with sensible defaults, reducing boilerplate in tests.
#
# Usage:
#   test "something" do
#     session = create_session(status: :running)
#     create_fake_transcript(session, content: "test transcript")
#   end
module FixtureHelpers
  # Create session with common defaults
  # @param attributes [Hash] Optional attributes to override defaults
  # @return [Session] Created session instance
  #
  # Example:
  #   session = create_session
  #   session = create_session(status: :running, prompt: "Custom prompt")
  def create_session(attributes = {})
    defaults = {
      prompt: "Test prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }

    Session.create!(defaults.merge(attributes))
  end

  # Create running session with transcript content
  # @param transcript_content [String, nil] Optional custom transcript content
  # @param attributes [Hash] Optional session attributes
  # @return [Session] Created session with transcript
  #
  # Example:
  #   session = create_running_session_with_transcript
  #   session = create_running_session_with_transcript(
  #     transcript_content: custom_content,
  #     prompt: "Custom prompt"
  #   )
  def create_running_session_with_transcript(transcript_content: nil, **attributes)
    session = create_session(attributes.merge(status: :running))

    transcript = transcript_content || default_transcript_content
    session.update!(transcript: transcript)

    session
  end

  # Create fake transcript file in mock file system
  #
  # The directory comes from the session's runtime (see
  # #transcript_directory_for_session). The FILE NAME and the default content are
  # Claude-shaped: a plain `.jsonl` in the directory is what TranscriptFileLocator
  # falls back to, whereas CodexTranscriptSource globs `rollout-*` and
  # PiTranscriptSource matches `*_<session_id>.jsonl` or a header-stamped
  # `zimmer_session.jsonl`. A fixture that a Codex or Pi source must be able to
  # LOCATE (rather than just live in the right directory) needs to be written
  # with that runtime's naming, not through this helper.
  #
  # @param session [Session] The session to create transcript for
  # @param content [String, nil] Optional transcript content (uses default if nil)
  # @param file_system [MockFileSystemAdapter] The file system to write to (uses @mock_fs if not provided)
  #
  # Example:
  #   setup_mock_dependencies
  #   session = create_session
  #   create_fake_transcript(session)
  #   create_fake_transcript(session, content: custom_jsonl_content)
  def create_fake_transcript(session, content: nil, file_system: nil)
    fs = file_system || @mock_fs
    raise "No file system provided and @mock_fs not set" unless fs

    transcript_content = content || default_transcript_content

    transcript_dir = transcript_directory_for_session(session)
    unless transcript_dir
      raise "Cannot resolve a transcript directory for session #{session.id}: " \
            "the #{session.agent_runtime} source needs metadata['working_directory'] " \
            "(or 'clone_path') to be set on the session"
    end

    fs.mkdir_p(transcript_dir)
    fs.write(
      File.join(transcript_dir, "transcript-001.jsonl"),
      transcript_content
    )
  end

  # Get the transcript directory for a session, from the runtime that writes it.
  #
  # This asks the same seam the production readers ask — TranscriptRuntime for
  # the session's TranscriptSource, then that source for the directory — so a
  # fixture lands exactly where TranscriptPollerService, SessionTranscriptLookup
  # and the retry services will look for it. The layout is a property of the
  # RUNTIME, not of the execution provider: Claude Code writes to
  # ~/.claude/projects/<sanitized-working-directory>/, Codex to a date-partitioned
  # tree under ~/.codex/sessions, Pi to <working_directory>/.pi/sessions. Nothing
  # here recomputes any of that.
  #
  # @param session [Session] The session to get the directory for
  # @return [String, nil] Path to the transcript directory, or nil when the
  #   session has no working directory yet (the runtime sources return nil rather
  #   than guessing)
  def transcript_directory_for_session(session)
    working_directory = session.working_directory
    return nil unless working_directory.is_a?(String) && working_directory.present?

    TranscriptRuntime.source_for(session).transcript_directory(working_directory: working_directory)
  end

  # Default transcript content for tests
  # Returns a sample JSONL transcript with typical message types
  # @return [String] JSONL formatted transcript
  #
  # Example:
  #   content = default_transcript_content
  def default_transcript_content
    <<~JSONL.strip
      {"type":"text","text":"Hello, I can help you with that.","role":"assistant"}
      {"type":"tool_use","name":"Read","input":{"file_path":"README.md"}}
      {"type":"tool_result","content":"File contents here"}
      {"type":"text","text":"I've read the README file.","role":"assistant"}
    JSONL
  end

  # Create a session with logs
  # @param log_count [Integer] Number of logs to create (default: 3)
  # @param attributes [Hash] Optional session attributes
  # @return [Session] Created session with logs
  #
  # Example:
  #   session = create_session_with_logs(log_count: 5)
  #   assert_equal 5, session.logs.count
  def create_session_with_logs(log_count: 3, **attributes)
    session = create_session(attributes)

    log_count.times do |i|
      session.logs.create!(
        content: "Log entry #{i + 1}",
        level: "info"
      )
    end

    session.reload
  end

  # Create a failed session with error logs
  # @param error_message [String] Optional custom error message
  # @param attributes [Hash] Optional session attributes
  # @return [Session] Created failed session with error log
  #
  # Example:
  #   session = create_failed_session
  #   session = create_failed_session(error_message: "Custom error")
  def create_failed_session(error_message: "Test error occurred", **attributes)
    session = create_session(attributes.merge(status: :failed))

    session.logs.create!(
      content: error_message,
      level: "error"
    )

    session
  end

  # Run a block with the operator's elicitation-expiry knob set (or, with nil,
  # explicitly unset), restoring whatever was there before.
  #
  # Sets the real variable rather than stubbing ENV#[]: `Elicitation.default_expiration`
  # reads it per call, and a partial mocha stub on ENV#[] would break every other
  # ENV read the code path makes.
  #
  # @param value [String, nil] minutes, as the operator would write it
  def with_expiration_env(value)
    previous = ENV[Elicitation::EXPIRATION_ENV_VAR]
    if value.nil?
      ENV.delete(Elicitation::EXPIRATION_ENV_VAR)
    else
      ENV[Elicitation::EXPIRATION_ENV_VAR] = value
    end
    yield
  ensure
    if previous.nil?
      ENV.delete(Elicitation::EXPIRATION_ENV_VAR)
    else
      ENV[Elicitation::EXPIRATION_ENV_VAR] = previous
    end
  end
end
