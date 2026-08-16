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
