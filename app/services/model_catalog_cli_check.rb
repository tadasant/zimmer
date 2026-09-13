# frozen_string_literal: true

require "json"

# Asks the installed agent CLI whether it knows a model id, so a model added to
# ModelCatalog at runtime is checked against the binary that will run it rather
# than only against a regex (#85).
#
# Two of the three runtimes can answer offline, from the model list bundled with
# the pinned CLI:
#
#   codex  `codex debug models` prints the catalog as JSON; each entry's `slug` is
#          what `-m` takes.
#   pi     `pi --offline --list-models` prints a table of provider and model. It
#          only prints providers whose credential resolves, so the check sets a
#          placeholder key for the provider named in the id. `--offline` means no
#          network call, so the placeholder never leaves the box. It reads Pi's
#          models.json from PiHome, as a session does, so a custom provider
#          declared there counts.
#
# Claude Code has no model list to ask. It passes the id to Anthropic, which
# accepts or refuses it on the session's first turn.
#
# An id missing from a list is not proof it will fail. Codex passes an unknown
# slug to the API, and Pi warns and uses it as a custom model id, so the provider
# decides at the first turn. The check reports that as `listed: false` with a note
# saying so. ModelCatalogEntry.add refuses such an id unless the caller says to add
# it anyway.
#
# Never raises. A CLI that is missing, times out or prints something unparseable
# gives `listed: nil` and a note naming what went wrong, and the model can still
# be added.
class ModelCatalogCliCheck
  Result = Data.define(:listed, :cli_version, :note)

  class CommandFailed < StandardError; end

  TIMEOUT = 20

  # Pi's variable per provider, where it is not `<PROVIDER>_API_KEY`. From the
  # provider table in the pinned Pi's docs/providers.md.
  PI_KEY_VARIABLES = {
    "google" => "GEMINI_API_KEY",
    "vercel-ai-gateway" => "AI_GATEWAY_API_KEY",
    "kimi-coding" => "KIMI_API_KEY",
    "opencode-go" => "OPENCODE_API_KEY",
    "qwen-token-plan-individual" => "QWEN_TOKEN_PLAN_API_KEY",
    "cloudflare-ai-gateway" => "CLOUDFLARE_API_KEY",
    "cloudflare-workers-ai" => "CLOUDFLARE_API_KEY"
  }.freeze

  # Pi's `--model` takes an optional `:<thinking>` suffix, which is not part of
  # the listed id.
  PI_THINKING_SUFFIX = /:(?:off|minimal|low|medium|high|xhigh|max)\z/

  class << self
    # @param runtime [String] a ModelCatalog runtime key
    # @param model_id [String]
    # @return [Result]
    def check(runtime, model_id)
      case runtime.to_s
      when "codex" then check_codex(model_id.to_s)
      when "pi" then check_pi(model_id.to_s)
      when "claude_code"
        Result.new(
          listed: nil,
          cli_version: nil,
          note: "Claude Code has no model list to check against. It passes the id to Anthropic, " \
                "which accepts or refuses it on the session's first turn."
        )
      else
        Result.new(listed: nil, cli_version: nil, note: "No CLI check exists for the #{runtime} runtime.")
      end
    end

    private

    def check_codex(model_id)
      version = version_of("codex")
      stdout = run!([ "codex", "debug", "models" ])
      slugs = Array(JSON.parse(stdout)["models"]).filter_map { |model| model["slug"] if model.is_a?(Hash) }
      return unreadable("codex", version, "its model list was empty") if slugs.empty?

      if slugs.include?(model_id)
        Result.new(listed: true, cli_version: version, note: "Listed by #{named("codex", version)}.")
      else
        Result.new(
          listed: false,
          cli_version: version,
          note: "Not in #{named("codex", version)}'s model list. Codex still sends the id to OpenAI, " \
                "which accepts or refuses it on the session's first turn."
        )
      end
    rescue JSON::ParserError, NoMethodError, TypeError => e
      unreadable("codex", version, "could not parse `codex debug models`: #{e.class}")
    rescue CommandFailed => e
      unreadable("codex", version, e.message)
    end

    def check_pi(model_id)
      provider, _rest = model_id.split("/", 2)
      version = version_of("pi")
      stdout = run!([ "pi", "--offline", "--list-models" ], env: pi_env(provider))
      ids = pi_listed_ids(stdout)
      provider_ids = ids.select { |id| id.start_with?("#{provider}/") }

      if provider_ids.empty?
        return Result.new(
          listed: nil,
          cli_version: version,
          note: "#{named("pi", version)} lists no models for the #{provider} provider, so the id could not be checked."
        )
      end

      if provider_ids.include?(model_id) || provider_ids.include?(model_id.sub(PI_THINKING_SUFFIX, ""))
        Result.new(listed: true, cli_version: version, note: "Listed by #{named("pi", version)}.")
      else
        Result.new(
          listed: false,
          cli_version: version,
          note: "Not in #{named("pi", version)}'s model list for #{provider}. Pi uses an unlisted id as a custom " \
                "model id, and the provider accepts or refuses it on the session's first turn."
        )
      end
    rescue CommandFailed => e
      unreadable("pi", version, e.message)
    end

    # `provider  model  context  max-out  thinking  images`, one row per model,
    # after a header row.
    def pi_listed_ids(stdout)
      stdout.lines.filter_map do |line|
        provider, model = line.split
        next if provider.nil? || model.nil? || provider == "provider"

        "#{provider}/#{model}"
      end
    end

    def pi_env(provider)
      variable = PI_KEY_VARIABLES.fetch(provider.to_s) { "#{provider.to_s.upcase.tr("-", "_")}_API_KEY" }
      {
        "PI_CODING_AGENT_DIR" => PiHome.path,
        "PI_OFFLINE" => "1",
        "PI_SKIP_VERSION_CHECK" => "1",
        "PI_TELEMETRY" => "0",
        variable => "zimmer-model-catalog-check"
      }
    end

    def version_of(cli)
      stdout = run!([ cli, "--version" ])
      stdout[/\d+\.\d+\.\d+/]
    rescue CommandFailed
      nil
    end

    def named(cli, version)
      [ cli, version ].compact.join(" ")
    end

    def unreadable(cli, version, reason)
      Result.new(listed: nil, cli_version: version, note: "Could not check against #{cli}: #{reason}.")
    end

    def run!(argv, env: {})
      stdout, stderr, status = BoundedSubprocess.run(argv, timeout: TIMEOUT, env: env)
      unless status&.success?
        raise CommandFailed, "`#{argv.join(" ")}` exited #{status&.exitstatus.inspect}: #{stderr.to_s.strip.truncate(200)}"
      end

      stdout
    rescue BoundedSubprocess::TimeoutError
      raise CommandFailed, "`#{argv.join(" ")}` timed out after #{TIMEOUT}s"
    rescue SystemCallError => e
      raise CommandFailed, "`#{argv.first}` could not be run (#{e.class})"
    end
  end
end
