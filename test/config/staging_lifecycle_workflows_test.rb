# frozen_string_literal: true

require "test_helper"
require "yaml"

# Staging is torn down on a cron and stood back up by hand, so two workflows now run on a
# schedule against a droplet that may not exist. The wiring that makes that safe is all
# in YAML, where nothing else can check it — and each of these properties fails silently
# in a different direction if it goes.
#
#   A lost `workflow_dispatch`  -> the manual path is gone and staging cannot be torn down
#                                  or certified on demand at all.
#   A guard that runs on more than the schedule -> a human's deliberate teardown becomes
#                                  a no-op, and the deploy chain pays for a Terraform init.
#   A guard that gates nothing   -> the cron destroys the droplet the moment it is warm.
#   A missing `actions: read`    -> the guard's run-history request 403s, and because it
#                                  fails SAFE it then skips every night forever: staging
#                                  bills round the clock again and no run ever goes red.
class StagingLifecycleWorkflowsTest < ActiveSupport::TestCase
  TEARDOWN = Rails.root.join(".github/workflows/teardown-staging.yml")
  CERT = Rails.root.join(".github/workflows/domain-cert-staging.yml")
  DEPLOY = Rails.root.join(".github/workflows/deploy-staging.yml")
  GUARD = "scripts/staging-lifecycle-guard.sh"

  # Both gated jobs carry this verbatim. Run the schedule's verdict; run every other
  # trigger regardless, which is what `!cancelled()` buys — a plain `needs:` job is skipped
  # when its dependency is skipped, and a manual dispatch skips `guard` by design.
  GATE = "${{ !cancelled() && (github.event_name != 'schedule' || " \
         "needs.guard.outputs.proceed == 'true') }}"

  # `on:` parses as the boolean `true` in YAML 1.1, which is what Psych speaks.
  ON = true

  def workflow(path)
    YAML.load_file(path, aliases: true)
  end

  test "teardown runs nightly AND still runs on demand" do
    triggers = workflow(TEARDOWN)[ON]

    assert triggers.key?("schedule"), "the nightly schedule is the entire feature"
    assert triggers.key?("workflow_dispatch"), "the manual teardown must not regress"

    cron = triggers["schedule"].map { |s| s["cron"] }
    assert_equal 1, cron.length, "one nightly run, not several"
    minute, hour, dom, month, dow = cron.first.split
    assert_equal [ "*", "*", "*" ], [ dom, month, dow ], "daily, every day"
    assert_operator minute.to_i, :>, 0, "GitHub's cron queue is busiest on the hour; stay off it"
    assert_includes 0..23, hour.to_i
  end

  test "the teardown window is one tunable integer, declared next to the cron" do
    wf = workflow(TEARDOWN)
    hours = wf.dig("env", "RECENT_DEPLOY_HOURS")

    assert hours, "RECENT_DEPLOY_HOURS belongs at workflow level, beside the cron it trades off against"
    assert_match(/\A\d+\z/, hours.to_s, "hours, as a plain integer")

    # The window must cover at least the gap between two runs, or a run lands in the gap
    # and destroys a droplet whose owner deployed to it a few hours earlier. An 18h window
    # against this daily cron would have torn staging down at 06:23 on 2026-08-16, 34
    # minutes before that morning's deploy.
    assert_equal [ "*", "*", "*" ], wf[ON]["schedule"].first["cron"].split.last(3),
      "the assertion below assumes a daily cron"
    assert_operator hours.to_i, :>=, 24,
      "a window shorter than the cron period lets a scheduled run fall between a deploy " \
      "and the next day's work"

    # One number, in one place. A second copy is a second thing to forget.
    body = TEARDOWN.read
    assert_equal 1, body.scan(/^\s*RECENT_DEPLOY_HOURS:/).length
    # `${RECENT_DEPLOY_HOURS:-}` is fine — it is how the script detects "unset" and refuses.
    # `${RECENT_DEPLOY_HOURS:-24}` would not be: a fallback window makes the workflow's
    # number look authoritative while a typo there silently hands control to the script's.
    assert_nil Rails.root.join(GUARD).read[/RECENT_DEPLOY_HOURS:-[^}]/],
      "the script must not carry a default window of its own"
  end

  test "the guard gates the nightly teardown and nothing else" do
    jobs = workflow(TEARDOWN)["jobs"]

    assert_equal "github.event_name == 'schedule'", jobs.dig("guard", "if"),
      "a dispatched teardown must destroy unconditionally, as it did before"
    assert_includes jobs.dig("guard", "steps").last["run"], "#{GUARD} teardown"

    # The whole expression, not three substrings: `!cancelled() || (…)` contains every one
    # of them and inverts the meaning, destroying the droplet on any night the guard fails.
    assert_equal GATE, jobs.dig("teardown", "if"),
      "the cron is gated on the verdict; every other trigger runs anyway; and `!cancelled()` " \
      "is what lets this job run past a `guard` that a manual dispatch skipped"
    assert_equal [ "guard" ], jobs.dig("teardown", "needs")
  end

  test "the guard can actually read the two things it decides on" do
    teardown = workflow(TEARDOWN)
    step = teardown.dig("jobs", "guard", "steps").last

    assert_equal "read", teardown.dig("permissions", "actions"),
      "without actions:read the run-history request 403s and the guard fails safe forever, " \
      "which looks green while never tearing anything down"
    assert_includes step["env"].keys, "GH_TOKEN"
    assert_includes step["env"].keys, "AWS_ACCESS_KEY_ID"
    assert_includes step["env"].keys, "AWS_SECRET_ACCESS_KEY"

    cert_step = workflow(CERT).dig("jobs", "guard", "steps").last
    assert_includes cert_step["env"].keys, "AWS_ACCESS_KEY_ID"
    assert_includes cert_step["env"].keys, "AWS_SECRET_ACCESS_KEY"
    refute_includes cert_step["env"].keys, "GH_TOKEN",
      "the cert guard asks only whether the box exists; it has no business reading deploy history"

    # Without this the guard cannot tell a fork that never configured staging (skip green)
    # from this repository having lost the keys to its own state (fail loudly), and would
    # take the fork branch — switching the schedule off silently in the one repo that runs it.
    [ step, cert_step ].each do |s|
      assert_equal "${{ secrets.DIGITALOCEAN_ACCESS_TOKEN != '' }}", s["env"]["STAGING_IS_CONFIGURED"],
        "a boolean ABOUT the secret, never the secret: it lands in a log line either way"
    end
  end

  test "the cert workflow keeps every path it had, and guards only the schedule" do
    wf = workflow(CERT)

    assert wf[ON].key?("schedule")
    assert wf[ON].key?("workflow_dispatch")
    assert wf[ON].key?("workflow_call"), "deploy-staging chains this after a fresh droplet comes up"

    assert_equal "github.event_name == 'schedule'", wf.dig("jobs", "guard", "if")
    assert_includes wf.dig("jobs", "guard", "steps").last["run"], "#{GUARD} cert"

    assert_equal GATE, wf.dig("jobs", "cert", "if"), "the same gate, for the same reasons"

    assert_includes DEPLOY.read, "uses: ./.github/workflows/domain-cert-staging.yml",
      "the chained call is what re-issues the cert after a teardown, so a skipped weekly run " \
      "costs nothing — if this link goes, the skip becomes a cert that quietly expires"
  end

  test "teardown and deploy still share one concurrency group" do
    assert_equal "staging-lifecycle", workflow(TEARDOWN).dig("concurrency", "group")
    assert_equal "staging-lifecycle", workflow(DEPLOY).dig("concurrency", "group"),
      "the shared group is why the cron cannot destroy the droplet out from under a running " \
      "deploy: it queues behind it, and then sees the fresh success and skips"
  end

  test "both workflows ask the same script, rather than each carrying its own copy" do
    [ TEARDOWN, CERT ].each do |path|
      assert_includes path.read, GUARD, "#{path.basename} must call the shared guard"
    end
    assert Rails.root.join(GUARD).executable?, "#{GUARD} is invoked as `bash <path>`, but keep it runnable"
  end
end
