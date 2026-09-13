# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors Settings → Models and /api/v1/model_catalog_entries (#85): list each
    # runtime's models, add one without a deploy, remove an added one. All three
    # surfaces write through ModelCatalogEntry.add, so the validation and the CLI
    # check are the same wherever a model is added.
    class ManageModels < Tool
      ACTIONS = %w[list add remove].freeze

      tool_name "manage_models"

      description <<~DESC
        Manage the models each agent runtime offers. What is listed here is what `start_session`'s `config.model`, the session model editor and the new-session form accept.

        Built-in models ship with Zimmer and cannot be changed here. Added models are offered alongside them as soon as they are added, with no deploy.

        **Actions:**
        - **list**: Every runtime's models, built-in and added. Each added model shows what the installed CLI said about it when it was added.
        - **add**: Add a model (requires "runtime" and "model_id"; optional "label", "requires_oauth", "allow_unlisted"). Use the id exactly as the CLI takes it. Pi ids name their provider, like `openrouter/google/gemini-3.5-pro`. Claude Code ids must be floating aliases, not versions, and no runtime takes a dated snapshot.

          Before saving, Zimmer asks the CLI in the image whether it knows the id: Codex and Pi each have a model list, and Claude Code has none, so a Claude Code id is saved unchecked. **An id the CLI does not list is refused** unless "allow_unlisted" is true. Adding a model installs nothing. Codex and Pi still pass an unlisted id to the provider, which accepts or refuses it on the session's first turn, so only set "allow_unlisted" for a model you know the provider serves, such as one released after the CLI in the image.
        - **remove**: Remove an added model (requires "runtime" and "model_id"). New sessions can no longer pick it, and sessions already on it keep it. Refused while the Settings page's session default or the categorization model names it.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "The model catalog action to perform."
          },
          runtime: {
            type: "string",
            enum: ModelCatalog.runtimes,
            description: 'Runtime key. Required for "add" and "remove".'
          },
          model_id: {
            type: "string",
            description: 'Model id exactly as the CLI takes it. Required for "add" and "remove".'
          },
          label: {
            type: "string",
            description: 'For "add". What pickers show. Defaults to the id.'
          },
          requires_oauth: {
            type: "boolean",
            description: 'For "add". True when the model only runs with an interactive (ChatGPT or Claude) login rather than an API key. Default false.'
          },
          allow_unlisted: {
            type: "boolean",
            description: 'For "add". Save the model even though the installed CLI\'s model list does not name it. Default false.'
          }
        },
        required: [ "action" ]
      })

      def call(args)
        case require_arg(args, :action).to_s
        when "list" then list
        when "add" then add(args)
        when "remove" then remove(args)
        else
          raise ToolError, "Unknown action \"#{args["action"]}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      end

      private

      def list
        lines = [ "## Models", "" ]
        ModelCatalog.runtimes.each do |runtime|
          default = ModelCatalog.default_for(runtime)
          lines << "### #{RuntimeRegistry.label_for(runtime)} (`#{runtime}`)" << ""
          ModelCatalog.models_for(runtime).each do |model|
            lines << format_model(model, default: model[:id] == default)
          end
          lines << ""
        end
        lines.join("\n").rstrip
      end

      def add(args)
        entry = ModelCatalogEntry.add(
          runtime: require_arg(args, :runtime),
          model_id: require_arg(args, :model_id),
          label: args["label"],
          requires_oauth: args["requires_oauth"],
          allow_unlisted: args["allow_unlisted"],
          added_via: "mcp"
        )

        unless entry.persisted?
          message = "Validation failed: #{entry.errors.full_messages.join(', ')}"
          message += " Pass allow_unlisted: true to add it anyway." if entry.errors.of_kind?(:model_id, :unlisted)
          raise ToolError, message
        end

        [
          "## Model Added",
          "",
          "- **Runtime:** `#{entry.runtime}`",
          "- **Model:** `#{entry.model_id}`",
          "- **Label:** #{entry.display_label}",
          "- **Requires OAuth:** #{entry.requires_oauth}",
          "- **CLI check:** #{cli_check(entry.cli_listed, entry.cli_note)}"
        ].join("\n")
      end

      def remove(args)
        runtime = require_arg(args, :runtime).to_s
        model_id = require_arg(args, :model_id).to_s
        entry = ModelCatalogEntry.find_by(runtime: runtime, model_id: model_id)

        if entry.nil?
          built_in = ModelCatalog.runtimes.include?(runtime) &&
            ModelCatalog.built_in_models_for(runtime).any? { |model| model[:id] == model_id }
          raise ToolError, "`#{model_id}` is a built-in #{runtime} model; only added models can be removed." if built_in

          raise ToolError, "No added #{runtime} model `#{model_id}`. Call with action \"list\" to see them."
        end

        raise ToolError, entry.destroy_refusal unless entry.destroy

        "Removed `#{model_id}` from `#{runtime}`. New sessions can no longer pick it."
      end

      def format_model(model, default:)
        notes = []
        notes << "default" if default
        notes << (model[:source] == "added" ? "added" : "built in")
        notes << "requires OAuth" if model[:requires_oauth]
        label = model[:label].present? && model[:label] != model[:id] ? " — #{model[:label]}" : ""
        line = "- `#{model[:id]}` (#{notes.join(', ')})#{label}"
        return line unless model[:source] == "added"

        "#{line}\n  - CLI check: #{cli_check(model[:cli_listed], model[:cli_note])}"
      end

      def cli_check(listed, note)
        verdict = case listed
        when true then "listed"
        when false then "NOT LISTED"
        else "not checked"
        end
        "#{verdict}. #{note}"
      end
    end
  end
end
