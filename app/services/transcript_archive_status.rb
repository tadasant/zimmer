# frozen_string_literal: true

# What the transcript archive on disk actually looks like, right now.
#
# Every reader of the archive — Api::V1::TranscriptArchivesController#download and
# #status, and the get_transcript_archive MCP tool — used to answer "there isn't one"
# with the same hardcoded sentence:
#
#   "No transcript archive exists yet. The archive is built every 10 minutes."
#
# That sentence asserts a recovery rather than reporting a state. It tells the caller
# the failure is transient and costs them ten minutes before they find out otherwise —
# which is exactly what happened while the writer and the readers were looking at two
# different container filesystems (#714): the wait could never help, because no run of
# the job could ever put a file where the reader was looking.
#
# So this class reports only what it observed, and says which path it observed it at.
# The caller can go and check that path; a cadence promise cannot be checked at all.
# The three states it distinguishes:
#
#   never_built  neither the zip nor its metadata sidecar is there. The job has not
#                completed a run against this directory.
#   missing      the metadata sidecar is there but the zip is not — a run finished
#                once and the zip has since been removed or half-written.
#   present      the zip is there. `stale?` then says whether it is recent enough to
#                be treated as current; a stale archive is still served, with the age
#                stated, rather than withheld.
#
class TranscriptArchiveStatus
  # Reads the archive directory once and holds the answer for this instance's
  # lifetime. Instances are cheap and short-lived (one per request), so a freshly
  # written archive is visible to the very next reader — but within one request the
  # answer must not change, or a 200 could be decided on a file that a later line
  # then fails to stat.
  def initialize(archive_path: nil, metadata_path: nil, stale_after: TranscriptArchiveJob::STALE_AFTER)
    @archive_path = archive_path || TranscriptArchiveJob.archive_path
    @metadata_path = metadata_path || TranscriptArchiveJob.metadata_path
    @stale_after = stale_after
  end

  attr_reader :archive_path, :metadata_path

  def present?
    return @present unless @present.nil?

    @present = File.exist?(archive_path)
  end

  # A previous run left its bookkeeping behind, so the job has completed at least
  # once against this directory even if the zip is gone now.
  def metadata_present?
    File.exist?(metadata_path)
  end

  def state
    return :present if present?
    return :missing if metadata_present?

    :never_built
  end

  def metadata
    @metadata ||= begin
      metadata_present? ? JSON.parse(File.read(metadata_path)) : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end
  end

  # When the archive was built, as recorded by the job. Falls back to the zip's
  # mtime so a readable archive with an unreadable sidecar still reports an age
  # rather than nothing.
  def generated_at
    recorded = metadata["generated_at"]
    parsed = recorded.present? ? (Time.zone.parse(recorded) rescue nil) : nil
    return parsed if parsed
    return file_mtime if present?

    nil
  end

  def session_count
    metadata["session_count"].to_i
  end

  # How many changed sessions the last run deferred to a later tick. Non-zero means the
  # archive is a correct prefix of the corpus rather than the whole of it — see
  # TranscriptArchiveJob::MAX_SESSIONS_PER_RUN. A sidecar written before this field
  # existed has no opinion, and reads as complete.
  def deferred_count
    metadata["deferred_count"].to_i
  end

  # Whether the last run got through its whole backlog. Distinct from `stale?`: a
  # mid-bootstrap archive is freshly written (so not stale) and still incomplete, which is
  # exactly the case a caller cannot otherwise detect.
  def complete?
    return true unless metadata.key?("deferred_count")

    deferred_count.zero?
  end

  # One line for a reader who got a partial archive, or nil when it is whole.
  def incompleteness_note
    return nil if complete?

    "This archive covers #{session_count} session(s) and the last build deferred " \
      "#{deferred_count} more to a later run, so it is a prefix of the corpus rather than " \
      "all of it. TranscriptArchiveJob archives a bounded slice per run; it will catch up " \
      "over subsequent ticks."
  end

  def file_size_bytes
    recorded = metadata["file_size_bytes"]
    return recorded.to_i if recorded.present?
    return file_size.to_i if present?

    0
  end

  def age
    at = generated_at
    at ? (Time.current - at) : nil
  end

  def stale?
    return false unless present?

    current = age
    current.nil? || current > @stale_after
  end

  # One line describing the age, for a reader that got an archive but should know
  # how old it is. nil when the archive is fresh (or absent).
  def staleness_note
    return nil unless stale?

    if (current = age)
      "This archive was built #{humanized_duration(current)} ago, which is older than the " \
        "#{humanized_duration(@stale_after)} it is expected to be rebuilt within. " \
        "#{JOB_HEALTH_HINT}"
    else
      "This archive's build time could not be read, so its age is unknown. #{JOB_HEALTH_HINT}"
    end
  end

  # What to tell a caller who asked for an archive that is not there. States the
  # observation and the path it was made at, so the claim is one the caller can go
  # and falsify — rather than a schedule they can only wait on.
  def unavailable_message
    case state
    when :missing
      "The transcript archive is missing at #{archive_path}. A previous build recorded " \
        "#{session_count} session(s)#{recorded_at_clause}, so TranscriptArchiveJob has completed a run " \
        "against this directory before and the zip has since been removed or was left half-written. " \
        "#{JOB_HEALTH_HINT}"
    else
      "No transcript archive has ever been built at #{archive_path} — neither the zip nor its " \
        "metadata sidecar (#{File.basename(metadata_path)}) is present, so TranscriptArchiveJob has not " \
        "completed a run against this directory. Waiting will not help on its own. #{JOB_HEALTH_HINT}"
    end
  end

  JOB_HEALTH_HINT = "Check the `transcript_archive` cron job (it is scheduled every 10 minutes, and " \
                    "can be disabled per-deployment in good_job_settings.cron_keys_disabled) and the " \
                    "worker's `[TranscriptArchiveJob]` log lines."

  private

  # The disk is the thing this class exists to be sceptical about, so neither stat is
  # allowed to turn a missing file into a 500 — the archive can be replaced (the job
  # writes by atomic rename) between the `exist?` above and the read here.
  def file_mtime
    File.mtime(archive_path).in_time_zone
  rescue SystemCallError
    nil
  end

  def file_size
    File.size(archive_path)
  rescue SystemCallError
    0
  end

  def recorded_at_clause
    at = metadata["generated_at"]
    at.present? ? " at #{at}" : ""
  end

  def humanized_duration(seconds)
    seconds = seconds.to_i
    return "#{seconds} second#{'s' unless seconds == 1}" if seconds < 60
    return "#{(seconds / 60.0).round} minute#{'s' unless (seconds / 60.0).round == 1}" if seconds < 3600
    return "#{(seconds / 3600.0).round(1)} hours" if seconds < 86_400

    "#{(seconds / 86_400.0).round(1)} days"
  end
end
