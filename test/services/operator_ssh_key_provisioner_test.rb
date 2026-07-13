# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OperatorSshKeyProvisionerTest < ActiveSupport::TestCase
  # A stand-in for an OpenSSH private key. The provisioner only matches the PEM header
  # pattern — ssh2 and OpenSSH do the real parsing — so this never has to be a real key.
  # The header is assembled from parts rather than spelled out so that no line committed to
  # this repo reads as a private-key header itself — that is what secret scanners flag, and
  # what a reviewer greps the history for to prove no key was committed.
  LABEL = %w[OPENSSH PRIVATE KEY].join(" ")
  PEM = "-----BEGIN #{LABEL}-----\nZmFrZS1rZXktbWF0ZXJpYWw=\n-----END #{LABEL}-----\n"

  setup do
    @home = Dir.mktmpdir("operator-ssh-key-test")
    @original_env = ENV[OperatorSshKeyProvisioner::ENV_VAR]
    ENV.delete(OperatorSshKeyProvisioner::ENV_VAR)
    SecretsLoader.stubs(:get).with(OperatorSshKeyProvisioner::ENV_VAR).returns(nil)
  end

  teardown do
    if @original_env.nil?
      ENV.delete(OperatorSshKeyProvisioner::ENV_VAR)
    else
      ENV[OperatorSshKeyProvisioner::ENV_VAR] = @original_env
    end
    FileUtils.remove_entry(@home) if File.directory?(@home)
  end

  test "returns nil and writes nothing when no key material is configured" do
    assert_nil OperatorSshKeyProvisioner.ensure!(home: @home)
    assert_not File.exist?(File.join(@home, ".ssh"))
  end

  test "decodes base64 key material into ~/.ssh/id_ed25519 with 0600 in a 0700 ~/.ssh" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(PEM)

    path = OperatorSshKeyProvisioner.ensure!(home: @home)

    assert_equal File.join(@home, ".ssh", "id_ed25519"), path
    assert_equal PEM, File.read(path)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    assert_equal "700", format("%o", File.stat(File.join(@home, ".ssh")).mode & 0o777)
  end

  test "accepts a raw PEM as well as base64" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = PEM

    path = OperatorSshKeyProvisioner.ensure!(home: @home)

    assert_equal PEM, File.read(path)
  end

  test "appends the trailing newline OpenSSH requires when the material lacks one" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(PEM.chomp)

    path = OperatorSshKeyProvisioner.ensure!(home: @home)

    assert_equal PEM, File.read(path)
  end

  test "falls back to mcp_secrets when the env var is unset" do
    SecretsLoader.unstub(:get)
    SecretsLoader.stubs(:get).with(OperatorSshKeyProvisioner::ENV_VAR).returns(Base64.strict_encode64(PEM))

    path = OperatorSshKeyProvisioner.ensure!(home: @home)

    assert_equal PEM, File.read(path)
  end

  test "is idempotent and reasserts 0600 on an existing key" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(PEM)
    path = OperatorSshKeyProvisioner.ensure!(home: @home)
    File.chmod(0o644, path)

    assert_equal path, OperatorSshKeyProvisioner.ensure!(home: @home)
    assert_equal PEM, File.read(path)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
  end

  test "rewrites the key when the configured material changes" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(PEM)
    path = OperatorSshKeyProvisioner.ensure!(home: @home)

    rotated = PEM.sub("ZmFrZS1rZXktbWF0ZXJpYWw=", "cm90YXRlZC1rZXktbWF0ZXJpYWw=")
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(rotated)

    assert_equal path, OperatorSshKeyProvisioner.ensure!(home: @home)
    assert_equal rotated, File.read(path)
  end

  test "returns nil without writing when the material is neither a PEM nor base64 of one" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64("not a private key")

    assert_nil OperatorSshKeyProvisioner.ensure!(home: @home, logger: Logger.new(File::NULL))
    assert_not File.exist?(File.join(@home, ".ssh", "id_ed25519"))
  end

  test "never raises when the home directory cannot be written" do
    ENV[OperatorSshKeyProvisioner::ENV_VAR] = Base64.strict_encode64(PEM)

    assert_nil OperatorSshKeyProvisioner.ensure!(home: "/proc/nonexistent-home", logger: Logger.new(File::NULL))
  end
end
