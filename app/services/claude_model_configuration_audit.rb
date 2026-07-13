# frozen_string_literal: true

class ClaudeModelConfigurationAudit
  CONCRETE_CLAUDE_MODEL = /\A(?:(?:claude-)?(?:opus|sonnet|haiku)-\d|claude-\d)/i
  DEFAULT_SETTINGS_PATH = File.join(Dir.home, ".claude", "settings.json")

  Finding = Data.define(:location, :value, :message)

  class << self
    # +reader+ is the filesystem seam used to read the settings file. It must
    # respond to #file?(path) and #read(path); it defaults to ::File. Injecting
    # it lets tests exercise the unreadable-settings path with a scoped double
    # instead of globally stubbing File.file?/File.read — a process-wide
    # monkeypatch that races background threads under the parallel suite.
    def findings(env: ENV, settings_path: DEFAULT_SETTINGS_PATH, reader: File)
      [].tap do |results|
        anthropic_model = env["ANTHROPIC_MODEL"]
        if concrete_model?(anthropic_model)
          results << Finding.new(
            location: "ANTHROPIC_MODEL",
            value: anthropic_model,
            message: "Use a floating Claude alias such as opus instead of a concrete model version."
          )
        end

        settings_entries(settings_path, reader).each do |key, value|
          if concrete_model?(value)
            results << Finding.new(
              location: "#{settings_path}:#{key}",
              value: value,
              message: "Remove the settings.json model pin or use a floating Claude alias such as opus."
            )
          end
        end
      end
    end

    def pinned?(**kwargs)
      findings(**kwargs).any?
    end

    def warn_if_pinned!(logger: Rails.logger)
      return if @warned

      current_findings = findings
      current_findings.each do |finding|
        logger.warn(
          "[ClaudeModelConfigurationAudit] concrete Claude model pin detected " \
          "location=#{finding.location.inspect} value=#{finding.value.inspect} message=#{finding.message}"
        )
      end
      @warned = true if current_findings.any?
    rescue => e
      logger.warn("[ClaudeModelConfigurationAudit] model pin audit failed: #{e.class}: #{e.message}")
    end

    def concrete_model?(value)
      value.to_s.match?(CONCRETE_CLAUDE_MODEL)
    end

    private

    def settings_entries(path, reader = File)
      return [] unless reader.file?(path)

      data = JSON.parse(reader.read(path))
      return [] unless data.is_a?(Hash)

      entries = []
      entries << [ "model", data["model"] ] if data.key?("model")
      entries << [ "ANTHROPIC_MODEL", data["ANTHROPIC_MODEL"] ] if data.key?("ANTHROPIC_MODEL")

      env = data["env"]
      if env.is_a?(Hash) && env.key?("ANTHROPIC_MODEL")
        entries << [ "env.ANTHROPIC_MODEL", env["ANTHROPIC_MODEL"] ]
      end

      entries
    rescue => e
      Rails.logger.warn("[ClaudeModelConfigurationAudit] could not read #{path}: #{e.class}: #{e.message}")
      []
    end
  end
end
