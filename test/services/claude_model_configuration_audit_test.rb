# frozen_string_literal: true

require "test_helper"

class ClaudeModelConfigurationAuditTest < ActiveSupport::TestCase
  test "flags concrete ANTHROPIC_MODEL pins" do
    findings = ClaudeModelConfigurationAudit.findings(
      env: { "ANTHROPIC_MODEL" => "claude-opus-4-7" },
      settings_path: missing_settings_path
    )

    assert_equal 1, findings.size
    assert_equal "ANTHROPIC_MODEL", findings.first.location
    assert_equal "claude-opus-4-7", findings.first.value
  end

  test "flags concrete settings model pins" do
    Dir.mktmpdir do |dir|
      settings_path = File.join(dir, "settings.json")
      File.write(settings_path, { model: "opus-4-7" }.to_json)

      findings = ClaudeModelConfigurationAudit.findings(env: {}, settings_path: settings_path)

      assert_equal 1, findings.size
      assert_equal "#{settings_path}:model", findings.first.location
      assert_equal "opus-4-7", findings.first.value
    end
  end

  test "flags older concrete Claude model id shapes" do
    findings = ClaudeModelConfigurationAudit.findings(
      env: { "ANTHROPIC_MODEL" => "claude-3-5-sonnet-20241022" },
      settings_path: missing_settings_path
    )

    assert_equal 1, findings.size
    assert_equal "claude-3-5-sonnet-20241022", findings.first.value
  end

  test "flags settings env model pins" do
    Dir.mktmpdir do |dir|
      settings_path = File.join(dir, "settings.json")
      File.write(settings_path, { env: { ANTHROPIC_MODEL: "claude-opus-4-7" } }.to_json)

      findings = ClaudeModelConfigurationAudit.findings(env: {}, settings_path: settings_path)

      assert_equal 1, findings.size
      assert_equal "#{settings_path}:env.ANTHROPIC_MODEL", findings.first.location
      assert_equal "claude-opus-4-7", findings.first.value
    end
  end

  test "allows floating Claude aliases" do
    Dir.mktmpdir do |dir|
      settings_path = File.join(dir, "settings.json")
      File.write(settings_path, { model: "opus" }.to_json)

      findings = ClaudeModelConfigurationAudit.findings(
        env: { "ANTHROPIC_MODEL" => "sonnet" },
        settings_path: settings_path
      )

      assert_empty findings
    end
  end

  test "treats unreadable settings as a non-fatal empty audit result" do
    # Inject a scoped reader that reports the file exists but raises EACCES on
    # read, rather than globally stubbing File.file?/File.read. A process-wide
    # File stub races the suite's background threads (otel exporter, catalog
    # refresher, etc.), which call File.read with argument shapes the stub's
    # arity can't accept — the source of this test's historical flakiness.
    unreadable_reader = Class.new do
      def file?(_path) = true
      def read(_path) = raise(Errno::EACCES, "settings.json")
    end.new

    assert_empty ClaudeModelConfigurationAudit.findings(
      env: {},
      settings_path: missing_settings_path,
      reader: unreadable_reader
    )
  end

  private

  def missing_settings_path
    File.join(Dir.tmpdir, "missing-claude-settings-#{SecureRandom.hex}.json")
  end
end
