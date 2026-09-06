# Produces a *relocatable* copy of an air.json document. Two transforms, applied
# in that order by both callers, and deliberately kept separate so a caller can
# tell "the pin changed nothing" from "the pin changed something":
#
#   - `rewrite` pins each matching `github://owner/repo/...` catalog URI to a ref.
#   - `absolutize_sources` turns the document's relative local source paths into
#     absolute ones, so the copy still resolves from wherever it is written. It
#     mirrors AIR's own resolution rules (`getScheme` for the path-or-provider
#     split, `path.resolve` semantics for the anchoring) rather than guessing at
#     them, because "resolves identically from anywhere" is the whole property.
#
# `relocated` composes the two for the callers that write a copy. Two callers:
#   - staging.rb, when AIR_CATALOG_REF is set, to pin tadasant/zimmer-catalog for a
#     deploy that tests catalog changes from a branch before merging.
#   - AirCatalogService, to apply the UI-configured CatalogPin set (any of the
#     catalogs in air.production.json) so a specific commit SHA can be frozen.
#
# `pins` is a map of `github://owner/repo` prefix => ref. Only URIs whose repo
# matches a pinned prefix are touched; everything else passes through unchanged.
# Longer prefixes are matched first so a pin on `github://tadasant/zimmer-catalog`
# never swallows a sibling repo like `github://tadasant/zimmer-catalog-foo`.
#
# The chosen syntax depends on the ref:
# - Refs without a slash use the repo-level form: `github://owner/repo@ref/path`
# - Refs containing a slash (e.g. `feature/branch`) use the legacy
#   path-suffix form: `github://owner/repo/path@ref`. The provider docs
#   require this for refs with slashes.
#
# Any ref already present on a matched URI is dropped — the pin expresses the
# operator's intent and wins over whatever ref the file may have hard-coded.
class AirCatalogRefRewriter
  CATALOG_PREFIX = "github://tadasant/zimmer-catalog"

  # The air.json keys whose array entries are always local index paths — the six
  # artifact types AIR resolves from `./<type>/<type>.json` siblings. Held here
  # rather than read from AirCatalogService::ARTIFACT_TYPES because staging.rb
  # `require_relative`s this file at boot, before autoloading; a test keeps the
  # two lists in step.
  LOCAL_SOURCE_KEYS = %w[skills mcp roots references hooks plugins].freeze

  # Every key AIR resolves against the config file's own directory. `catalogs`
  # belongs here too: AIR's `resolveCatalogRoot` is
  # `getScheme(c) ? provider.resolveCatalogDir(c) : resolve(baseDir, c)`, so a
  # `catalogs` entry with no provider scheme — `"."`, `"vendor/shared"` — is an
  # ordinary path, and one left relative in a relocated copy discovers nothing
  # (`discoverCatalogIndexes` returns `[]` for a directory that isn't there).
  PATH_KEYS = (LOCAL_SOURCE_KEYS + %w[catalogs]).freeze

  # `extensions` is the one key that is not path-or-URI. AIR's extension loader
  # treats an entry as a local path only when it starts with `./`, `../` or `/`,
  # and as an npm package specifier otherwise.
  EXTENSIONS_KEY = "extensions"

  # AIR's `getScheme`: a `scheme://` prefix routes an entry to a catalog
  # provider instead of the filesystem — except `file://`, which AIR explicitly
  # treats as local. Everything `getScheme` calls local gets anchored.
  PROVIDER_SCHEME = %r{\A(?!file://)[a-zA-Z][a-zA-Z0-9+.\-]*://}i

  class << self
    # @param json_string [String] an air.json document
    # @param pins [Hash{String => String}] { "github://owner/repo" => "ref" }
    # @return [String] pretty-printed rewritten document
    def rewrite(json_string, pins:)
      cleaned = normalize_pins(pins)
      parsed = JSON.parse(json_string)
      return JSON.pretty_generate(parsed) if cleaned.empty?

      JSON.pretty_generate(deep_rewrite(parsed, cleaned))
    end

    # Rewrite the document's relative local source paths to absolute paths
    # anchored at `base_dir`.
    #
    # AIR resolves a config's local index paths **relative to the config file's
    # own directory**, and Zimmer's catalogs declare exactly such paths
    # (`"skills": ["./skills/skills.json"]` and five siblings). So a copy of a
    # catalog is only equivalent to the original if it sits in the same
    # directory or carries absolute paths. Callers write their copy elsewhere
    # (`tmp/`), which makes this the second half of producing that copy: without
    # it, `./skills/skills.json` resolves to `tmp/skills/skills.json`, AIR finds
    # no index files, and the resolve exits 0 with an empty catalog (#1078).
    #
    # @param json_string [String] an air.json document
    # @param base_dir [String] the directory the document's relative paths are
    #   currently anchored at — i.e. the directory holding the *base* config
    # @return [String] pretty-printed document with absolute local source paths
    def absolutize_sources(json_string, base_dir:)
      parsed = JSON.parse(json_string)
      base = File.expand_path(base_dir)

      PATH_KEYS.each do |key|
        next unless parsed[key].is_a?(Array)

        parsed[key] = parsed[key].map { |entry| anchor_if_local(entry, base) }
      end

      if parsed[EXTENSIONS_KEY].is_a?(Array)
        parsed[EXTENSIONS_KEY] = parsed[EXTENSIONS_KEY].map do |entry|
          local_extension?(entry) ? anchor(entry, base) : entry
        end
      end

      JSON.pretty_generate(parsed)
    end

    # Apply the pins and, if that changed anything, hand back a document whose
    # local source paths still resolve from wherever the caller writes it. The
    # two callers both need exactly this, in exactly this order, so they share
    # it rather than each spelling out the sequence.
    #
    # @param json_string [String] an air.json document
    # @param pins [Hash{String => String}] { "github://owner/repo" => "ref" }
    # @param base_dir [String] the directory the document's relative paths are
    #   currently anchored at
    # @return [String, nil] the relocatable document, or nil when the pins
    #   matched nothing this config declares and there is nothing to write.
    #   Compared on the parsed documents, because `rewrite` re-serializes with
    #   JSON.pretty_generate whether or not it matched anything, so the source
    #   text is never the baseline.
    def relocated(json_string, pins:, base_dir:)
      rewritten = rewrite(json_string, pins: pins)
      return nil if JSON.parse(rewritten) == JSON.parse(json_string)

      absolutize_sources(rewritten, base_dir: base_dir)
    end

    private

    # Anchor an entry AIR would resolve against the config's own directory;
    # leave a provider URI (`github://…`) for its provider to resolve.
    def anchor_if_local(entry, base)
      return entry unless entry.is_a?(String)
      return entry if entry.empty? || entry.match?(PROVIDER_SCHEME)

      anchor(entry, base)
    end

    def local_extension?(entry)
      entry.is_a?(String) && (entry.start_with?("./") || entry.start_with?("../") || entry.start_with?("/"))
    end

    # The Ruby equivalent of AIR's `path.resolve(baseDir, entry)`. The two agree
    # on everything — including leaving an absolute path alone and collapsing
    # `..` — except a leading `~`, which File.expand_path expands to this
    # process's home directory where path.resolve treats it as an ordinary path
    # segment. Joining first keeps AIR's reading of the document rather than
    # substituting Ruby's.
    def anchor(entry, base)
      entry.start_with?("~") ? File.expand_path(File.join(base, entry)) : File.expand_path(entry, base)
    end

    # Drop blank refs and order by descending prefix length for longest-match.
    def normalize_pins(pins)
      pins
        .reject { |prefix, ref| prefix.blank? || ref.nil? || ref.to_s.strip.empty? }
        .sort_by { |prefix, _| -prefix.length }
    end

    def deep_rewrite(node, pins)
      case node
      when Hash
        node.transform_values { |v| deep_rewrite(v, pins) }
      when Array
        node.map { |v| deep_rewrite(v, pins) }
      when String
        rewrite_uri(node, pins)
      else
        node
      end
    end

    def rewrite_uri(uri, pins)
      pins.each do |prefix, ref|
        next unless uri.start_with?(prefix)

        tail = uri[prefix.length..]
        # Require a delimiter after the repo name so we don't mangle sibling
        # repos like `github://tadasant/zimmer-catalog-foo/...`.
        next unless tail.empty? || tail.start_with?("/", "@")

        return apply_ref(prefix, tail, ref, uri)
      end
      uri
    end

    def apply_ref(prefix, tail, ref, original_uri)
      path =
        if tail.start_with?("@")
          # Repo-level ref already present: `@ref/path` or just `@ref`.
          slash_idx = tail.index("/")
          slash_idx ? tail[slash_idx..] : ""
        else
          # No repo-level ref. Strip a path-suffix ref if present.
          # Legacy syntax: `path@ref`, where the ref runs from the first `@`
          # in the tail to the end of the URI. Refs may contain slashes, so
          # we must use the *first* `@`, not search backward.
          at_idx = tail.index("@")
          at_idx ? tail[0...at_idx] : tail
        end

      if ref.include?("/")
        # Legacy syntax required for refs containing a slash.
        if path.empty? || path == "/"
          raise ArgumentError,
            "cannot rewrite #{original_uri.inspect} with ref containing '/': URI has no path component"
        end
        "#{prefix}#{path}@#{ref}"
      else
        "#{prefix}@#{ref}#{path}"
      end
    end
  end
end
