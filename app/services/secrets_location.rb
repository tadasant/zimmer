# frozen_string_literal: true

# The single source of truth for *where* an MCP server's `${VAR}` secret has to
# be set, and the exact commands that put it there.
#
# There are two answers, and which one is right depends on the deployment:
#
#   * **Google Parameter Store**, when a resolver credential is configured. This
#     is the durable home: it survives a redeploy, needs no re-encrypted file in
#     git, and is the first link in SecretProviders' chain.
#   * **Rails encrypted credentials** (`mcp_secrets`), otherwise — and always as
#     the place a not-yet-migrated secret still lives.
#
# Every "go set it here" string in the app comes from here, so a change of store
# is a change to one file. Nothing in this class ever reads a secret value; it
# renders addresses, commands, and a `<the-secret-value>` placeholder.
class SecretsLocation
  PLACEHOLDER = "<the-secret-value>"

  class << self
    # Everything the UI needs to tell a user how to set one variable.
    #
    # @param variable_name [String]
    # @param chain [SecretProviders::Chain] injectable for tests
    # @return [Hash]
    def instructions(variable_name, chain: SecretProviders.chain)
      store = parameter_store_provider(chain)

      store ? parameter_store_instructions(variable_name, store) : credentials_instructions(variable_name)
    end

    # --- Rails encrypted credentials -----------------------------------------

    def credentials_store_name
      "Zimmer's Rails encrypted credentials"
    end

    # Repo-relative path of the encrypted file that holds `mcp_secrets`.
    def credentials_path(env = Rails.env)
      "config/credentials/#{env}.yml.enc"
    end

    # The exact command that opens that file for editing, run from the repo root.
    def edit_command(env = Rails.env)
      "bin/rails credentials:edit -e #{env}"
    end

    # The YAML to add under `mcp_secrets:`. A placeholder, never a real value.
    def yaml_snippet(variable_name)
      <<~YAML.strip
        mcp_secrets:
          - name: #{variable_name}
            value: #{PLACEHOLDER}
            description: Used by Zimmer's MCP catalog
      YAML
    end

    def credentials_followup
      "Commit the re-encrypted file and deploy — the credentials file ships inside the image. " \
      "Exporting the variable into the server's environment also works, but is not durable across a redeploy."
    end

    # --- Google Parameter Store ----------------------------------------------

    def parameter_store_name
      "Zimmer's Google Parameter Store"
    end

    # The envelope Zimmer's resolver expects: a JSON payload carrying the
    # canonical path, the secret flag, and a Secret Manager pointer as its value.
    # The path field is what guards against `Namespace.parameter_id`'s lossy fold,
    # so it has to be exactly right — which is why this is generated, not typed.
    def envelope_json(variable_name, project_id, env: Rails.env)
      path = ParameterStore::Namespace.parameter_path(variable_name, env)
      secret_id = ParameterStore::Namespace.parameter_id(path)

      JSON.generate({
        path: path,
        secret: true,
        value: "__REF__(\"//secretmanager.googleapis.com/projects/#{project_id}/secrets/#{secret_id}/versions/latest\")"
      })
    end

    # The three commands that put one secret in the store: the value into Secret
    # Manager, the parameter that indexes it, and the envelope version that
    # points one at the other.
    #
    # Zimmer's own resolver credential cannot run these — it holds no write
    # permission by design — so they are run by a human with the admin identity.
    def gcloud_snippet(variable_name, project_id, location, env: Rails.env)
      path = ParameterStore::Namespace.parameter_path(variable_name, env)
      id = ParameterStore::Namespace.parameter_id(path)

      <<~SHELL.strip
        # 1. The value itself, in Secret Manager.
        printf %s '#{PLACEHOLDER}' | gcloud secrets create #{id} \\
          --project #{project_id} --replication-policy automatic \\
          --labels managed-by=zimmer --data-file=-

        # 2. The parameter that indexes it.
        gcloud parametermanager parameters create #{id} \\
          --project #{project_id} --location #{location} \\
          --parameter-format json --labels managed-by=zimmer,secret=true

        # 3. The envelope version pointing one at the other.
        cat > /tmp/#{id}.json <<'JSON'
        #{envelope_json(variable_name, project_id, env: env)}
        JSON
        gcloud parametermanager parameters versions create v1 \\
          --parameter #{id} --project #{project_id} --location #{location} \\
          --payload-data-from-file /tmp/#{id}.json
        rm -f /tmp/#{id}.json
      SHELL
    end

    private

    def parameter_store_provider(chain)
      chain.providers.find { |provider| provider.is_a?(SecretProviders::ParameterStoreProvider) }
    end

    def parameter_store_instructions(variable_name, store)
      {
        variable: variable_name,
        store_name: parameter_store_name,
        headline: "#{variable_name} is not set. It belongs at #{store.path_for(variable_name)} " \
                  "in Google Cloud project #{store.project_id} (#{store.location}).",
        path: store.path_for(variable_name),
        project_id: store.project_id,
        location: store.location,
        command: "gcloud parametermanager parameters describe " \
                 "#{ParameterStore::Namespace.parameter_id(store.path_for(variable_name))} " \
                 "--project #{store.project_id} --location #{store.location}",
        command_caption: "Check whether it is already there:",
        snippet: gcloud_snippet(variable_name, store.project_id, store.location),
        snippet_caption: "Create it (needs the admin identity — Zimmer's own credential cannot write):",
        followup: "Zimmer picks a new value up within a minute; no redeploy. " \
                  "Until a secret is migrated it can also live under `mcp_secrets:` in " \
                  "#{credentials_path} — the store is consulted first, so whichever holds it wins in that order."
      }
    end

    def credentials_instructions(variable_name)
      {
        variable: variable_name,
        store_name: credentials_store_name,
        headline: "#{variable_name} is not set. Add it to #{credentials_store_name} (#{credentials_path}).",
        path: credentials_path,
        project_id: nil,
        location: nil,
        command: edit_command,
        command_caption: "Open the encrypted file from the repo root:",
        snippet: yaml_snippet(variable_name),
        snippet_caption: "Add, under `mcp_secrets:`:",
        followup: credentials_followup
      }
    end
  end
end
