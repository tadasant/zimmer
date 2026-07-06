# frozen_string_literal: true

require "test_helper"

class CodexHomeTest < ActiveSupport::TestCase
  setup do
    @original_codex_home = ENV["CODEX_HOME"]
  end

  teardown do
    if @original_codex_home.nil?
      ENV.delete("CODEX_HOME")
    else
      ENV["CODEX_HOME"] = @original_codex_home
    end
  end

  test "path defaults to ~/.codex when CODEX_HOME is unset" do
    ENV.delete("CODEX_HOME")
    assert_equal File.join(Dir.home, ".codex"), CodexHome.path
  end

  test "path honors the CODEX_HOME env override" do
    ENV["CODEX_HOME"] = "/srv/codex-state"
    assert_equal "/srv/codex-state", CodexHome.path
  end

  test "path falls back to the default when CODEX_HOME is blank" do
    ENV["CODEX_HOME"] = ""
    assert_equal File.join(Dir.home, ".codex"), CodexHome.path
  end

  test "sessions_path nests sessions under CODEX_HOME" do
    ENV["CODEX_HOME"] = "/srv/codex-state"
    assert_equal "/srv/codex-state/sessions", CodexHome.sessions_path
  end

  test "auth_json_path nests auth.json under CODEX_HOME" do
    ENV["CODEX_HOME"] = "/srv/codex-state"
    assert_equal "/srv/codex-state/auth.json", CodexHome.auth_json_path
  end

  test "sessions_path and auth_json_path default under ~/.codex when unset" do
    ENV.delete("CODEX_HOME")
    assert_equal File.join(Dir.home, ".codex", "sessions"), CodexHome.sessions_path
    assert_equal File.join(Dir.home, ".codex", "auth.json"), CodexHome.auth_json_path
  end
end
