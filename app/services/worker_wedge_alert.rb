# frozen_string_literal: true

# Turns an incident record from the host-side worker watchdog into a page in
# #eng-alerts.
#
# The watchdog (scripts/worker-watchdog.sh, installed as a systemd timer by
# scripts/install-worker-watchdog.sh) detects a container Docker still reports as
# `running` while every `docker exec` into it fails. That is the *signature* of the
# sysbox wedge from issue #502, and it is also all the signature establishes: the
# cause and the impact are separate questions the payload answers separately.
# It hands the incident to this service over
# `docker exec <web> bin/rails zimmer:worker_wedge_alert`.
#
# WHAT THIS PAGE MAY CLAIM
# ------------------------
# Only what the payload measured. Cause comes from the cgroup's `oom_kill` counter and
# the container's `OOMKilled` flag; impact comes from the live-process census; and each
# says "unknown" rather than guessing when its evidence is missing or unread.
#
# Both halves matter because both were got wrong (issue #774). On 2026-09-02 two hosts
# wedged twelve minutes apart with `OOMKilled=false`, `oom_kill=0` and five live workload
# processes each, on memory limits 5x apart -- and the page called it #502's cgroup OOM
# and called the worker idle, while production's job queue went on dequeuing throughout.
# `docker exec` sets up a *new* process in the container's namespaces, so its failure is
# a statement about starting processes, not about the ones already running. The census is
# the only field here that speaks to impact, and a census that could not be taken is not
# a census that came back empty.
#
# WHY THE ALERT ARRIVES THIS WAY
# ------------------------------
# Two constraints meet here. Detection cannot live in the app, because Zimmer's cron
# runs on GoodJob *in the worker* -- a job that watches the worker is a job that dies
# with it. And the alert cannot live on the host, because the Slack credentials are in
# Rails' encrypted credentials, not in anything a shell script on the droplet can read.
#
# So detection runs on the host and delivery runs in the *web* container, which shares
# the image, the credentials and the Redis dedup cache, and is untouched by the
# worker's cgroup. The watchdog needs no new secret and Zimmer needs no new endpoint.
#
# ROBUSTNESS OVER PRECISION
# -------------------------
# A malformed payload still pages. The payload is assembled by hand-rolled shell
# quoting on a host that is, by construction, in a bad state -- so a JSON parse failure
# is a plausible outcome, and "the watchdog says the worker is wedged" is the part
# worth delivering. Every field below is optional and every reader tolerates its
# absence; nothing here raises on shape.
class WorkerWedgeAlert
  SOURCE = "zimmer-worker-watchdog"

  # AlertService caps the details section at 2800 characters and truncates from the END,
  # which is where the runbook link is. These bound the two fields that can be long (the
  # OCI runtime error, and the recovery step list) so the framing around them can never
  # be squeezed out -- including the longest framing, which is a live census explaining
  # why a failed `docker exec` proves nothing. A test pins that worst case.
  MAX_ERROR_CHARS = 500
  MAX_STEPS_CHARS = 600

  # An unparseable payload is quoted back verbatim, bounded, so whoever reads the page
  # can see what the watchdog actually sent.
  MAX_RAW_CHARS = 1200

  # How each recovery outcome the script can report reads to a human, and whether it
  # leaves work for one. The script's vocabulary is closed; anything else is a bug in
  # one of the two halves and says so rather than being silently prettified.
  RECOVERY_OUTCOMES = {
    "restarted" => "recovered automatically -- the container restarted and `docker exec` answers again",
    "exited" => "the wedge was cleared but the container did not come back: it is `exited` and needs a redeploy",
    "failed" => "recovery ran and did not clear the wedge -- the container is still running and still unexecable",
    "skipped" => "recovery was skipped (see the steps below) -- nothing was killed",
    "disabled" => "recovery is switched off on this host (ZIMMER_WATCHDOG_RECOVER=0)"
  }.freeze

  RUNBOOK = "https://docs.zimmer.tadasant.com/operate/nested-docker/#when-the-worker-wedges"
  ISSUE_502 = "<https://github.com/tadasant/zimmer/issues/502|#502>"

  # @param payload [String] the watchdog's incident JSON, read from stdin
  # @return [Boolean] whatever AlertService#raise_alert returns
  def self.report(payload)
    new(payload).report
  end

  def initialize(payload)
    @raw = payload.to_s
    @data = parse
  end

  def report
    AlertService.raise_alert(title, details: details, source: SOURCE, dedup_key: dedup_key)
  end

  private

  attr_reader :raw, :data

  def parse
    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError, TypeError
    {}
  end

  def parsed? = data.present?

  def container = data["container"].is_a?(Hash) ? data["container"] : {}
  def probe = data["probe"].is_a?(Hash) ? data["probe"] : {}
  def cgroup = data["cgroup"].is_a?(Hash) ? data["cgroup"] : {}
  def recovery = data["recovery"].is_a?(Hash) ? data["recovery"] : {}

  def host = data["host"].presence || "unknown host"

  # The watchdog reports two shapes. `wedged` is the #502 case: a container Docker
  # still calls `running`. `absent` is its sequel — the same container, later, no
  # longer listed at all, which is what a cleared-but-not-restarted wedge looks like
  # and is just as silent, because nothing else in Zimmer notices a missing worker.
  def absent? = data["kind"].to_s == "absent"

  # A paused container fails every exec exactly the way the wedge does, so the
  # watchdog checks for it first and labels it rather than letting it masquerade.
  # Reporting "the worker is wedged and this is not over" about a container someone
  # paused is a claim the alarm never established, and an alarm that overstates once
  # is an alarm nobody trusts the next time.
  def paused? = data["kind"].to_s == "paused"

  def title
    return "Worker watchdog reported a wedge (unreadable payload)" unless parsed?
    return "No worker container running on #{host}" if absent?
    return "Worker container is paused on #{host}" if paused?

    "Worker container wedged on #{host}"
  end

  # Keyed to the container rather than to the host, so a wedge on a replacement
  # container after a redeploy pages again instead of being swallowed by the previous
  # one's throttle window. Falls back to the host when there is no id to key on.
  def dedup_key
    "worker_wedge:#{container["id"].presence || host}"
  end

  def details
    return unparseable_details unless parsed?
    return absent_details if absent?
    return paused_details if paused?

    lines = [
      impact_sentence,
      "",
      cause_sentence,
      "",
      "*Host:* #{host}",
      "*Container:* #{container["name"].presence || "?"} (`#{container["id"].presence || "?"}`)" \
      "#{" under `#{container["runtime"]}`" if container["runtime"].present?}",
      "*Detected:* #{data["detected_at"].presence || "?"}",
      "*Docker state:* Running=#{container["running"].inspect}, " \
      "OOMKilled=#{container["oom_killed"].inspect}, RestartCount=#{container["restart_count"] || "?"}" \
      "#{", limit #{human_bytes(container["memory_limit_bytes"])}" if container["memory_limit_bytes"].to_i.positive?}",
      "*Probe:* #{probe["consecutive_failures"] || "?"} consecutive `docker exec` failures " \
      "(#{probe["timeout_seconds"] || "?"}s timeout)",
      "*Cgroup:* #{census_summary}, oom_kill=#{oom_kill_summary}",
      "*Recovery:* #{recovery_description}"
    ]

    if (steps = recovery["steps"].presence)
      lines << "*Steps:* #{truncate(steps, MAX_STEPS_CHARS)}"
    end

    if (last_error = probe["last_error"].presence)
      lines << ""
      lines << "*Last exec error:*"
      lines << "```#{truncate(last_error, MAX_ERROR_CHARS)}```"
    end

    if unresolved?
      lines << ""
      lines << unresolved_sentence
    end

    lines.join("\n")
  end

  def paused_details
    <<~DETAILS
      The worker container is **paused**, so every `docker exec` into it fails and it is running no jobs or agent sessions. Its processes are all still there and intact.

      This is *not* the #502 cgroup-OOM wedge, and it is reversible: `docker unpause #{container["id"].presence || "<container>"}`. Nothing in Zimmer pauses a container on its own, so something or someone else did.

      *Host:* #{host}
      *Container:* #{container["name"].presence || "?"} (`#{container["id"].presence || "?"}`)
      *Detected:* #{data["detected_at"].presence || "?"}

      The watchdog took no action: a paused container is never recovered automatically, because unpausing is a decision for whoever paused it.
    DETAILS
  end

  def absent_details
    <<~DETAILS
      The worker container this watchdog reported wedged is no longer running at all — nothing matches its name on the host, so no jobs and no agent sessions are being executed. Every Zimmer cron job runs in the worker, so nothing else on this instance will notice.

      *Host:* #{host}
      *Container:* `#{container["id"].presence || "?"}` (last seen wedged)
      *Detected:* #{data["detected_at"].presence || "?"}

      This needs a redeploy to bring a worker back. The watchdog will keep repeating this until one is running: #{RUNBOOK}
    DETAILS
  end

  def unparseable_details
    "The worker watchdog reported a wedged worker, but its payload could not be parsed as JSON, " \
    "so the detail below is raw. Treat it as a real incident anyway: the watchdog sends nothing at " \
    "all until a run of consecutive `docker exec` probes has failed against a container Docker " \
    "still reports as running. Runbook: #{RUNBOOK}\n\n```#{truncate(raw.strip, MAX_RAW_CHARS)}```"
  end

  def recovery_description
    outcome = recovery["outcome"].to_s
    known = RECOVERY_OUTCOMES[outcome]
    return "#{outcome.presence || "not reported"} — unrecognised outcome, check the watchdog's journal" if known.nil?

    known
  end

  # `restarted` is the only outcome that means nobody has to do anything. Everything
  # else -- including an outcome this class does not recognise, and a missing one --
  # leaves the container unexecable, so it must fail towards telling someone. It says
  # nothing about whether work is still running: that is `workload_census`'s answer,
  # and the sentence below defers to it.
  def unresolved?
    recovery["outcome"].to_s != "restarted"
  end

  # WHAT WEDGED IT. The signature the watchdog triggers on -- running container, failing
  # exec -- is shared by #502's cgroup OOM and by whatever produced the 2026-09-02
  # firings, which carried no OOM at all. So read the OOM fields and say only what they
  # support. Getting this branch backwards would under-state a real #502 wedge, which is
  # why it is pinned by tests rather than by a careful read.
  def cause_sentence
    case oom_evidence
    when :present
      "An OOM kill is recorded against the container or its cgroup, so this is the sysbox " \
      "cgroup-OOM wedge from #{ISSUE_502}."
    when :absent
      "The cgroup's `oom_kill` counter is 0, so no OOM kill landed in it: this is *not* the " \
      "cgroup-OOM wedge from #{ISSUE_502} and its cause is unknown. #502's ladder may still " \
      "clear it -- clearing it is not a diagnosis."
    else
      "The cgroup's `oom_kill` counter is not in this payload, so whether this is the " \
      "cgroup-OOM wedge from #{ISSUE_502} is unknown -- a kill inside the cgroup does not " \
      "have to set `OOMKilled` on the container."
    end
  end

  # WHAT IT COST. `docker exec` failing is a statement about starting a new process, not
  # about the ones already running, so the live-process census is the only thing here that
  # can speak to impact.
  def impact_sentence
    opening = "The worker container reports `running` while `docker exec` into it fails"

    case workload_census
    when :busy
      count = workload_process_count
      "#{opening}. #{count} #{"process".pluralize(count)} #{count == 1 ? "is" : "are"} still alive in " \
      "its cgroup, and `docker exec` starts a *new* process in the container's namespaces -- its " \
      "failure says nothing about processes that were already running. Whether the worker is still " \
      "executing jobs and agent sessions is unverified: read its logs or the queue's head age before " \
      "calling this an outage."
    when :empty
      "#{opening}, and no workload processes are left in its cgroup, so it is running no jobs and " \
      "no agent sessions."
    else
      "#{opening}. The watchdog could not take a census of its cgroup, so whether it is still " \
      "executing jobs and agent sessions is unknown."
    end
  end

  def unresolved_sentence
    ladder = "Recovery ladder and the manual last rung (`docker rm` plus a redeploy) are in the runbook: #{RUNBOOK}"

    case workload_census
    when :busy
      "This one is not over: `docker exec` still fails and the wedge was not cleared. Whether the " \
      "worker is still running work is unverified -- #{workload_process_count} of its processes are " \
      "alive -- so establish that it is idle before reaching for the destructive last rung. #{ladder}"
    when :empty
      "This one is not over: the worker is still not running work. #{ladder}"
    else
      "This one is not over: `docker exec` still fails and the wedge was not cleared. Whether the " \
      "worker is still running work is unknown, because the cgroup census could not be taken. #{ladder}"
    end
  end

  # :present / :absent / :unknown.
  #
  # Either signal alone is enough to say an OOM happened. Only the cgroup counter can say
  # one did NOT: `OOMKilled` is set when the container's init process is the one killed,
  # and #502's kill lands on a child inside the cgroup, so `OOMKilled=false` on its own
  # rules nothing out. And the counter speaks only when the scope was located -- the
  # payload carries `null` for a counter nobody could read.
  def oom_evidence
    kills = cgroup_located? ? cgroup["oom_kills"] : nil

    return :present if container["oom_killed"] == true || kills.to_i.positive?
    return :absent if kills.present?

    :unknown
  end

  # :busy / :empty / :unknown. The recovery gate refuses to read "could not enumerate" as
  # "empty", and so does this page. A positive count can only come from a walk that
  # worked, so it stands on its own; calling the container EMPTY takes the script's
  # `census_known`, which is the only thing that distinguishes a walk that found nothing
  # from one that never ran.
  def workload_census
    count = cgroup["workload_process_count"]

    return :unknown if count.nil?
    return :busy if count.to_i.positive?

    cgroup["census_known"] == true ? :empty : :unknown
  end

  # Nothing under the cgroup was read when the scope could not be located, and `path` is
  # empty exactly then -- so its counters are defaults rather than readings.
  def cgroup_located? = cgroup["path"].present?

  def workload_process_count = cgroup["workload_process_count"].to_i

  # The evidence block prints readings. An unread field says so rather than rendering the
  # zero it was defaulted to, which would contradict the sentences above it.
  def census_summary
    return "census unavailable" if workload_census == :unknown

    "#{workload_process_count} live workload processes (#{cgroup["process_count"] || "?"} total)"
  end

  def oom_kill_summary
    kills = cgroup_located? ? cgroup["oom_kills"] : nil

    kills.nil? ? "unread" : kills
  end

  def truncate(value, limit)
    text = value.to_s
    return text if text.length <= limit

    "#{text[0, limit]}… (truncated)"
  end

  def human_bytes(bytes)
    value = bytes.to_i
    return "#{value} B" if value < 1024

    units = %w[KiB MiB GiB TiB]
    index = -1
    while value >= 1024 && index < units.length - 1
      value = value.to_f / 1024
      index += 1
    end
    format("%.1f %s", value, units[index])
  end
end
