# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Proves the GHCR login retry actually retries -- and actually gives up.
#
# A retry whose failure path has never run is not a retry. The thing it guards against is
# unreproducible on demand (you cannot ask ghcr.io for a TLS handshake timeout), so the
# only honest way to gain confidence is to drive the script with `docker` stubbed on PATH
# and make it fail on cue. `sleep` is stubbed out too, so the escalating backoff the real
# workflow uses costs the suite nothing.
#
# What each case pins down is a way the retry could be wired and still be useless: one that
# never fires, one that fires but reports green after publishing nothing, one that burns
# attempts on a missing credential, and one that leaks the token into the log.
class GhcrLoginTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join(".github/scripts/ghcr-login.sh")

  EXIT_OK = 0
  EXIT_FAILED = 1

  # A fake `docker` with the given body, plus a no-op `sleep`, ahead of the real ones.
  # The stub records every invocation so a test can count attempts rather than infer them.
  def stub_bin(dir, docker_body)
    docker = <<~SH
      echo "$@" >> "$LOG"
      #{docker_body}
    SH
    { "docker" => docker, "sleep" => "exit 0" }.each do |name, body|
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
    end
    "#{dir}:#{ENV['PATH']}"
  end

  def run_login(docker_body:, env: {})
    Dir.mktmpdir do |dir|
      log = File.join(dir, "calls")
      base = {
        "PATH" => stub_bin(dir, docker_body),
        "LOG" => log,
        "REGISTRY" => "ghcr.io",
        "REGISTRY_USERNAME" => "tadasant",
        "REGISTRY_PASSWORD" => "ghs-supersecret-token",
        # Two backoffs -> three attempts, matching the workflow's shape at no cost.
        "LOGIN_BACKOFF_SECONDS" => "90 240"
      }
      stdout, stderr, status = Open3.capture3(base.merge(env), "bash", SCRIPT.to_s)
      attempts = File.exist?(log) ? File.readlines(log).size : 0
      yield status.exitstatus, stdout + stderr, attempts
    end
  end

  test "the script is executable, since the workflow invokes it as a bare run: command" do
    assert SCRIPT.exist?
    assert SCRIPT.executable?,
      "#{SCRIPT.basename} must be executable or the release fails with 'Permission denied' " \
      "at exactly the step this change exists to make survivable"
  end

  test "a login that works first time costs nothing extra" do
    run_login(docker_body: "exit 0") do |code, out, attempts|
      assert_equal EXIT_OK, code, out
      assert_equal 1, attempts, "a healthy login must not pay for the retry"
      assert_match(/Logged in to ghcr\.io.*attempt 1\/3/, out)
    end
  end

  # The regression this whole change is about: run 33632998177 died here, 48 seconds in,
  # and took the release with it.
  test "a TLS handshake timeout is retried rather than failing the run" do
    body = <<~SH
      if [ "$(wc -l < "$LOG")" -lt 3 ]; then
        echo 'Error response from daemon: Get "https://ghcr.io/v2/": net/http: TLS handshake timeout' >&2
        exit 1
      fi
      exit 0
    SH

    run_login(docker_body: body) do |code, out, attempts|
      assert_equal EXIT_OK, code, out
      assert_equal 3, attempts, "the third attempt is the one that succeeds here"
      assert_match(/retrying in 90s/, out)
      assert_match(/retrying in 240s/, out)
    end
  end

  # A retry that swallows a permanent failure is worse than no retry: the job would carry
  # on unauthenticated and fail somewhere less legible, or report green having published
  # nothing.
  test "a login that never succeeds still fails the job, after every attempt" do
    run_login(docker_body: "echo 'unauthorized' >&2; exit 1") do |code, out, attempts|
      assert_equal EXIT_FAILED, code
      assert_equal 3, attempts
      assert_match(/::error::/, out)
      assert_match(/registry being down or the token being wrong/, out)
    end
  end

  # The backoff escalates because the GHCR secondary rate limit is account-wide and has
  # outlasted a single 90s wait. Attempts are driven by the backoff list, so a list that
  # silently shrank would silently remove attempts.
  test "the attempt count follows the backoff list" do
    run_login(docker_body: "exit 1", env: { "LOGIN_BACKOFF_SECONDS" => "1 2 3" }) do |code, _out, attempts|
      assert_equal EXIT_FAILED, code
      assert_equal 4, attempts, "four attempts for three backoffs"
    end
  end

  # An absent token is a configuration fault, not a hiccup. Retrying it three times only
  # delays the diagnosis by every backoff in the list.
  test "an empty token fails immediately instead of being retried" do
    run_login(docker_body: "exit 1", env: { "REGISTRY_PASSWORD" => "" }) do |code, out, attempts|
      assert_not_equal EXIT_OK, code
      assert_equal 0, attempts, "a missing credential must not spend the retry budget"
      assert_match(/REGISTRY_PASSWORD/, out)
    end
  end

  # The token reaches docker on stdin, never on a command line, and the daemon's error text
  # is echoed back into the log -- so the one thing that must never appear there is the
  # password itself.
  test "the token never reaches the log or the argument list" do
    run_login(docker_body: "echo \"args: $*\" >&2; exit 1") do |_code, out, _attempts|
      assert_not_includes out, "ghs-supersecret-token"
      assert_match(/--password-stdin/, out)
    end
  end

  # Registry output is untrusted text. A daemon error line beginning with `::` would
  # otherwise be interpreted as a workflow command by the runner.
  test "registry output is fenced before being echoed" do
    run_login(docker_body: "echo '::error::forged' >&2; exit 1") do |_code, out, _attempts|
      assert_match(/::stop-commands::ghcr-login-\d+/, out)
      assert_match(/::ghcr-login-\d+::/, out)
    end
  end
end
