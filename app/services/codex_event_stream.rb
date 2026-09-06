# frozen_string_literal: true

# CodexEventStream — reader for the JSONL event stream `codex exec --json`
# prints to stdout.
#
# Zimmer has always passed `--json` and then sent stdout to /dev/null, learning
# what the agent was doing only by polling Codex's rollout file. That left the
# transcript pipeline guessing at the one thing the stream answers on its very
# first line: WHICH rollout belongs to this session (#109).
#
# == The stream ==
#
# Verified against codex-cli 0.146.0 (the version in the Zimmer base image), one
# JSON object per line:
#
#   {"type":"thread.started","thread_id":"01a07412-4d9a-78f0-aad9-2cde1bf7586e"}
#   {"type":"turn.started"}
#   {"type":"item.completed","item":{"id":"item_0","type":"agent_message",...}}
#   {"type":"error","message":"..."}
#   {"type":"turn.failed","error":{"message":"..."}}
#   {"type":"turn.completed","usage":{...}}
#
# `thread_id` is the same UUID that names the rollout file
# (`rollout-<ts>-<uuid>.jsonl`), is what the rollout's `session_meta` line
# carries as `id`, and is what `codex exec resume <uuid>` requires. It is
# printed before the model is even contacted — on the failing 401 run used to
# verify these shapes it was the first of fourteen lines.
#
# == Why a file, not a pipe ==
#
# CodexRuntimeAdapter redirects stdout into `codex_events.jsonl` inside the
# working directory, exactly as it already redirects stderr into
# `codex_stderr.log`, and this class reads it back. A pipe would be the more
# obvious "consume the stream", and it is the wrong shape here: Zimmer's
# monitoring loop does not always outlive the process it watches
# (ProcessLifecycleManager#resume_monitoring exists to re-attach to an agent
# whose worker was restarted mid-turn). A pipe whose read end goes away leaves
# the child writing into a broken pipe — SIGPIPE, agent dead mid-turn — or, if
# nobody drains it, blocked on a full buffer. A file has neither failure mode,
# survives the restart, and is readable by whichever process is monitoring now.
#
# The adapter truncates the file on every spawn (`"w"`), so the stream never
# describes an earlier run of the same clone.
#
# == Reading cost ==
#
# The event log grows for the life of the turn, so #thread_id streams lines
# through the file-system adapter and stops at the first one that carries an id
# rather than materializing the file. The poller asks on every cycle.
class CodexEventStream
  # Stop looking for the thread id after this many lines. Codex emits
  # `thread.started` first, so the only thing a larger budget would buy is a
  # long scan of a stream that is never going to answer.
  THREAD_ID_SCAN_LIMIT = 50

  # Codex thread ids are UUIDs. The id is written straight into
  # `sessions.session_id`, which is uniquely indexed and is what every later
  # `codex exec resume` targets, so anything that is not shaped like a UUID is
  # refused rather than persisted.
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # @param working_directory [String, nil] the cwd Codex was spawned from
  # @param file_system [FileSystemAdapter, nil] injected for testing
  def initialize(working_directory:, file_system: nil)
    @working_directory = working_directory
    @file_system = file_system || RealFileSystemAdapter.new
  end

  # @return [String, nil] path to the event log, or nil without a working dir
  def path
    CodexRuntimeAdapter.event_log_path(@working_directory)
  end

  # @return [Boolean] whether Codex has created the event log yet
  def available?
    path.present? && @file_system.exists?(path)
  end

  # The Codex-minted thread UUID for the run currently writing this log.
  #
  # nil means "not knowable from the stream yet" — no log, no `thread_id` line
  # flushed, or a malformed head — never "there is no thread". Callers keep
  # their existing fallbacks for that case.
  #
  # @return [String, nil]
  def thread_id
    return nil unless available?

    scanned = 0
    @file_system.each_line(path) do |line|
      scanned += 1
      return nil if scanned > THREAD_ID_SCAN_LIMIT

      candidate = parse_line(line)&.dig("thread_id")
      return candidate if candidate.is_a?(String) && candidate.match?(UUID_PATTERN)
    end
    nil
  rescue => e
    Rails.logger.warn "[CodexEventStream] Failed to read thread id from #{path}: #{e.message}"
    nil
  end

  # Every parsed event in the stream, in order. Malformed lines are dropped —
  # the last line of a live stream is routinely half-flushed.
  #
  # @return [Array<Hash>]
  def events
    return [] unless available?

    @file_system.read(path).to_s.lines.filter_map { |line| parse_line(line) }
  rescue => e
    Rails.logger.warn "[CodexEventStream] Failed to read #{path}: #{e.message}"
    []
  end

  private

  # A single JSONL line, or nil when it is blank, half-written, or not an
  # object. Deliberately silent: a partially flushed final line is the normal
  # state of a stream that is still being written, not a fault to report.
  def parse_line(line)
    stripped = line.to_s.strip
    return nil if stripped.empty?

    parsed = JSON.parse(stripped)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end
end
