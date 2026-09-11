# frozen_string_literal: true

# Real Pi session transcripts, for tests of how Zimmer classifies and recovers a
# failed Pi turn.
#
# Every file under test/fixtures/files/pi_sessions/ was written by the real
# `pi 0.84.4` binary (the version in the Zimmer base image) driven against a
# local OpenAI-completions stub that answered each request with the failure the
# file is named for (tadasant/zimmer#856). Pi's own records are kept verbatim —
# including the repeated error records its internal retries produce — and only
# two fields are neutralised: the session header's `cwd` and its `id`, which is
# rewritten to SESSION_ID so #plant_pi_session can point a fixture at whatever
# session a test built. See PiTurnError for the table of what each one says.
module PiSessionFixtures
  DIR = Rails.root.join("test/fixtures/files/pi_sessions")

  # The placeholder session id every fixture's header carries.
  SESSION_ID = "11111111-2222-3333-4444-555555555555"

  # @param name [String, Symbol] the fixture's basename
  # @return [String] its JSONL
  def pi_session(name)
    File.read(DIR.join("#{name}.jsonl"))
  end

  # The same JSONL with the header re-stamped for `session_id`, which is what Pi
  # itself would have written had the run used that id.
  def pi_session_for(name, session_id)
    pi_session(name).gsub(SESSION_ID, session_id.to_s)
  end

  # Write a fixture transcript where PiTranscriptSource finds it for `session`:
  # inside the clone's own `.pi/sessions/`, under the `<timestamp>_<session id>`
  # name Pi uses for a file it created itself.
  #
  # @param file_system [MockFileSystemAdapter]
  # @param session [Session] a pi session
  # @param name [String, Symbol] the fixture's basename
  # @param working_directory [String] the clone path
  # @param content [String, nil] JSONL to write instead of the named fixture
  # @return [String] the transcript path
  def plant_pi_session(file_system, session, name = nil, working_directory:, content: nil)
    dir = PiTranscriptSource.session_directory(working_directory: working_directory)
    file_system.mkdir_p(dir)
    path = File.join(dir, "2026-09-11T20-34-16-693Z_#{session.session_id}.jsonl")
    file_system.write(path, content || pi_session_for(name, session.session_id))
    path
  end

  # A transcript whose terminal error carries a wording Zimmer does not know and
  # no HTTP status — the one shape that reaches the unclassified-failure alert.
  #
  # Derived rather than captured, and it has to be: an unknown wording is by
  # definition one no run has produced. The RECORD is a real one (the 401 run's,
  # verbatim) and only `errorMessage` is replaced, so what is hypothetical here is
  # the provider's prose and nothing about Pi's format.
  UNKNOWN_WORDING = "The inference mesh entered an unrecoverable state."

  def pi_session_with_unknown_error(session_id)
    lines = pi_session_for(:unauthorized_401, session_id).lines
    record = JSON.parse(lines.last)
    record["message"]["errorMessage"] = UNKNOWN_WORDING
    (lines[0..-2] + [ "#{JSON.generate(record)}\n" ]).join
  end

  # Append a later turn's records to a planted transcript, the way a resumed
  # `pi --session-id` appends to the same file. The fixture's own header and
  # bookkeeping records are dropped, since the file already has them.
  def append_pi_session(file_system, path, name, session)
    later = pi_session_for(name, session.session_id).lines.reject do |line|
      record = JSON.parse(line) rescue nil
      record.nil? || %w[session model_change thinking_level_change].include?(record["type"])
    end
    file_system.write(path, file_system.read(path) + later.join)
  end
end
