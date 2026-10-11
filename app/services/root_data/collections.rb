# frozen_string_literal: true

module RootData
  # Reads a root's `data_collections` catalog field:
  #
  #   "data_collections": {
  #     "notes": {
  #       "description": "Things worth remembering between sessions",
  #       "schema": { "type": "object", "required": ["title"] },
  #       "retention_days": 90
  #     }
  #   }
  #
  # Every part is optional. A collection with no `schema` accepts any JSON
  # object; one with no `retention_days` keeps its records until they are
  # deleted. A bare list of names (`["notes", "runs"]`) is read as the same
  # declarations with nothing set.
  #
  # TOLERANT ON READ. The catalog is a separate artifact on its own release
  # schedule, and AirCatalogService may serve a last-known-good snapshot older
  # than this code. So a shape this reader does not understand is skipped, never
  # raised on: an entry that is not an object reads as a declaration with nothing
  # set, an unusable `retention_days` reads as none, and a name that is not a
  # valid collection name is dropped. Only a WRITE consults the declaration —
  # reads go to whatever is stored, declared or not — so no catalog, stale or
  # current, can change or hide rows that are already there.
  module Collections
    NAME_PATTERN = /\A[a-z][a-z0-9_-]{0,62}\z/

    Declaration = Data.define(:name, :description, :schema, :retention_days) do
      def expires_at(now)
        retention_days && (now + retention_days.days)
      end
    end

    module_function

    # @return [Hash{String => Declaration}]
    def declared(root)
      case (raw = root.data_collections)
      when Hash
        raw.each_with_object({}) do |(name, config), out|
          name = name.to_s
          next unless name.match?(NAME_PATTERN)

          out[name] = declaration(name, config.is_a?(Hash) ? config : {})
        end
      when Array
        raw.each_with_object({}) do |name, out|
          next unless name.is_a?(String) && name.match?(NAME_PATTERN)

          out[name] = declaration(name, {})
        end
      else
        {}
      end
    end

    def declaration(name, config)
      Declaration.new(
        name: name,
        description: config["description"].is_a?(String) ? config["description"] : nil,
        schema: config["schema"].is_a?(Hash) ? config["schema"] : nil,
        retention_days: retention_days(config["retention_days"])
      )
    end

    def retention_days(value)
      days = Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
      return nil unless days&.positive?

      [ days, Limits::MAX_RETENTION_DAYS ].min
    end

    # Problems with `data` against the declaration's schema — empty when it
    # conforms. A schema that is itself broken, or that reaches for a remote
    # `$ref`, is reported as a problem rather than skipped: a write is refused,
    # never accepted unchecked.
    #
    # @return [Array<String>]
    def schema_errors(declaration, data)
      return [] if declaration.schema.nil?

      unless JSONSchemer.valid_schema?(declaration.schema)
        return [ "the declared schema for collection \"#{declaration.name}\" is not a valid JSON Schema — " \
                 "fix the root's data_collections in the catalog" ]
      end

      JSONSchemer.schema(declaration.schema).validate(data).first(5).map { |error| error["error"] }
    rescue StandardError => e
      [ "the declared schema for collection \"#{declaration.name}\" could not be applied (#{e.class}: #{e.message})" ]
    end
  end
end
