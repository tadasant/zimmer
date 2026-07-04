# frozen_string_literal: true

namespace :claude do
  desc "Audit ambient Claude model configuration for concrete version pins"
  task audit_model_configuration: :environment do
    findings = ClaudeModelConfigurationAudit.findings

    if findings.empty?
      puts "No concrete Claude model pins detected in ambient configuration."
      next
    end

    puts "Concrete Claude model pins detected:"
    findings.each do |finding|
      puts "- #{finding.location}: #{finding.value} (#{finding.message})"
    end

    abort "Replace concrete Claude model versions with floating aliases."
  end
end
