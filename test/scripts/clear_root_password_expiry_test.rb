# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Proves the converge picks the RIGHT closing message, not merely that it fails.
#
# The value of this script's failure path is entirely in which diagnosis it prints.
# "the host was unreachable" and "the repair itself failed" send an operator to two
# completely different places, and getting it backwards is what sent a real staging
# deploy investigation looking for a password that was never broken. A guard whose
# failure path has never run is not a guard, so every branch is driven here with `ssh`
# stubbed on PATH -- no network and no host -- and `sleep` stubbed out so the backoff
# costs the suite nothing.
class ClearRootPasswordExpiryTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "clear-root-password-expiry.sh")

  EXIT_OK = 0
  EXIT_FAILED = 1
  EXIT_BAD_USAGE = 2

  # A fake `ssh` with the given body, plus a no-op `sleep`, ahead of the real ones.
  def stub_bin(dir, ssh_body)
    { "ssh" => ssh_body, "sleep" => "exit 0" }.each do |name, body|
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
    end
    "#{dir}:#{ENV["PATH"]}"
  end

  def run_script(ssh_body:, attempts: "2", host: "testhost", extra_env: {})
    Dir.mktmpdir do |dir|
      env = { "PATH" => stub_bin(dir, ssh_body), "ATTEMPTS" => attempts }.merge(extra_env)
      env = env.transform_values { |v| v.to_s.gsub("__DIR__", dir) }
      stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT.to_s, host)
      [ status.exitstatus, stdout + stderr ]
    end
  end

  test "reports success and exits 0 when the repair runs" do
    code, out = run_script(ssh_body: "exit 0")

    assert_equal EXIT_OK, code
    assert_match(/root password neutralized/, out)
  end

  test "an unreachable host is diagnosed as reachability, not as a broken password" do
    code, out = run_script(ssh_body: "exit 255")

    assert_equal EXIT_FAILED, code
    assert_match(/did not run to completion/, out)
    assert_match(/reachability problem, not a repair problem/, out)

    # The misdiagnosis this branch exists to prevent: sending an operator to repair a
    # password by hand over the very path that just timed out.
    refute_match(/repair it there by hand/, out)
  end

  test "a failed repair on a reachable host keeps the pam_unix advice" do
    code, out = run_script(ssh_body: "exit 7")

    assert_equal EXIT_FAILED, code
    assert_match(/Reached testhost/, out)
    assert_match(/repair it there by hand/, out)
    refute_match(/reachability problem/, out)
  end

  test "a host that answers once lands in the repair branch but reports the failed reaches" do
    # 255 first, then 7. The host answered at least once, so the by-hand advice is the
    # correct one -- but the tally still has to say the tailnet path is not healthy.
    ssh_body = <<~SH
      n=$(cat "$COUNTER" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$COUNTER"
      if [ "$n" -eq 0 ]; then exit 255; fi
      exit 7
    SH

    code, out = run_script(ssh_body: ssh_body, extra_env: { "COUNTER" => "__DIR__/n" })

    assert_equal EXIT_FAILED, code
    assert_match(/Reached testhost/, out)
    assert_match(%r{1/2 of those attempts could not reach it}, out)
  end

  test "rejects a non-positive or non-numeric ATTEMPTS instead of describing work it never did" do
    # Without the guard these skip the loop and still print a confident closing message
    # about a host that was never contacted.
    [ "0", "abc" ].each do |bad|
      code, out = run_script(ssh_body: "exit 0", attempts: bad)

      assert_equal EXIT_BAD_USAGE, code, "ATTEMPTS=#{bad.inspect} should be rejected"
      assert_match(/ATTEMPTS must be a positive integer/, out)
    end
  end
end
