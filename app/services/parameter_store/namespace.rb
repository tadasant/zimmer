# frozen_string_literal: true

module ParameterStore
  # Canonical parameter paths, and the lossy fold from a path to a GCP resource id.
  #
  # A Zimmer secret lives at:
  #
  #     /zimmer/{env}/mcp/static/{VARIABLE_NAME}
  #
  # The `static` segment is a *kind*. It is here from day one so a future kind
  # (`oauth`, say) is a new prefix rather than a migration of every existing path.
  #
  # Zimmer's namespace is flat — one bucket of `${VAR}` names — because its
  # `${VAR}` references are global to the catalog rather than scoped per server:
  # two catalog entries that both say `${STRAD_API_KEY}` mean the same key.
  module Namespace
    # Zimmer's `${VAR}` names are environment-variable names, and the fold below
    # lowercases, so a path segment must already be lowercase to be reachable.
    SEGMENT = /\A[a-z0-9][a-z0-9._-]*\z/
    VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # GCP resource ids are 63 chars, must start with a letter, and allow only
    # lowercase alphanumerics and dashes.
    MAX_ID_LENGTH = 63

    module_function

    # The namespace Zimmer's resolver reads, for one Rails environment.
    # @return [String] e.g. "/zimmer/production/mcp/static/"
    def static_namespace(env = Rails.env)
      "/zimmer/#{env}/mcp/static/"
    end

    # The full canonical path of one variable.
    # @return [String] e.g. "/zimmer/production/mcp/static/STRAD_API_KEY"
    def parameter_path(variable, env = Rails.env)
      "#{static_namespace(env)}#{variable}"
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
