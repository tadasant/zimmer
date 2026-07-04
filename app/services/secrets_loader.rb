# frozen_string_literal: true

# Service class for loading secrets from Rails encrypted credentials
# Reads from config/credentials/{environment}.yml.enc (e.g., development.yml.enc, production.yml.enc)
# Makes secrets available for use in MCP server configuration
#
# To edit secrets for an environment:
#   EDITOR="code --wait" bin/rails credentials:edit -e development
#   EDITOR="code --wait" bin/rails credentials:edit -e production
#
# Expected format in credentials file:
#   mcp_secrets:
#     - name: API_KEY
#       value: your_api_key_here
#       description: Optional description
class SecretsLoader
  class SecretNotFoundError < StandardError; end

  # Secret model to represent individual secrets
  class Secret
    attr_reader :name, :value, :description

    def initialize(name:, value:, description: nil)
      @name = name
      @value = value
      @description = description
    end

    def to_h
      {
        name: @name,
        value: @value,
        description: @description
      }
    end
  end

  class << self
    # Load all secrets from Rails credentials
    #
    # NOTE: This method intentionally does NOT memoize. Encrypted credentials
    # can change during deploys, and class-level memoization (`@all ||=`)
    # causes stale secrets to persist for the lifetime of the process.
    # The cost of re-reading credentials on each call is negligible.
    #
    # @return [Hash] hash of secret key-value pairs
    def all
      load_secrets
    end

    # Get all secrets with full metadata (name, value, description)
    # @return [Array<Secret>] array of Secret objects
    def all_with_metadata
      load_secrets_with_metadata
    end

    # Get a specific secret by key
    # @param key [String] the secret key
    # @return [String, nil] the secret value or nil if not found
    def get(key)
      all[key]
    end

    # Get a specific secret by key, raise error if not found
    # @param key [String] the secret key
    # @return [String] the secret value
    # @raise [SecretNotFoundError] if secret is not found
    def get!(key)
      get(key) || raise(SecretNotFoundError,
        "Secret '#{key}' not found. Check config/credentials/#{Rails.env}.yml.enc. " \
        "Use 'EDITOR=\"code --wait\" bin/rails credentials:edit -e #{Rails.env}' to add it.")
    end

    # Get a specific secret with metadata
    # @param key [String] the secret key
    # @return [Secret, nil] the Secret object or nil if not found
    def get_with_metadata(key)
      all_with_metadata.find { |s| s.name == key }
    end

    # Check if a secret exists
    # @param key [String] the secret key
    # @return [Boolean] true if secret exists
    def exists?(key)
      all.key?(key)
    end

    # Get all secret keys
    # @return [Array<String>] list of secret keys
    def keys
      all.keys
    end

    # Check if credentials are available with mcp_secrets
    # @return [Boolean] true if credentials are available
    def available?
      credentials_available?
    end

    # Get templated representation of a secret ({{KEY}})
    # @param key [String] the secret key
    # @return [String] templated secret reference
    def template(key)
      "{{#{key}}}"
    end

    # Get all secrets as templated references
    # @return [Hash] hash with keys and templated values
    def all_templated
      all.keys.to_h { |k| [ k, template(k) ] }
    end

    private

    # Check if Rails credentials have mcp_secrets configured
    # @return [Boolean] true if credentials are available and have mcp_secrets
    def credentials_available?
      mcp_secrets = Rails.application.credentials.mcp_secrets
      mcp_secrets.present?
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, NoMethodError
      false
    end

    # Load secrets from Rails credentials
    def load_secrets
      return {} unless credentials_available?

      secrets = {}
      mcp_secrets = Rails.application.credentials.mcp_secrets || []

      mcp_secrets.each do |secret_config|
        # Handle both symbol and string keys
        name = secret_config[:name] || secret_config["name"]
        value = secret_config[:value] || secret_config["value"]
        secrets[name] = value if name.present? && value.present?
      end

      secrets
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      {}
    end

    # Load secrets with full metadata from Rails credentials
    def load_secrets_with_metadata
      return [] unless credentials_available?

      mcp_secrets = Rails.application.credentials.mcp_secrets || []

      mcp_secrets.filter_map do |secret_config|
        # Handle both symbol and string keys
        name = secret_config[:name] || secret_config["name"]
        value = secret_config[:value] || secret_config["value"]
        description = secret_config[:description] || secret_config["description"]

        next unless name.present? && value.present?

        Secret.new(
          name: name,
          value: value,
          description: description
        )
      end
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      []
    end
  end
end
