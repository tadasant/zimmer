# frozen_string_literal: true

# Pins an AIR catalog dependency to a specific git ref so its content stops
# tracking HEAD. Each row maps a `github://owner/repo` catalog prefix to a ref
# (commit SHA, tag, or branch). AirCatalogService rewrites the active air.json's
# matching URIs with these refs (see AirCatalogRefRewriter), freezing both
# catalog resolution and agent-session setup to the pinned content.
#
# A catalog with no row tracks the latest HEAD (the default behavior).
class CatalogPin < ApplicationRecord
  # github://owner/repo (no trailing path, no @ref). The set of pinnable
  # catalogs is derived from the active air.json's `catalogs` array.
  CATALOG_FORMAT = %r{\Agithub://[^/@\s]+/[^/@\s]+\z}

  # Refs may be SHAs, tags, or branches. Branches/tags can contain slashes
  # (e.g. "user/feature"); disallow whitespace and the `@` delimiter that
  # would corrupt the rewritten URI.
  REF_FORMAT = %r{\A[^\s@]+\z}

  validates :catalog, presence: true, uniqueness: true, format: { with: CATALOG_FORMAT }
  validates :ref, presence: true, format: { with: REF_FORMAT }

  # @return [Hash{String => String}] { "github://owner/repo" => "ref" } for the
  #   rewriter. Excludes blanks defensively.
  def self.as_map
    all.each_with_object({}) do |pin, map|
      map[pin.catalog] = pin.ref if pin.ref.present?
    end
  end

  # Cheap, stable signature of the current pin set. Used to invalidate the
  # generated effective air.json across processes (web + worker) without a
  # shared filesystem — any pin insert/update/delete changes count or max
  # updated_at, so each process regenerates its local copy on the next read.
  # @return [String]
  def self.fingerprint
    scope = all
    "#{scope.count}:#{scope.maximum(:updated_at)&.to_f}"
  end
end
