# frozen_string_literal: true

require "test_helper"
require "open3"

# The routing rule lives twice — GithubTokens for Ruby callers, bin/zimmer-git-credential
# for git — so both are driven through the same table of cases. A change to one that
# is not mirrored in the other fails here.
class GithubTokensTest < ActiveSupport::TestCase
  HELPER = Rails.root.join("bin/zimmer-git-credential").to_s

  MAP = {
    "ZIMMER_GITHUB_TOKEN_ROUTING" => "1",
    "GH_TOKEN" => "github_pat_tadasant",
    "GH_TOKEN__PULSEMCP" => "github_pat_pulsemcp",
    "GH_TOKEN__MY_ORG" => "github_pat_my_org",
    "ZIMMER_GITHUB_DEFAULT_OWNER" => "tadasant"
  }.freeze

  # [description, env, owner, expected token]
  CASES = [
    [ "an owner's own token wins", MAP, "pulsemcp", "github_pat_pulsemcp" ],
    [ "owners match case-insensitively", MAP, "PulseMCP", "github_pat_pulsemcp" ],
    [ "a hyphenated owner folds to an underscore", MAP, "my-org", "github_pat_my_org" ],
    [ "the default owner gets GH_TOKEN", MAP, "tadasant", "github_pat_tadasant" ],
    [ "the default owner matches case-insensitively", MAP, "Tadasant", "github_pat_tadasant" ],
    [ "an unknown owner gets nothing (fail closed)", MAP, "warpdotdev", nil ],
    [ "with no default owner configured, GH_TOKEN serves every owner",
      MAP.except("ZIMMER_GITHUB_DEFAULT_OWNER"), "warpdotdev", "github_pat_tadasant" ],
    [ "no default token and no own token is nothing", MAP.except("GH_TOKEN"), "tadasant", nil ],
    [ "a name that is not a GitHub owner is never expanded", MAP, "a$(id)", nil ]
  ].freeze

  CASES.each do |description, env, owner, expected|
    test "GithubTokens: #{description}" do
      actual = GithubTokens.token_for(owner, env: env)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end

    test "git helper: #{description}" do
      stdout, status = run_helper(env, path: "#{owner}/repo.git")

      assert status.success?, "the helper must never fail git's credential lookup"
      if expected
        assert_equal "protocol=https\nhost=github.com\nusername=x-access-token\npassword=#{expected}\n", stdout
      else
        assert_equal "", stdout
      end
    end
  end

  test "git helper: a host other than github.com is not answered" do
    stdout, = run_helper(MAP, path: "tadasant/repo.git", host: "gitlab.com")
    assert_equal "", stdout
  end

  test "git helper: store and erase are no-ops in routing mode" do
    %w[store erase].each do |operation|
      stdout, status = run_helper(MAP, path: "tadasant/repo.git", operation: operation)
      assert status.success?
      assert_equal "", stdout
    end
  end

  # Backward compatibility: before any token is seeded the helper must keep handing
  # out the stored `gh auth login` credential, which it does by delegating to gh.
  test "git helper: without routing it delegates to `gh auth git-credential`" do
    Dir.mktmpdir do |bin|
      File.write(File.join(bin, "gh"), "#!/usr/bin/env bash\necho \"gh $*\"\ncat\n")
      File.chmod(0o755, File.join(bin, "gh"))
      env = { "PATH" => "#{bin}:#{ENV['PATH']}", "GH_TOKEN" => "ignored" }

      stdout, = run_helper(env, path: "tadasant/repo.git")

      assert_match(/\Agh auth git-credential get\n/, stdout)
      assert_includes stdout, "path=tadasant/repo.git"
    end
  end

  test "the helper takes its tokens from the environment only, never argv" do
    script = File.read(HELPER)
    assert_no_match(/\$\{?[12]\b.*password/, script)
    assert_includes script, "${!variable:-}"
  end

  # --- Ruby-only surface -------------------------------------------------------

  test "env_for overrides GH_TOKEN only for an owner with its own token" do
    assert_equal({ "GH_TOKEN" => "github_pat_pulsemcp" }, GithubTokens.env_for("pulsemcp", env: MAP))
    assert_equal({}, GithubTokens.env_for("tadasant", env: MAP))
    # Not unset: an unset GH_TOKEN would let gh fall back to the stored OAuth login.
    assert_equal({}, GithubTokens.env_for("warpdotdev", env: MAP))
    assert_equal({}, GithubTokens.env_for(nil, env: MAP))
  end

  test "session_env hands a session its owner's token and strips the rest of the map" do
    env = GithubTokens.session_env("pulsemcp", env: MAP)

    assert_equal "github_pat_pulsemcp", env["GH_TOKEN"]
    assert_equal "pulsemcp", env["ZIMMER_GITHUB_DEFAULT_OWNER"]
    assert env.key?("GH_TOKEN__PULSEMCP") && env["GH_TOKEN__PULSEMCP"].nil?
    assert env.key?("GH_TOKEN__MY_ORG") && env["GH_TOKEN__MY_ORG"].nil?
  end

  test "a session's narrowed env makes its git helper route only its own owner" do
    session = MAP.merge(GithubTokens.session_env("pulsemcp", env: MAP)).compact

    assert_equal "github_pat_pulsemcp", GithubTokens.token_for("pulsemcp", env: session)
    assert_nil GithubTokens.token_for("tadasant", env: session)
    stdout, = run_helper(session, path: "tadasant/repo.git")
    assert_equal "", stdout
  end

  test "session_env for an owner with no token leaves the session without one" do
    env = GithubTokens.session_env("warpdotdev", env: MAP)

    assert env.key?("GH_TOKEN") && env["GH_TOKEN"].nil?
  end

  test "session_env is empty before routing is on" do
    assert_equal({}, GithubTokens.session_env("tadasant", env: { "GH_TOKEN" => "x" }))
  end

  test "owner_from_url reads every github.com URL shape and nothing else" do
    assert_equal "tadasant", GithubTokens.owner_from_url("https://github.com/tadasant/zimmer.git")
    assert_equal "pulsemcp", GithubTokens.owner_from_url("https://x-access-token@github.com/pulsemcp/air")
    assert_equal "pulsemcp", GithubTokens.owner_from_url("git@github.com:pulsemcp/mcp-servers.git")
    assert_equal "pulsemcp", GithubTokens.owner_from_url("ssh://git@github.com/pulsemcp/air.git")
    assert_nil GithubTokens.owner_from_url("https://gitlab.com/tadasant/zimmer.git")
    assert_nil GithubTokens.owner_from_url("/home/rails/repos/zimmer")
  end

  test "owner_for_working_directory reads the clone's origin" do
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", dir, exception: true)
      system("git", "-C", dir, "remote", "add", "origin", "https://github.com/pulsemcp/air.git", exception: true)
      FileUtils.mkdir_p(File.join(dir, "sub"))

      assert_equal "pulsemcp", GithubTokens.owner_for_working_directory(File.join(dir, "sub"))
    end
  end

  test "owner_for_working_directory is nil for something that is not a clone" do
    Dir.mktmpdir { |dir| assert_nil GithubTokens.owner_for_working_directory(dir) }
    assert_nil GithubTokens.owner_for_working_directory("/does/not/exist")
  end

  test "variable names round-trip to owners" do
    assert_equal "GH_TOKEN__MY_ORG", GithubTokens.variable_for("my-org")
    assert_equal "my-org", GithubTokens.owner_for_variable("GH_TOKEN__MY_ORG")
    assert_nil GithubTokens.variable_for("not/an owner")
    refute GithubTokens.owner_variable?("GH_TOKEN")
    refute GithubTokens.owner_variable?("GH_TOKEN__")
  end

  test "the fingerprint changes on a rotation and does not contain a token" do
    before = GithubTokens.fingerprint(env: MAP)
    after = GithubTokens.fingerprint(env: MAP.merge("GH_TOKEN__PULSEMCP" => "github_pat_rotated"))

    refute_equal before, after
    refute_includes before, "github_pat"
  end

  private

  def run_helper(env, path:, host: "github.com", operation: "get")
    # unsetenv_others, so nothing from the test process's own environment leaks in.
    base = { "PATH" => ENV["PATH"], "HOME" => ENV["HOME"] }
    stdout, _stderr, status = Open3.capture3(base.merge(env), HELPER, operation,
                                             stdin_data: "protocol=https\nhost=#{host}\npath=#{path}\n\n",
                                             unsetenv_others: true)
    [ stdout, status ]
  end
end
