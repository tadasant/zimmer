# frozen_string_literal: true

module ParameterStore
  # Canonical parameter paths, and the lossy fold from a path to a GCP resource id.
  #
  # A Zimmer secret lives at:
  #
  #     /zimmer/{env}/secrets/static/{VARIABLE_NAME}
  #
  # Two segments, two different jobs:
  #
  #   * `secrets` is the *scope* — whose secrets these are and what they are for.
  #     It says "every static secret this Zimmer resolves", which is what the
  #     namespace actually holds: `GH_TOKEN` (the `gh` CLI's token) and
  #     `OPENROUTER_API_KEY` (Pi's provider credential) are not MCP secrets, and
  #     they were never going to be the last of their kind.
  #   * `static` is the *kind*. It is here from day one so a future kind
  #     (`oauth`, say) is a new prefix rather than a migration of every existing
  #     path.
  #
  # ## The pre-rename namespace, and why reads still cover it
  #
  # This scope segment used to be `mcp`. {.parameter_id} is a LOSSY fold of the
  # whole path, so a renamed path folds to a DIFFERENT resource id: a rename is
  # create-new + verify + delete-old (see {NamespaceMigration}), never an edit in
  # place. Code deploys and data moves are separate events in either order, and
  # the resolution chain's contract is that *a miss is not an error* — so a
  # resolver that read only the new namespace before the data moved would report
  # every secret as simply unset. {.read_namespaces} therefore returns both, new
  # first, and the old one is dropped only once the store is confirmed empty of
  # it. The Connectors page says which namespace answered.
  #
  # Zimmer's namespace is flat — one bucket of `${VAR}` names — because its
  # `${VAR}` references are global to the catalog rather than scoped per server:
  # two catalog entries that both say `${STRAD_API_KEY}` mean the same key.
  module Namespace
    # The scope segment: whose secrets, and what for.
    SCOPE = "secrets"

    # The scope segment these paths carried before the rename. Read-only: nothing
    # writes here any more.
    LEGACY_SCOPE = "mcp"

    # The kind segment. A second kind is a new prefix, not a migration.
    KIND = "static"

    # Zimmer's `${VAR}` names are environment-variable names, and the fold below
    # lowercases, so a path segment must already be lowercase to be reachable.
    SEGMENT = /\A[a-z0-9][a-z0-9._-]*\z/
    VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # GCP resource ids are 63 chars, must start with a letter, and allow only
    # lowercase alphanumerics and dashes.
    MAX_ID_LENGTH = 63

    module_function

    # The canonical namespace: the one Zimmer writes, and the one a human is told
    # to put a secret in.
    # @return [String] e.g. "/zimmer/production/secrets/static/"
    def static_namespace(env = Rails.env)
      "/zimmer/#{env}/#{SCOPE}/#{KIND}/"
    end

    # The namespace these secrets occupied before the scope segment was renamed.
    # Still read (see {.read_namespaces}); never written.
    # @return [String] e.g. "/zimmer/production/mcp/static/"
    def legacy_static_namespace(env = Rails.env)
      "/zimmer/#{env}/#{LEGACY_SCOPE}/#{KIND}/"
    end

    # Every namespace the resolver consults, in PRECEDENCE ORDER: the canonical
    # one first, so a value written to the new path wins over a stale copy left
    # at the old one, and migrating a secret is a change that takes effect the
    # moment it lands rather than one that waits for a delete.
    #
    # @return [Array<String>]
    def read_namespaces(env = Rails.env)
      [ static_namespace(env), legacy_static_namespace(env) ]
    end

    # The full canonical path of one variable.
    # @return [String] e.g. "/zimmer/production/secrets/static/STRAD_API_KEY"
    def parameter_path(variable, env = Rails.env)
      "#{static_namespace(env)}#{variable}"
    end

    # Where one variable sat before the rename.
    # @return [String] e.g. "/zimmer/production/mcp/static/STRAD_API_KEY"
    def legacy_parameter_path(variable, env = Rails.env)
      "#{legacy_static_namespace(env)}#{variable}"
    end

    # The trailing {VARIABLE_NAME} of a canonical path.
    # @return [String]
    def variable_of(path)
      path.to_s.split("/").last.to_s
    end

    # Fold a canonical path into the flat GCP resource id that holds it. The same
    # id names both the Parameter Manager parameter and, for a secret, the Secret
    # Manager secret it points at.
    #
    # This fold is LOSSY — `/a/B_c` and `/a/b-c` collapse together — which is why
    # every read compares the envelope's own `path` field against the path that
    # was asked for (see GcpClient#resolve). Do not treat a resolving id as proof
    # you found the right parameter.
    #
    # @param path [String]
    # @return [String]
    def parameter_id(path)
      id = path.to_s
        .sub(%r{\A/+}, "")
        .downcase
        .gsub(/[^a-z0-9]+/, "-")
        .gsub(/\A-+|-+\z/, "")
      id = "p-#{id}" unless id.start_with?(/[a-z]/)

      return id if id.length <= MAX_ID_LENGTH

      # Truncate and re-hash the FULL path, so two long paths sharing a prefix
      # still get different ids.
      digest = Digest::SHA256.hexdigest(path.to_s)[0, 8]
      "#{id[0, 54].sub(/-+\z/, '')}-#{digest}"
    end

    # @return [Boolean] true when `variable` is a legal environment variable name.
    def valid_variable_name?(variable)
      variable.to_s.match?(VARIABLE_NAME) && variable.to_s.length <= 200
    end

    # @return [Boolean] true when `namespace` is a well-shaped absolute prefix.
    #   A bare "/" is refused: it would cover every parameter in the project.
    def valid_namespace?(namespace)
      value = namespace.to_s
      return false unless value.start_with?("/")
      return false if value.length > 200

      segments = value.split("/").reject(&:empty?)
      segments.any? && segments.all? { |segment| segment.match?(SEGMENT) }
    end
  end
end
