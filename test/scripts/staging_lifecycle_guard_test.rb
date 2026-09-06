# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "json"

# The guard is the only thing standing between a nightly cron and a nightly page.
#
# Two failure shapes matter, and both are silent from the outside. A guard that answers
# "tear it down" when it could not actually tell destroys a droplet somebody is working
# on. A guard that reddens on the ordinary "staging is already down" night pages #alerts
# every night through `alert-ci-failure.yml`, which is how an alert channel stops being
# read. So every branch is driven here with `terraform` and `curl` stubbed on PATH -- no
# backend, no droplet, no network -- and the assertions are about the verdict AND the
# exit status, because a correct verdict delivered by a red run is still a page.
class StagingLifecycleGuardTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "staging-lifecycle-guard.sh")

  EXIT_ANSWERED = 0
  EXIT_COULD_NOT_ANSWER = 1
  EXIT_BAD_USAGE = 2

  DROPLET = "digitalocean_droplet.zimmer"

  # What `terraform state list` prints for a live staging environment.
  LIVE_STATE = [
    "digitalocean_droplet.zimmer",
    "digitalocean_firewall.zimmer",
    "digitalocean_reserved_ip.zimmer"
  ].join("\n")

  # What it prints once the droplet is destroyed but the (empty) state object remains.
  TORN_DOWN_STATE = ""

  # A `terraform` that logs its arguments and answers from the environment, and a `curl`
  # that writes STUB_BODY to the -o path and prints STUB_CODE. Neither touches a network.
  def stub_bin(dir)
    File.write(File.join(dir, "terraform"), <<~SH)
      #!/bin/sh
      echo "$*" >> "$TF_CALLS"
      case "$2" in
        init)
          if [ "$TF_INIT_FAIL" = "1" ]; then
            echo "Error: error configuring S3 Backend: no valid credential sources found" >&2
            exit 1
          fi
          echo "Terraform has been successfully initialized!"
          exit 0
          ;;
        state)
          if [ -n "$TF_STATE_ERR" ]; then
            echo "$TF_STATE_ERR" >&2
            exit 1
          fi
          if [ -n "$TF_STATE_LIST" ]; then echo "$TF_STATE_LIST"; fi
          exit 0
          ;;
      esac
      exit 0
    SH

    File.write(File.join(dir, "curl"), <<~SH)
      #!/bin/sh
      out=""; url=""; next_is_out=""
      for a in "$@"; do
        if [ -n "$next_is_out" ]; then out="$a"; next_is_out=""; continue; fi
        [ "$a" = "-o" ] && next_is_out=1
        url="$a"
      done
      echo "$url" >> "$CURL_LOG"
      [ -n "$out" ] && printf '%s' "$STUB_BODY" > "$out"
      printf '%s' "$STUB_CODE"
      [ "$STUB_CODE" = "000" ] && exit 7
      exit 0
    SH

    [ "terraform", "curl" ].each { |n| File.chmod(0o755, File.join(dir, n)) }
    "#{dir}:#{ENV["PATH"]}"
  end

  # Returns [exit status, combined output, parsed $GITHUB_OUTPUT hash, curl urls].
  def run_guard(mode, state: LIVE_STATE, state_err: "", init_fail: false,
                hours: "18", body: nil, code: "200", credentials: true, configured: false,
                output_path: :tmp)
    Dir.mktmpdir do |dir|
      out_file = File.join(dir, "gh_output")
      env = {
        "PATH" => stub_bin(dir),
        "TF_CALLS" => File.join(dir, "tf.log"),
        "CURL_LOG" => File.join(dir, "curl.log"),
        "TF_STATE_LIST" => state,
        "TF_STATE_ERR" => state_err,
        "TF_INIT_FAIL" => init_fail ? "1" : "0",
        "STUB_BODY" => body || JSON.dump({ "workflow_runs" => [] }),
        "STUB_CODE" => code,
        "GITHUB_OUTPUT" => out_file,
        "GITHUB_REPOSITORY" => "tadasant/zimmer",
        "GITHUB_API_URL" => "https://api.example",
        "GH_TOKEN" => "t0ken",
        "RECENT_DEPLOY_HOURS" => hours,
        "AWS_ACCESS_KEY_ID" => credentials ? "spaces-key" : "",
        "AWS_SECRET_ACCESS_KEY" => credentials ? "spaces-secret" : "",
        "STAGING_IS_CONFIGURED" => configured ? "true" : "false"
      }
      # `nil`, not `delete`: the parent process may well have GITHUB_OUTPUT set (this
      # suite runs in Actions), and only an explicit nil unsets it for the child.
      env["GITHUB_OUTPUT"] = nil if output_path == :unset

      stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT.to_s, mode)

      outputs = {}
      if File.exist?(out_file)
        File.readlines(out_file, chomp: true).each do |line|
          k, _, v = line.partition("=")
          outputs[k] = v
        end
      end
      curls = File.exist?(env["CURL_LOG"]) ? File.readlines(env["CURL_LOG"], chomp: true) : []
      tf = File.exist?(env["TF_CALLS"]) ? File.readlines(env["TF_CALLS"], chomp: true) : []

      yield(tf) if block_given?
      [ status.exitstatus, stdout + stderr, outputs, curls, tf ]
    end
  end

  # A run list whose newest successful entry finished `hours_ago` hours ago.
  def deploy_history(hours_ago)
    JSON.dump({ "workflow_runs" => [ { "updated_at" => (Time.now.utc - (hours_ago * 3600)).iso8601 } ] })
  end

  # --- The nightly no-op: staging is already down ------------------------------------

  test "teardown skips cleanly when the state manages no droplet" do
    code, out, outputs, curls = run_guard("teardown", state: TORN_DOWN_STATE)

    assert_equal EXIT_ANSWERED, code, "an ordinary 'staging is already down' night must not be a red run"
    assert_equal "false", outputs["proceed"]
    assert_equal "absent", outputs["droplet"]
    assert_match(/nothing to destroy/, outputs["reason"])
    assert_match(/Skipping/, out)

    # It answered without asking GitHub anything: with no droplet, deploy history cannot
    # change the verdict, and an API outage must not be able to redden this path.
    assert_empty curls
  end

  test "teardown skips cleanly when the environment has never been applied at all" do
    code, _out, outputs = run_guard(
      "teardown", state: TORN_DOWN_STATE,
      # Terraform 1.10.5's wording (the version both workflows pin). This is the
      # never-applied case; the case this repo actually reaches after a teardown is an
      # empty state OBJECT, which exits 0 with no output and is covered above.
      state_err: "Error: No state file was found!\n\nState management commands require a state file."
    )

    assert_equal EXIT_ANSWERED, code, "terraform reports a missing state object on stderr with a " \
      "non-zero status; reading that as a broken backend would page every night"
    assert_equal "false", outputs["proceed"]
    assert_equal "absent", outputs["droplet"]
  end

  test "teardown proceeds when a droplet exists and no deploy is holding it" do
    tf = nil
    code, _out, outputs, curls = run_guard("teardown", body: deploy_history(40)) { |calls| tf = calls }

    assert_equal EXIT_ANSWERED, code
    assert_equal "true", outputs["proceed"]
    assert_equal "present", outputs["droplet"]
    assert_match(/40h ago/, outputs["reason"])
    assert_equal 1, curls.length
    assert_match(%r{/repos/tadasant/zimmer/actions/workflows/deploy-staging\.yml/runs\?status=success},
                 curls.first)

    # The defaults are what the workflow relies on and never restates, so a typo in either
    # would pass every other assertion here and fail only at 06:23 in production.
    assert tf.any? { |c| c.include?("-chdir=infra/terraform") && c.include?("init") },
      "it must init the staging Terraform directory: #{tf.inspect}"
    assert tf.any? { |c| c.include?("-backend-config=backend.staging.hcl") },
      "it must open the STAGING remote state, not whatever backend is configured by default"
    assert tf.any? { |c| c.include?("-chdir=infra/terraform state list") }
  end

  # --- The recent-deploy window ------------------------------------------------------

  test "a deploy inside the window suppresses tonight's teardown" do
    code, out, outputs = run_guard("teardown", hours: "18", body: deploy_history(2))

    assert_equal EXIT_ANSWERED, code
    assert_equal "false", outputs["proceed"]
    assert_equal "present", outputs["droplet"]
    assert_match(/2h ago, within the 18h window/, outputs["reason"])
    assert_match(/Skipping/, out)
  end

  test "a deploy just outside the window does not" do
    # 18h is the boundary: at exactly the window the droplet is no longer protected.
    _code, _out, inside = run_guard("teardown", hours: "18", body: deploy_history(17.9))
    _code, _out, outside = run_guard("teardown", hours: "18", body: deploy_history(18.1))

    assert_equal "false", inside["proceed"]
    assert_equal "true", outside["proceed"]
  end

  test "the window is the only knob -- a different one moves the verdict" do
    _code, _out, tight = run_guard("teardown", hours: "6", body: deploy_history(12))
    _code, _out, wide = run_guard("teardown", hours: "48", body: deploy_history(12))

    assert_equal "true", tight["proceed"], "12h ago is outside a 6h window"
    assert_equal "false", wide["proceed"], "12h ago is inside a 48h window"
  end

  test "a droplet nobody has ever successfully deployed to is torn down" do
    code, _out, outputs = run_guard("teardown", body: JSON.dump({ "workflow_runs" => [] }))

    assert_equal EXIT_ANSWERED, code
    assert_equal "true", outputs["proceed"]
    assert_match(/no successful deploy-staging\.yml run on record/, outputs["reason"])
  end

  # --- Unknown is read as "in use", never as "destroy it" ----------------------------

  test "an API that will not answer keeps the droplet, and stays green" do
    [ "403", "500", "000" ].each do |status|
      code, out, outputs = run_guard("teardown", code: status, body: "{}")

      assert_equal EXIT_ANSWERED, code, "HTTP #{status}: an unreadable API must not page"
      assert_equal "false", outputs["proceed"],
        "HTTP #{status}: unknown deploy history must never be read as permission to destroy"
      assert_match(/assumed to be in use/, outputs["reason"])
      assert_match(/::warning::/, out)
    end
  end

  test "a 200 whose body is not run history keeps the droplet" do
    # `%{http_code}` is written as soon as the response headers arrive, so a --max-time
    # expiry or a connection reset mid-body reports 200 over a truncated document. Reading
    # a failed parse as "no deploy on record" would destroy a droplet somebody is using.
    [ "<html>502 Bad Gateway</html>", "", '{"workflow_runs":' ].each do |garbage|
      code, out, outputs = run_guard("teardown", code: "200", body: garbage)

      assert_equal EXIT_ANSWERED, code, garbage.inspect
      assert_equal "false", outputs["proceed"],
        "#{garbage.inspect}: an unparseable body is unknown deploy history, not an absent one"
      assert_match(/::warning::/, out)
    end
  end

  test "a run with no timestamp on it keeps the droplet" do
    body = JSON.dump({ "workflow_runs" => [ { "updated_at" => nil } ] })
    code, _out, outputs = run_guard("teardown", body: body)

    assert_equal EXIT_ANSWERED, code
    assert_equal "false", outputs["proceed"]
  end

  test "a timestamp it cannot parse keeps the droplet" do
    body = JSON.dump({ "workflow_runs" => [ { "updated_at" => "the day before yesterday" } ] })
    code, out, outputs = run_guard("teardown", body: body)

    assert_equal EXIT_ANSWERED, code
    assert_equal "false", outputs["proceed"]
    assert_match(/::warning::/, out)
  end

  # --- A backend it cannot read is a real failure, and must page ---------------------

  test "a backend that refuses to initialize fails loudly" do
    code, out, outputs = run_guard("teardown", init_fail: true)

    assert_equal EXIT_COULD_NOT_ANSWER, code
    assert_match(/::error::/, out)
    assert_empty outputs, "it must decide nothing rather than decide 'absent' from a broken backend"
  end

  test "an unrecognized state error fails loudly rather than reading as an empty environment" do
    code, out, outputs = run_guard("teardown", state_err: "Error: Failed to load state: AccessDenied")

    assert_equal EXIT_COULD_NOT_ANSWER, code
    assert_match(/unknown whether a droplet exists/, out)
    assert_empty outputs
  end

  # --- A fork that never configured staging ------------------------------------------

  test "no remote-state credentials is a warned skip, not a nightly red X on somebody's fork" do
    tf_calls = nil
    code, out, outputs = run_guard("teardown", credentials: false, configured: false) { |tf| tf_calls = tf }

    assert_equal EXIT_ANSWERED, code
    assert_equal "false", outputs["proceed"]
    assert_equal "unknown", outputs["droplet"]
    assert_match(/::warning::/, out)
    assert_match(/not configured in this repository/, outputs["reason"])
    assert_empty tf_calls, "terraform must not be invoked at all without the keys that open the backend"
  end

  test "but losing the state credentials in a repo that HAS staging fails loudly" do
    # The asymmetry is the point. A green skip here would switch the nightly teardown off
    # permanently and silently — the droplet bills round the clock again and nothing ever
    # goes red — which is the same do-nothing failure the broken-backend branch refuses.
    code, out, outputs = run_guard("teardown", credentials: false, configured: true)

    assert_equal EXIT_COULD_NOT_ANSWER, code
    assert_match(/::error::/, out)
    assert_match(/bill continuously again/, out)
    assert_empty outputs
  end

  test "a state with leftovers but no droplet says so, loudly enough to reach an operator" do
    # An unassigned digitalocean_reserved_ip still bills, and no scheduled run will ever
    # clean it up — the guard skips past it every night. Saying so in the run is the only
    # way anyone finds out without a shell.
    code, out, outputs = run_guard("teardown", state: "digitalocean_reserved_ip.zimmer")

    assert_equal EXIT_ANSWERED, code
    assert_equal "false", outputs["proceed"]
    assert_equal "absent", outputs["droplet"]
    assert_match(/::warning::  digitalocean_reserved_ip\.zimmer/, out)
    assert_match(/unassigned digitalocean_reserved_ip still bills/, out)
  end

  test "an empty state says nothing about leftovers, because there are none" do
    _code, out, = run_guard("teardown", state: TORN_DOWN_STATE)

    refute_match(/state is not empty/, out)
  end

  # --- Cert mode ---------------------------------------------------------------------

  test "cert skips when there is no droplet to point DNS at" do
    code, _out, outputs, curls = run_guard("cert", state: TORN_DOWN_STATE)

    assert_equal EXIT_ANSWERED, code, "the weekly cert cron must not page on the weeks staging is down"
    assert_equal "false", outputs["proceed"]
    assert_equal "absent", outputs["droplet"]
    assert_match(/no box to point DNS at or push a cert to/, outputs["reason"])
    assert_empty curls
  end

  test "cert proceeds when the droplet exists, without consulting deploy history" do
    code, _out, outputs, curls = run_guard("cert", hours: "")

    assert_equal EXIT_ANSWERED, code
    assert_equal "true", outputs["proceed"]
    assert_equal "present", outputs["droplet"]
    assert_empty curls, "a cert run cares that the box exists, not when it was last deployed to"
  end

  # --- Called wrong ------------------------------------------------------------------

  test "an unknown mode is a usage error, not a silent skip" do
    code, out, _outputs = run_guard("nightly")

    assert_equal EXIT_BAD_USAGE, code
    assert_match(/usage: staging-lifecycle-guard\.sh/, out)
  end

  test "a missing RECENT_DEPLOY_HOURS is a usage error rather than a guessed window" do
    [ "", "eighteen", "0" ].each do |value|
      tf = nil
      code, out, _outputs = run_guard("teardown", hours: value) { |calls| tf = calls }

      assert_equal EXIT_BAD_USAGE, code, "RECENT_DEPLOY_HOURS=#{value.inspect}"
      assert_match(/RECENT_DEPLOY_HOURS must be a positive integer/, out)

      # Before the backend is read, not after. On the nights staging is down the script
      # answers and exits early, so a window validated at the point of use would sit
      # undiscovered until the first night the droplet happens to exist.
      assert_empty tf, "the window must be validated before anything slow happens"
    end
  end

  test "the cert mode needs no window at all" do
    _code, _out, outputs = run_guard("cert", hours: "")

    assert_equal "true", outputs["proceed"]
  end

  test "a missing GITHUB_OUTPUT is refused, because every gated step would read it as skip" do
    code, out, _outputs = run_guard("teardown", output_path: :unset)

    assert_equal EXIT_BAD_USAGE, code
    assert_match(/GITHUB_OUTPUT is not set/, out)
  end

  # --- The address it looks for has to be the one Terraform actually manages ---------

  test "the droplet address the guard looks for is the one main.tf declares" do
    main_tf = Rails.root.join("infra/terraform/main.tf").read
    resource_type, name = DROPLET.split(".")

    assert_match(/resource\s+"#{Regexp.escape(resource_type)}"\s+"#{Regexp.escape(name)}"/, main_tf,
      "the guard defaults to #{DROPLET}; if the resource is renamed, a scheduled teardown " \
      "silently decides 'absent' forever and staging bills round the clock again")
    assert_includes SCRIPT.read, "DROPLET_ADDRESS:-#{DROPLET}"
  end
end
