# Rewrites `github://owner/repo/...` URIs in an air.json document to pin each
# matching catalog to a specific git ref. Two callers:
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
  PULSEMCP_PREFIX = "github://tadasant/zimmer-catalog"

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

    private

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
