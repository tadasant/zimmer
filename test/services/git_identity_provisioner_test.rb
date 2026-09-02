# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "open3"
require "securerandom"
require "tmpdir"

# These tests drive real `git` against a temp HOME rather than stubbing the
# subprocess, because the claim under test is git's own: that after provisioning,
# `git config user.email` in a freshly prepared clone answers with exit 0. A double
# could only ever assert that Zimmer wrote the bytes it meant to write.
class GitIdentityProvisionerTest < ActiveSupport::TestCase
  NAME_VAR = GitIdentityProvisioner::NAME_ENV_VAR
  EMAIL_VAR = GitIdentityProvisioner::EMAIL_ENV_VAR

  # The credential-helper block Dockerfile.base bakes into the image's ~/.gitconfig.
  # Provisioning has to land *beside* it, not on top of it: clobbering this is how a
  # fix for committing would break pushing.
  CREDENTIAL_HELPER = <<~CONFIG
    [credential "https://github.com"]
    \thelper =
    \thelper = !/usr/bin/gh auth git-credential
  CONFIG

  setup do
    @home = Dir.mktmpdir("git-identity-test")
    File.write(File.join(@home, ".gitconfig"), CREDENTIAL_HELPER)
    @logger = TestLogger.new
    @original = { NAME_VAR => ENV[NAME_VAR], EMAIL_VAR => ENV[EMAIL_VAR] }
    ENV.delete(NAME_VAR)
    ENV.delete(EMAIL_VAR)
  end

  teardown do
    @original.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
    FileUtils.remove_entry(@home) if File.directory?(@home)
  end

  test "a clone prepared after provisioning answers git config user.email with exit 0" do
    configure("Zimmer Test Operator", "operator@example.com")

    assert_equal({ name: "Zimmer Test Operator", email: "operator@example.com" }, provision)

    clone = prepared_clone
    email, email_status = git_in(clone, "config", "user.email")
    name, name_status = git_in(clone, "config", "user.name")

    assert_equal 0, email_status.exitstatus, "expected `git config user.email` to exit 0 in a prepared clone"
    assert_equal 0, name_status.exitstatus, "expected `git config user.name` to exit 0 in a prepared clone"
    assert_equal "operator@example.com", email
    assert_equal "Zimmer Test Operator", name
  end

  test "a commit in a prepared clone succeeds and carries the configured identity" do
    configure("Zimmer Test Operator", "operator@example.com")
    provision

    clone = prepared_clone
    File.write(File.join(clone, "a.txt"), "hi\n")
    _out, add_status = git_in(clone, "add", "a.txt")
    assert_equal 0, add_status.exitstatus

    _out, commit_status = git_in(clone, "commit", "-q", "-m", "first commit")
    assert_equal 0, commit_status.exitstatus, "the commit that exits 128 with 'Author identity unknown' today"

    author, = git_in(clone, "log", "-1", "--pretty=%an <%ae>")
    assert_equal "Zimmer Test Operator <operator@example.com>", author
  end

  test "provisioning leaves the credential helper intact" do
    configure("Zimmer Test Operator", "operator@example.com")
    provision

    helper, status = git_in(@home, "config", "--global", "credential.https://github.com.helper")
    assert_equal 0, status.exitstatus
    assert_equal "!/usr/bin/gh auth git-credential", helper
  end

  test "writes into ~/.gitconfig, the file the image already configures" do
    configure("Zimmer Test Operator", "operator@example.com")
    provision

    assert_match(/operator@example\.com/, File.read(File.join(@home, ".gitconfig")))
  end

  # `--global` prefers $XDG_CONFIG_HOME/git/config when ~/.gitconfig is absent, which
  # is the whole subject of config_path's comment: a home with no gitconfig must still
  # get one at the path a reader expects, not somewhere else.
  test "creates ~/.gitconfig on a home that has none, rather than an XDG path" do
    FileUtils.rm_f(File.join(@home, ".gitconfig"))
    xdg = File.join(@home, ".config")
    FileUtils.mkdir_p(File.join(xdg, "git"))
    configure("Zimmer Test Operator", "operator@example.com")

    with_env("XDG_CONFIG_HOME" => xdg) { provision }

    assert_path_exists File.join(@home, ".gitconfig")
    assert_not File.exist?(File.join(xdg, "git", "config"))
    assert_equal "operator@example.com", git_in(@home, "config", "--global", "user.email").first
  end

  test "provisions nothing and says so when neither variable is set" do
    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:info).any? { |m| m.include?(NAME_VAR) && m.include?(EMAIL_VAR) }
  end

  test "provisions nothing rather than inventing the missing half of a partial identity" do
    ENV[NAME_VAR] = "Zimmer Test Operator"

    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:warn).any? { |m| m.include?(EMAIL_VAR) }
  end

  test "provisions nothing when only the email is set, naming the missing name" do
    ENV[EMAIL_VAR] = "operator@example.com"

    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:warn).any? { |m| m.include?(NAME_VAR) }
  end

  test "rejects an email carrying a character git cannot put in an ident line" do
    configure("Zimmer Test Operator", "operator@example.com>")

    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:warn).any? { |m| m.include?(EMAIL_VAR) }
  end

  # The realistic typo: the two variables swapped, or the email left as prose. git
  # itself would accept it and every commit after would wear it.
  test "rejects an email that is not shaped like one" do
    configure("Zimmer Test Operator", "Zimmer Test Operator")

    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:warn).any? { |m| m.include?(EMAIL_VAR) && m.include?("email address") }
  end

  test "rejects a value carrying a character git cannot put in an ident line" do
    configure("Zimmer\nuser.email = smuggled@example.com", "operator@example.com")

    assert_nil provision
    assert_equal CREDENTIAL_HELPER, File.read(File.join(@home, ".gitconfig"))
    assert @logger.messages(:warn).any? { |m| m.include?(NAME_VAR) }
  end

  test "is idempotent: a second pass rewrites nothing and leaves one value" do
    configure("Zimmer Test Operator", "operator@example.com")
    provision
    first = File.read(File.join(@home, ".gitconfig"))

    @logger = TestLogger.new
    provision

    assert_equal first, File.read(File.join(@home, ".gitconfig"))
    assert_empty @logger.messages(:info).grep(/Provisioned/), "a no-op pass should not claim to have provisioned"

    values, status = git_in(@home, "config", "--global", "--get-all", "user.email")
    assert_equal 0, status.exitstatus
    assert_equal [ "operator@example.com" ], values.lines.map(&:strip)
  end

  test "converges a config that already carries the key twice" do
    run_git_global("config", "--global", "--add", "user.email", "first@example.com")
    run_git_global("config", "--global", "--add", "user.email", "operator@example.com")
    configure("Zimmer Test Operator", "operator@example.com")

    provision

    values, = git_in(@home, "config", "--global", "--get-all", "user.email")
    assert_equal [ "operator@example.com" ], values.lines.map(&:strip)
  end

  test "logs the value it replaces, so a clobbered identity is recoverable" do
    run_git_global("config", "--global", "user.email", "someone@example.com")
    configure("Zimmer Test Operator", "operator@example.com")

    provision

    assert @logger.messages(:warn).any? { |m| m.include?("someone@example.com") },
      "expected the replaced value to appear in the log"
  end

  test "a changed value replaces the old one instead of appending a second" do
    configure("Zimmer Test Operator", "operator@example.com")
    provision

    configure("Someone Else", "someone@example.com")
    provision

    values, = git_in(@home, "config", "--global", "--get-all", "user.email")
    assert_equal [ "someone@example.com" ], values.lines.map(&:strip)
  end

  test "an unwritable config is logged, not raised" do
    configure("Zimmer Test Operator", "operator@example.com")
    File.chmod(0o500, @home)

    begin
      assert_nil provision
      assert @logger.messages(:warn).any? { |m| m.include?("Failed to provision the git identity") }
    ensure
      File.chmod(0o700, @home)
    end
  end

  test "a git failure is logged, not raised" do
    configure("Zimmer Test Operator", "operator@example.com")
    BoundedSubprocess.stubs(:run).raises(BoundedSubprocess::TimeoutError, "command timed out after 10s")

    assert_nil provision
    assert @logger.messages(:warn).any? { |m| m.include?("Failed to provision the git identity") }
  end

  private

  def configure(name, email)
    ENV[NAME_VAR] = name
    ENV[EMAIL_VAR] = email
  end

  # Seeds the provisioned global config directly, for the cases that need something
  # already in it before `ensure!` runs.
  def run_git_global(*args)
    _out, status = git_in(@home, *args)
    assert_equal 0, status.exitstatus
  end

  def with_env(vars)
    original = vars.transform_values { |_| nil }.merge(vars.keys.index_with { |k| ENV[k] })
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def provision
    GitIdentityProvisioner.ensure!(home: @home, logger: @logger)
  end

  # A clone the way a session gets one: a working tree with no identity of its own,
  # under the provisioned HOME. `git init` rather than `git clone` keeps the test off
  # the network; the identity lookup git performs is identical either way.
  def prepared_clone
    path = File.join(@home, "clone-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(path)
    _out, status = git_in(path, "init", "-q")
    assert_equal 0, status.exitstatus
    path
  end

  # Runs git with GIT_CONFIG_GLOBAL pinned at the provisioned config, which is what
  # HOME would do for a real session's subprocess. GIT_CONFIG_SYSTEM=/dev/null keeps
  # /etc/gitconfig — which on a developer's machine or a CI runner may well carry an
  # identity — from answering for the config under test.
  def git_in(cwd, *args)
    env = {
      "GIT_CONFIG_GLOBAL" => File.join(@home, ".gitconfig"),
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "HOME" => @home
    }
    stdout, _stderr, status = Open3.capture3(env, "git", "-C", cwd, *args)
    [ stdout.strip, status ]
  end

  # Minimal logger that records what it was told, so a test can assert on the one
  # line an unconfigured deployment is supposed to get.
  class TestLogger
    def initialize = @messages = Hash.new { |h, k| h[k] = [] }
    def info(message) = @messages[:info] << message
    def warn(message) = @messages[:warn] << message
    def messages(level) = @messages[level]
  end
end
