# frozen_string_literal: true

# Real Codex rollouts, for tests of how Zimmer classifies and recovers a failed
# Codex turn.
#
# Every file under test/fixtures/files/codex_rollouts/ is a rollout written by
# the real codex-cli 0.146.0 binary, driven against a local fake of the ChatGPT
# backend that answered each request with the failure the file is named for
# (tadasant/zimmer#54). Each keeps Codex's own `session_meta`, `event_msg` and
# `compacted` records verbatim — only the `response_item` prompt records (the
# instructions Codex sends the model) are dropped, and the recorded `cwd` is
# neutralised. See CodexTurnError for the table of what each one says.
module CodexRolloutFixtures
  DIR = Rails.root.join("test/fixtures/files/codex_rollouts")

  # @param name [String, Symbol] the fixture's basename
  # @return [String] its JSONL
  def codex_rollout(name)
    File.read(DIR.join("#{name}.jsonl"))
  end

  # Write a fixture rollout where CodexTranscriptSource finds it for `session`:
  # under CodexHome.sessions_path, named for the session's thread id, which is
  # set on the session if it has none that looks like one.
  #
  # @param file_system [MockFileSystemAdapter]
  # @param session [Session] a codex session
  # @param name [String, Symbol] the fixture's basename
  # @param content [String, nil] JSONL to write instead of the named fixture
  # @return [String] the rollout path
  def plant_codex_rollout(file_system, session, name = nil, content: nil)
    thread_id = session.session_id.to_s
    unless thread_id.match?(CodexEventStream::UUID_PATTERN)
      thread_id = SecureRandom.uuid
      session.update!(session_id: thread_id)
    end

    dir = File.join(CodexHome.sessions_path, "2026", "09", "11")
    file_system.mkdir_p(dir)
    path = File.join(dir, "rollout-2026-09-11T13-23-47-#{thread_id}.jsonl")
    file_system.write(path, content || codex_rollout(name))
    path
  end

  # Append a later turn's records to a planted rollout, the way `codex exec
  # resume` appends to the same file.
  def append_codex_rollout(file_system, path, name)
    file_system.write(path, file_system.read(path) + codex_rollout(name).lines.drop(1).join)
  end
end
