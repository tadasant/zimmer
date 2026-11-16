# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# The SSH-identity converge that every staging deploy runs (scripts/converge-ssh-identity.sh).
#
# `ssh` and `ssh-keyscan` are stubbed on PATH, so nothing here touches a network. The stub
# `ssh` records each call's argv and stdin, which is what lets these tests assert the two
# properties that matter most and are invisible in a green deploy log: the host PRIVATE key
# travels only on stdin (never on a command line, where the remote box's process list would
# show it), and a key that is not what it claims to be is refused before anything is sent.
class ConvergeSshIdentityTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "converge-ssh-identity.sh")

  def keygen(dir, name, type: "ed25519")
    path = File.join(dir, name)
    _out, err, status = Open3.capture3("ssh-keygen", "-q", "-t", type, "-N", "", "-C", name, "-f", path)
    assert status.success?, err
    path
  end

  # Runs the script with `ssh` / `ssh-keyscan` stubs. `keyscan` is the line the stub
  # ssh-keyscan prints; `ssh_exit` is what every stub ssh call returns.
  def run_script(env:, keyscan: "", ssh_exit: 0)
    Dir.mktmpdir do |dir|
      log = File.join(dir, "calls")
      Dir.mkdir(log)
      File.write(File.join(dir, "ssh"), <<~SH)
        #!/bin/sh
        n=$(ls "#{log}" | wc -l)
        for a in "$@"; do printf '%s\\n' "$a"; done > "#{log}/$n.argv"
        cat > "#{log}/$n.stdin"
        exit #{ssh_exit}
      SH
      File.write(File.join(dir, "ssh-keyscan"), "#!/bin/sh\nprintf '%s\\n' '#{keyscan}'\n")
      File.write(File.join(dir, "sleep"), "#!/bin/sh\nexit 0\n")
      %w[ssh ssh-keyscan sleep].each { |f| File.chmod(0o755, File.join(dir, f)) }

      full_env = { "PATH" => "#{dir}:#{ENV["PATH"]}", "ATTEMPTS" => "2" }.merge(env)
      stdout, stderr, status = Open3.capture3(full_env, "bash", SCRIPT.to_s, "testhost")
      calls = Dir[File.join(log, "*.argv")].sort.map do |argv|
        { argv: File.read(argv), stdin: File.read(argv.sub(/argv\z/, "stdin")) }
      end
      [ status.exitstatus, stdout + stderr, calls ]
    end
  end

  def pub_line(path)
    File.read("#{path}.pub").split[0, 2].join(" ")
  end

  test "with nothing configured it contacts nobody and succeeds" do
    code, out, calls = run_script(env: {})

    assert_equal 0, code
    assert_match(/nothing to converge/, out)
    assert_empty calls
  end

  test "authorizes the given public keys, sending them on stdin" do
    Dir.mktmpdir do |keys|
      strad = keygen(keys, "strad-client")
      code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => "\n#{File.read("#{strad}.pub")}\n" })

      assert_equal 0, code, out
      assert_equal 1, calls.size
      assert_includes calls.first[:stdin], pub_line(strad)
      assert_match(/authorized_keys/, calls.first[:argv])
    end
  end

  test "pins the host key: private half on stdin only, public half as the argument, keyscan confirms" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "pinned-host")
      private_key = File.read(host)
      code, out, calls = run_script(
        env: { "SSH_HOST_ED25519_KEY" => private_key },
        keyscan: "[testhost]:2222 #{pub_line(host)}"
      )

      assert_equal 0, code, out
      assert_equal 1, calls.size
      assert_equal private_key.strip, calls.first[:stdin].strip
      assert_includes calls.first[:argv], pub_line(host)
      refute_match(/PRIVATE KEY/, calls.first[:argv])
      refute_match(/PRIVATE KEY/, out)
      assert_match(/presents the pinned host key/, out)
    end
  end

  test "accepts the host key base64-encoded" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "pinned-host")
      code, out, calls = run_script(
        env: { "SSH_HOST_ED25519_KEY" => [ File.read(host) ].pack("m0") },
        keyscan: "testhost #{pub_line(host)}"
      )

      assert_equal 0, code, out
      assert_equal File.read(host).strip, calls.first[:stdin].strip
    end
  end

  test "a daemon still serving another key gets exactly one forced restart, then fails the deploy" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "pinned-host")
      other = keygen(keys, "other-host")
      code, out, calls = run_script(
        env: { "SSH_HOST_ED25519_KEY" => File.read(host) },
        keyscan: "testhost #{pub_line(other)}"
      )

      assert_equal 1, code
      assert_match(/restarting sshd once/, out)
      assert_match(/not the pinned key/, out)
      assert_equal 2, calls.size
      assert calls.last[:argv].strip.end_with?(" restart"), calls.last[:argv]
      refute_match(/PRIVATE KEY/, calls.last[:argv])
    end
  end

  test "accepts a raw host key with CRLF line endings and leading whitespace" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "pinned-host")
      code, out, _calls = run_script(
        env: { "SSH_HOST_ED25519_KEY" => "  " + File.read(host).gsub("\n", "\r\n") },
        keyscan: "testhost #{pub_line(host)}"
      )

      assert_equal 0, code, out
    end
  end

  test "refuses an authorized_keys line with an options prefix" do
    Dir.mktmpdir do |keys|
      strad = keygen(keys, "strad-client")
      code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => %(from="10.0.0.1" #{File.read("#{strad}.pub")}) })

      assert_equal 2, code
      assert_match(/does not start with a key type/, out)
      assert_empty calls
    end
  end

  test "fails the deploy when :2222 presents no key at all" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "pinned-host")
      code, out, _calls = run_script(env: { "SSH_HOST_ED25519_KEY" => File.read(host) }, keyscan: "")

      assert_equal 1, code
      assert_match(/presented no ed25519 host key/, out)
    end
  end

  test "refuses a private key in the public-key list without echoing it or contacting the host" do
    Dir.mktmpdir do |keys|
      leaked = keygen(keys, "leaked")
      code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => File.read(leaked) })

      assert_equal 2, code
      assert_match(/contains a PRIVATE key/, out)
      refute_includes out, File.read(leaked).lines[1].strip
      assert_empty calls
    end
  end

  test "refuses a line that is not a public key" do
    code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => "ssh-ed25519 not-base64" })

    assert_equal 2, code
    assert_match(/line 1 is not an OpenSSH public key/, out)
    assert_empty calls
  end

  test "refuses a host key that is not ed25519" do
    Dir.mktmpdir do |keys|
      host = keygen(keys, "ecdsa-host", type: "ecdsa")
      code, out, calls = run_script(env: { "SSH_HOST_ED25519_KEY" => File.read(host) })

      assert_equal 2, code
      assert_match(/not ssh-ed25519/, out)
      assert_empty calls
    end
  end

  test "refuses garbage in the host-key secret without echoing it" do
    code, out, calls = run_script(env: { "SSH_HOST_ED25519_KEY" => "definitely-not-a-key" })

    assert_equal 2, code
    assert_match(/not a readable, unencrypted OpenSSH private key/, out)
    refute_includes out, "definitely-not-a-key"
    assert_empty calls
  end

  test "an unreachable host fails after the retry budget" do
    Dir.mktmpdir do |keys|
      strad = keygen(keys, "strad-client")
      code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => File.read("#{strad}.pub") }, ssh_exit: 255)

      assert_equal 1, code
      assert_equal 2, calls.size
      assert_match(/on any of 2 attempts/, out)
    end
  end

  test "a payload failure is not retried" do
    Dir.mktmpdir do |keys|
      strad = keygen(keys, "strad-client")
      code, out, calls = run_script(env: { "AUTHORIZED_PUBKEYS" => File.read("#{strad}.pub") }, ssh_exit: 3)

      assert_equal 3, code
      assert_equal 1, calls.size
      assert_match(/exited 3/, out)
    end
  end
end
