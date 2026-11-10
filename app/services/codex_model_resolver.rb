# frozen_string_literal: true

require "json"

# Turns a Codex catalog id into the `-m` value a session launches with, so that
# Zimmer's Codex choices carry no version number — the Codex counterpart to the
# Claude Code aliases (`opus`, `sonnet`, ...) that the Claude CLI floats for us.
#
# The Codex CLI has no floating aliases of its own: `-m` takes a concrete slug
# (`gpt-5.6-terra`), and only an omitted `-m` follows OpenAI's moving default. So
# Zimmer's built-in Codex ids are model *families* — `sol`, `terra`, `luna` — and
# this class resolves a family to the newest slug of the shape
# `gpt-<version>-<family>` that the installed CLI lists:
#
# 1. the live catalog, `codex debug models`, which the CLI refreshes from OpenAI
#    with the session's own login, so a model OpenAI ships reaches sessions with
#    no Zimmer change and no CLI bump. It is also filtered to what that login's
#    plan may run: with a ChatGPT login that is not offered Sol, `gpt-5.6-sol` is
#    absent from it and refused by the API (400 `model_not_found`) — so when
#    the live list can be read, it is the only one consulted;
# 2. the catalog bundled with the binary, `codex debug models --bundled`, only
#    when the live one cannot be read (no network, a CLI error).
#
# A slug carrying an `upgrade` (the CLI's own "this model is retired, use X"
# marker) never wins. When neither list names the family — OpenAI renamed its
# tiers, or the CLI is missing — the model resolves to nil and the adapter omits
# `-m`, so the session runs on the CLI's own default rather than failing.
#
# A legacy pinned id (ModelCatalog::LEGACY_MODEL_ALIASES, e.g. `gpt-5.6-terra`)
# resolves through its family the same way. Any other id — an operator-added
# model, or a pin the operator added deliberately — passes through verbatim.
#
# The parsed catalogs are cached briefly, so a burst of launches makes one CLI
# call rather than one each.
class CodexModelResolver
  TIMEOUT = 15
  CACHE_TTL = 10.minutes
  # How long an unreadable live catalog is remembered: long enough that a burst
  # of launches does not each wait out the timeout, short enough that a blip
  # does not decide which model sessions get for the full TTL.
  FAILED_LIVE_CACHE_TTL = 30.seconds
  CACHE_KEY = "codex_model_resolver/catalog/v1"

  # Catalogs to use instead of asking the CLI, in #catalogs' shape. The test
  # suite sets it, so no test shells out to `codex` or reaches OpenAI.
  class_attribute :catalog_override, default: nil

  class << self
    # @param model [String, nil] a session's configured model
    # @return [String, nil] the slug to pass to `-m`, or nil to omit it
    def resolve(model)
      return nil if model.blank?

      family = ModelCatalog.codex_family_for(model)
      return model.to_s unless family

      latest_in_family(family).tap do |slug|
        Rails.logger.warn("[CodexModelResolver] no `gpt-*-#{family}` model in the Codex CLI's catalog; " \
                          "launching #{model.inspect} on the CLI's default model") if slug.nil?
      end
    end

    # @param family [String] e.g. "terra"
    # @return [String, nil] the newest current slug in the family
    def latest_in_family(family)
      live, bundled = catalogs
      newest(live.presence || bundled, family)
    end

    # The newest slug of the form `gpt-<version>-<family>`, by version.
    #
    # @param slugs [Array<String>]
    # @return [String, nil]
    def newest(slugs, family)
      pattern = /\Agpt-(\d+(?:\.\d+)*)-#{Regexp.escape(family)}\z/
      slugs.filter_map { |slug| (m = pattern.match(slug)) && [ Gem::Version.new(m[1]), slug ] }
           .max_by(&:first)&.last
    end

    # Current (not upgraded-away) slugs from the live catalog and the bundled
    # one, in that order. An unreadable catalog is an empty list. The bundled one
    # is only read when the live one could not be, and that answer is cached for
    # FAILED_LIVE_CACHE_TTL rather than CACHE_TTL.
    #
    # @return [Array(Array<String>, Array<String>)]
    def catalogs
      return catalog_override if catalog_override

      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached

      live = read_catalog([ "codex", "debug", "models" ])
      result = [ live, live.empty? ? read_catalog([ "codex", "debug", "models", "--bundled" ]) : [] ]
      Rails.cache.write(CACHE_KEY, result, expires_in: live.empty? ? FAILED_LIVE_CACHE_TTL : CACHE_TTL)
      result
    end

    private

    def read_catalog(argv)
      stdout, stderr, status = BoundedSubprocess.run(argv, timeout: TIMEOUT, env: { "CODEX_HOME" => CodexHome.path })
      unless SubprocessStatus.success?(status)
        Rails.logger.warn("[CodexModelResolver] `#{argv.join(" ")}` failed: #{stderr.to_s.scrub.strip.truncate(200)}")
        return []
      end

      models = JSON.parse(stdout.to_s)["models"]
      Array(models).filter_map do |entry|
        entry["slug"].to_s.presence if entry.is_a?(Hash) && entry["upgrade"].blank?
      end
    rescue JSON::ParserError, TypeError, NoMethodError, BoundedSubprocess::TimeoutError, SystemCallError => e
      Rails.logger.warn("[CodexModelResolver] could not read `#{argv.join(" ")}`: #{e.class}")
      []
    end
  end
end
