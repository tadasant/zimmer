# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class WorkerWedgeAlertTest < ActiveSupport::TestCase
  # A full incident, exactly as scripts/worker-watchdog.sh assembles it. Kept verbatim
  # rather than built from a helper: the shell script is the only producer, and a test
  # that constructs the payload its own way would stop testing the contract between
  # them.
  FULL_PAYLOAD = <<~JSON
    {
      "schema": 1,
      "host": "zimmer-staging",
      "detected_at": "2026-08-16T16:20:03Z",
      "container": {
        "id": "8f1c2b3d4e5f",
        "name": "zimmer-worker-staging-staging-9e95b4d",
        "runtime": "sysbox-runc",
        "running": true,
        "oom_killed": true,
        "restart_count": 0,
        "memory_limit_bytes": 2147483648,
        "started_at": "2026-08-16T08:55:11Z"
      },
      "probe": {
        "consecutive_failures": 3,
        "timeout_seconds": 20,
        "last_error": "OCI runtime exec failed: exec failed: container_linux.go:439: starting container process caused: process_linux.go:119: executing setns process caused: exit status 1"
      },
      "cgroup": {
        "path": "/sys/fs/cgroup/system.slice/docker-8f1c.scope",
        "census_known": true,
        "process_count": 1,
        "workload_process_count": 0,
        "oom_events": 1,
        "oom_kills": 1
      },
      "recovery": {
        "attempted": true,
        "outcome": "exited",
        "steps": "killing containerd shim(s) 4242; container left the running state; docker start failed: redundant container registration"
      }
    }
  JSON

  # The two real firings of 2026-09-02 (issue #774): no OOM anywhere, five live workload
  # processes, on hosts whose memory limits differ 5x. Both #774's false claims -- #502's
  # cgroup OOM, and an idle worker -- are claims about exactly this payload.
  NO_OOM_BUSY_PAYLOAD = <<~JSON
    {
      "schema": 1,
      "host": "zimmer-prod",
      "detected_at": "2026-09-02T06:43:53Z",
      "container": {
        "id": "a1b2c3d4e5f6",
        "name": "zimmer-worker-production",
        "runtime": "sysbox-runc",
        "running": true,
        "oom_killed": false,
        "restart_count": 0,
        "memory_limit_bytes": 10737418240,
        "started_at": "2026-09-01T22:10:00Z"
      },
      "probe": {
        "consecutive_failures": 3,
        "timeout_seconds": 20,
        "last_error": "unsafe procfs detected: openat2 fsmount:fscontext:proc/thread-self/fd/: operation not permitted"
      },
      "cgroup": {
        "path": "/sys/fs/cgroup/system.slice/docker-a1b2.scope",
        "census_known": true,
        "process_count": 6,
        "workload_process_count": 5,
        "oom_events": 0,
        "oom_kills": 0
      },
      "recovery": {
        "attempted": false,
        "outcome": "skipped",
        "steps": "5 process(es) other than the init shim are still alive in the cgroup"
      }
    }
  JSON

  test "pages with the container in the title and the evidence in the body" do
    captured = capture_alert { WorkerWedgeAlert.report(FULL_PAYLOAD) }

    assert_equal "Worker container wedged on zimmer-staging", captured[:title]
    assert_equal WorkerWedgeAlert::SOURCE, captured[:source]

    details = captured[:details]
    assert_includes details, "zimmer-worker-staging-staging-9e95b4d"
    assert_includes details, "sysbox-runc"
    assert_includes details, "OOMKilled=true"
    assert_includes details, "3 consecutive `docker exec` failures"
    assert_includes details, "0 live workload processes"
    assert_includes details, "oom_kill=1"
    assert_includes details, "2.0 GiB"
    assert_includes details, "setns process caused"
    assert_includes details, "issues/502"
  end

  # The four combinations that matter. Cause comes from the OOM fields and impact from the
  # census; each is read independently, and getting either backwards is silent until the
  # next wedge.
  test "OOM evidence plus an empty cgroup: names #502 and says the worker is idle" do
    details = capture_alert { WorkerWedgeAlert.report(FULL_PAYLOAD) }[:details]

    assert_includes details, "An OOM kill is recorded"
    assert_includes details, "this is the sysbox cgroup-OOM wedge from"
    assert_includes details, "issues/502"
    assert_includes details, "no workload processes are left in its cgroup, so it is running no jobs"
    assert_not_includes details, "is unverified"
  end

  test "OOM evidence with live processes: names #502 but does not claim the worker is idle" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["cgroup"]["workload_process_count"] = 5
    payload["cgroup"]["process_count"] = 6

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "An OOM kill is recorded"
    assert_includes details, "5 processes are still alive in its cgroup"
    assert_includes details, "is unverified"
    assert_not_includes details, "so it is running no jobs and no agent sessions"
  end

  test "no OOM evidence with an empty cgroup: refuses #502 but still reports the worker idle" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["container"]["oom_killed"] = false
    payload["cgroup"]["oom_kills"] = 0
    payload["cgroup"]["oom_events"] = 0

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "so no OOM kill landed in it"
    assert_includes details, "*not* the cgroup-OOM wedge"
    assert_includes details, "its cause is unknown"
    assert_includes details, "no workload processes are left in its cgroup, so it is running no jobs"
  end

  # The regression the issue was filed for: neither false claim may appear.
  test "no OOM evidence with live processes: claims neither the cause nor the impact" do
    details = capture_alert { WorkerWedgeAlert.report(NO_OOM_BUSY_PAYLOAD) }[:details]

    assert_includes details, "so no OOM kill landed in it"
    assert_includes details, "*not* the cgroup-OOM wedge"
    assert_includes details, "5 processes are still alive in its cgroup"
    assert_includes details, "says nothing about processes that were already running"
    assert_includes details, "is unverified"

    assert_not_includes details, "this is the sysbox cgroup-OOM wedge from"
    assert_not_includes details, "so it is running no jobs and no agent sessions"
    assert_not_includes details, "the worker is still not running work"
  end

  # `docker exec` failing says nothing about what is already running, so the unresolved
  # trailer cannot inherit the idle claim from the recovery outcome either.
  test "the unresolved trailer defers to the census rather than to the recovery outcome" do
    details = capture_alert { WorkerWedgeAlert.report(NO_OOM_BUSY_PAYLOAD) }[:details]

    assert_includes details, "This one is not over"
    assert_includes details, "5 of its processes are alive"
    assert_includes details, "establish that it is idle before reaching for the destructive last rung"
    assert_includes details, WorkerWedgeAlert::RUNBOOK
  end

  test "one live process is counted in the singular" do
    payload = JSON.parse(NO_OOM_BUSY_PAYLOAD)
    payload["cgroup"]["workload_process_count"] = 1

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "1 process is still alive in its cgroup"
  end

  # A census that could not be taken is not a census that came back empty -- the recovery
  # gate refuses to conflate them, and the page must not either.
  test "a census the watchdog could not take is reported as unknown, not as idle" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["cgroup"]["census_known"] = false
    payload["cgroup"]["workload_process_count"] = 0

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "could not take a census of its cgroup"
    assert_includes details, "is unknown"
    assert_includes details, "This one is not over"
    assert_includes details, "the cgroup census could not be taken"
    assert_not_includes details, "so it is running no jobs and no agent sessions"
  end

  # An unreadable cgroup used to default `oom_kill` to 0, which is indistinguishable from
  # a counter that genuinely read zero. The script sends `null` and the page must not read
  # it -- or a stale 0 from an older watchdog -- as proof no OOM happened.
  test "a cgroup the watchdog could not locate leaves the cause unknown, not ruled out" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["container"]["oom_killed"] = false
    payload["cgroup"] = { "path" => "", "census_known" => false, "process_count" => 0,
                          "workload_process_count" => 0, "oom_events" => nil, "oom_kills" => nil }

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "counter is not in this payload"
    assert_not_includes details, "so no OOM kill landed in it"
    # And the evidence block must not print the defaults as if they were readings.
    assert_includes details, "*Cgroup:* census unavailable, oom_kill=unread"
    assert_not_includes details, "0 live workload processes"
  end

  test "an older payload that defaulted oom_kill to 0 with no cgroup located is still unknown" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["container"]["oom_killed"] = false
    payload["cgroup"] = { "path" => "", "process_count" => 0, "workload_process_count" => 0,
                          "oom_events" => 0, "oom_kills" => 0 }

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "counter is not in this payload"
    assert_not_includes details, "so no OOM kill landed in it"
  end

  # A census that failed defaults the count to 0 exactly the way an empty container reads.
  # Only `census_known` tells them apart, so its absence -- a watchdog installed before the
  # field existed -- can never license the idle claim.
  test "a zero count without census_known is unknown rather than idle" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["cgroup"].delete("census_known")

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "could not take a census of its cgroup"
    assert_not_includes details, "so it is running no jobs and no agent sessions"
    assert_includes details, "*Cgroup:* census unavailable"
  end

  # A positive count can only come from a walk that worked, so it needs no flag to vouch
  # for it -- and an older watchdog must still get the live-process wording.
  test "a positive count stands on its own without census_known" do
    payload = JSON.parse(NO_OOM_BUSY_PAYLOAD)
    payload["cgroup"].delete("census_known")

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "5 processes are still alive in its cgroup"
    assert_includes details, "*Cgroup:* 5 live workload processes (6 total)"
  end

  test "a payload carrying no OOM fields at all says the cause is unknown" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["container"].delete("oom_killed")
    payload["cgroup"].delete("oom_kills")

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "counter is not in this payload"
    assert_not_includes details, "An OOM kill is recorded"
    assert_includes details, "oom_kill=unread"
  end

  # `OOMKilled=false` with a non-zero cgroup counter is still an OOM: the kill landed
  # inside the cgroup, which is exactly #502's shape.
  test "a cgroup oom_kill counts as OOM evidence even when OOMKilled is false" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["container"]["oom_killed"] = false
    payload["cgroup"]["oom_kills"] = 2

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "An OOM kill is recorded"
    assert_includes details, "issues/502"
  end

  test "keys dedup on the container id so a replacement container can page again" do
    captured = capture_alert { WorkerWedgeAlert.report(FULL_PAYLOAD) }

    assert_equal "worker_wedge:8f1c2b3d4e5f", captured[:dedup_key]
  end

  test "an unrecovered wedge says so and points at the runbook" do
    details = capture_alert { WorkerWedgeAlert.report(FULL_PAYLOAD) }[:details]

    assert_includes details, "needs a redeploy"
    assert_includes details, "This one is not over"
    assert_includes details, WorkerWedgeAlert::RUNBOOK
  end

  test "a recovered wedge does not tell anyone to go and fix it" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["recovery"] = { "attempted" => true, "outcome" => "restarted", "steps" => "killing containerd shim(s) 4242; exec answers again" }

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "recovered automatically"
    assert_not_includes details, "This one is not over"
  end

  test "each recovery outcome the script can emit renders as prose" do
    WorkerWedgeAlert::RECOVERY_OUTCOMES.each_key do |outcome|
      payload = JSON.parse(FULL_PAYLOAD)
      payload["recovery"]["outcome"] = outcome

      details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

      assert_includes details, WorkerWedgeAlert::RECOVERY_OUTCOMES.fetch(outcome),
                      "expected the #{outcome} outcome to be described in the alert"
      assert_not_includes details, "unrecognised outcome"
    end
  end

  test "an outcome the script never emits is flagged rather than prettified" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["recovery"]["outcome"] = "teleported"

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "unrecognised outcome"
  end

  # An outcome nobody recognises means nobody knows the worker recovered, so the alert
  # has to fail towards telling someone. Getting this backwards is silent in exactly
  # the way this whole mechanism exists to prevent.
  test "an unrecognised outcome is still treated as unresolved" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["recovery"]["outcome"] = "teleported"

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "This one is not over"
    assert_includes details, WorkerWedgeAlert::RUNBOOK
  end

  test "a missing recovery block is treated as unresolved" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload.delete("recovery")

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "This one is not over"
  end

  # The watchdog's second shape: the container it reported wedged is no longer listed
  # at all. `docker ps` goes quiet, so without its own page this failure is invisible.
  test "an absent worker pages with its own title and body" do
    payload = {
      "schema" => 1,
      "kind" => "absent",
      "host" => "zimmer-staging",
      "detected_at" => "2026-08-16T17:20:03Z",
      "container" => { "id" => "8f1c2b3d4e5f", "running" => false },
      "probe" => { "consecutive_failures" => 7, "last_error" => "no container matches 'zimmer-worker'" },
      "recovery" => { "attempted" => false, "outcome" => "exited", "steps" => "" }
    }

    captured = capture_alert { WorkerWedgeAlert.report(payload.to_json) }

    assert_equal "No worker container running on zimmer-staging", captured[:title]
    assert_includes captured[:details], "no longer running at all"
    assert_includes captured[:details], "8f1c2b3d4e5f"
    assert_includes captured[:details], "redeploy"
    assert_includes captured[:details], WorkerWedgeAlert::RUNBOOK
    # Same container, same throttle bucket as the wedge page that preceded it.
    assert_equal "worker_wedge:8f1c2b3d4e5f", captured[:dedup_key]
  end

  # A paused container fails exec exactly like the wedge does. Calling it a wedge —
  # and asserting "this one is not over" about a container `docker unpause` fixes —
  # is the kind of overstatement that costs an alarm its credibility.
  test "a paused worker is reported as paused, not as a wedge" do
    payload = {
      "schema" => 1,
      "kind" => "paused",
      "host" => "zimmer-staging",
      "detected_at" => "2026-08-16T17:30:03Z",
      "container" => { "id" => "8f1c2b3d4e5f", "name" => "zimmer-worker-staging", "running" => true },
      "recovery" => { "attempted" => false, "outcome" => "skipped", "steps" => "never recovered automatically" }
    }

    captured = capture_alert { WorkerWedgeAlert.report(payload.to_json) }

    assert_equal "Worker container is paused on zimmer-staging", captured[:title]
    assert_includes captured[:details], "docker unpause"
    assert_includes captured[:details], "not* the #502"
    assert_includes captured[:details], "running no jobs"
    # The claims the wedge page makes must NOT appear: nothing here established them.
    assert_not_includes captured[:details], "This one is not over"
    assert_not_includes captured[:details], "cgroup-OOM wedge from"
  end

  # The producer is hand-rolled shell quoting running on a host that is by definition
  # in a bad state. If it emits something unparseable, the page still has to happen --
  # losing the alert to a formatting bug is the one failure this whole mechanism
  # exists to prevent.
  test "an unparseable payload still pages, carrying the raw text" do
    captured = capture_alert { WorkerWedgeAlert.report("{not json at all") }

    assert_equal "Worker watchdog reported a wedge (unreadable payload)", captured[:title]
    assert_includes captured[:details], "{not json at all"
    assert_includes captured[:details], WorkerWedgeAlert::RUNBOOK
    assert_equal "worker_wedge:unknown host", captured[:dedup_key]
  end

  test "an empty payload still pages" do
    captured = capture_alert { WorkerWedgeAlert.report("") }

    assert_equal "Worker watchdog reported a wedge (unreadable payload)", captured[:title]
  end

  test "a payload missing every optional field pages without raising" do
    captured = capture_alert { WorkerWedgeAlert.report('{"host":"zimmer-prod"}') }

    assert_equal "Worker container wedged on zimmer-prod", captured[:title]
    assert_equal "worker_wedge:zimmer-prod", captured[:dedup_key]
    assert_includes captured[:details], "This one is not over"
  end

  test "a long exec error is truncated so it cannot squeeze out the framing" do
    payload = JSON.parse(FULL_PAYLOAD)
    payload["probe"]["last_error"] = "x" * 5_000

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_includes details, "(truncated)"
    assert_operator details.length, :<, AlertService::DETAILS_SECTION_MAX_CHARS
  end

  # The busiest framing is the longest one -- a live census spells out why `docker exec`
  # proves nothing -- and AlertService truncates from the end, which is where the runbook
  # link lives. So the worst case has to fit with both long fields at their caps.
  test "the longest framing still fits inside the details cap with both long fields maxed" do
    payload = JSON.parse(NO_OOM_BUSY_PAYLOAD)
    payload["probe"]["last_error"] = "x" * 5_000
    payload["recovery"]["steps"] = "y" * 5_000
    # Host and container names are unbounded and never truncated, so the pin uses the
    # longest shapes this deployment actually produces rather than the fixture's short ones.
    payload["host"] = "zimmer-production-droplet-nyc3-01"
    payload["container"]["name"] = "zimmer-worker-production-production-9e95b4d"

    details = capture_alert { WorkerWedgeAlert.report(payload.to_json) }[:details]

    assert_operator details.length, :<, AlertService::DETAILS_SECTION_MAX_CHARS
    assert_includes details, WorkerWedgeAlert::RUNBOOK
  end

  private

  # Intercept the one call this service makes, and hand back what it was asked to send.
  def capture_alert
    captured = {}
    AlertService.expects(:raise_alert).once.with do |title, opts|
      captured[:title] = title
      captured[:details] = opts[:details]
      captured[:source] = opts[:source]
      captured[:dedup_key] = opts[:dedup_key]
      true
    end.returns(true)

    yield

    captured
  end
end
