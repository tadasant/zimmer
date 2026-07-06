# frozen_string_literal: true

namespace :codex do
  desc "List the Codex (GPT) models registered in ModelCatalog. Usage: bin/rails 'codex:list_models'"
  task list_models: :environment do
    models = ModelCatalog.models_for("codex")
    default = ModelCatalog.default_for("codex")

    if models.empty?
      puts "No Codex models registered in ModelCatalog."
      next
    end

    puts "Codex models (default: #{default}):"
    models.each do |model|
      flags = []
      flags << "default" if model[:id] == default
      flags << "requires OAuth" if model[:requires_oauth]
      suffix = flags.any? ? "  [#{flags.join(", ")}]" : ""
      puts "  #{model[:id].ljust(14)} #{model[:label]}#{suffix}"
    end
  end
end
