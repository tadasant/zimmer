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

  # The Secrets Console: the human UI over a Google Parameter Manager project,
  # with a reveal/rotate flow behind Workspace SSO. Far better to point someone
  # at than a page of `gcloud`.
  #
  # It is stored NEXT TO the project it administers, and that pairing is the
  # whole point. **One console administers exactly one GCP project.** The console
  # below is strad's, over `strad-secrets-prod`; Zimmer's own store is
  # deliberately a *different* project (see docs/operate/secrets-parameter-store,
  # "Why a separate GCP project" — Zimmer's resolver must read secret *values*,
  # which is precisely the permission strad's viewer identity is defined by not
  # holding). So the console is the right destination only when the store Zimmer
  # actually resolves from IS the project this console administers.
  #
  # Getting that wrong is not a cosmetic error. A value typed into a console for
  # another project is accepted, saved, and never read by Zimmer — the variable
  # goes on reporting Missing configuration with no indication of why. That is
  # the failure this pairing exists to make impossible to render.
  #
  # The whole triple is overridable so that the day a Zimmer-scoped console ships
  # (strad can front a second store with a second bundle — strad/MULTI_STORE.md),
  # pointing at it is configuration rather than a deploy of new copy. It is
  # resolved as ONE unit, in {.console}: a half-override — the project set and
  # the URL not — would otherwise render the green "set it here" box pointing at
  # a console that administers something else, which is the exact failure this
  # pairing exists to prevent. An incomplete override is ignored, so the failure
  # mode of a misconfiguration is "no console claimed", never a wrong one.
  CONSOLE_URL = "https://strad.tadasant.com/ui/secrets"
  CONSOLE_PROJECT_ID = "strad-secrets-prod"
  CONSOLE_LOCATION = "global"

  ENV_CONSOLE_URL = "ZIMMER_SECRETS_CONSOLE_URL"
  ENV_CONSOLE_PROJECT_ID = "ZIMMER_SECRETS_CONSOLE_PROJECT_ID"
  ENV_CONSOLE_LOCATION = "ZIMMER_SECRETS_CONSOLE_LOCATION"

  # The gateway whose upstream credentials the console holds, and the namespace
  # it holds them under. Separate from the console's own URL on purpose: a
  # Zimmer-scoped console would change {.console_url} while these stay put, and
  # deriving one from the other would make the gateway note silently disappear
  # from the rows that still have a second credential.
  GATEWAY_HOST = "strad.tadasant.com"
  GATEWAY_NAMESPACE = "/strad/prod/mcp"

  class << self
    # --- The Secrets Console -------------------------------------------------

    # The console's address and the one project (in one location) it administers,
    # resolved together. See CONSOLE_URL's comment for why "together" is the
    # whole point.
    #
    # @return [Hash]
    def console
      overrides = [ ENV_CONSOLE_URL, ENV_CONSOLE_PROJECT_ID, ENV_CONSOLE_LOCATION ].map { |key| env_value(key) }

      return { url: CONSOLE_URL, project_id: CONSOLE_PROJECT_ID, location: CONSOLE_LOCATION } if overrides.any?(&:nil?)

      { url: overrides[0], project_id: overrides[1], location: overrides[2] }
    end

    # @return [String]
    def console_url = console[:url]

    # @return [String] the one GCP project {.console_url} administers.
    def console_project_id = console[:project_id]

    # @return [String] host of the gateway whose upstream credentials the console
    #   holds. Not derived from {.console_url} — see GATEWAY_HOST.
    def gateway_host = GATEWAY_HOST

    # @return [String] the console path prefix a gateway server's own credentials
    #   sit under, for `<slug>`.
    def gateway_namespace(slug) = "#{GATEWAY_NAMESPACE}/#{slug}/static/"

    # Does the console administer the store this variable resolves from?
    #
    # Location is compared as well as project: a parameter is addressed by both,
    # so a console pointed at the right project in the wrong location would send
    # someone to create a parameter Zimmer never reads — the same silent failure
    # as the wrong project, one field further down.
    #
    # @param store [SecretProviders::ParameterStoreProvider, nil] nil when no
    #   Parameter Store is configured, in which case the answer is no: the
    #   console does not hold Zimmer's encrypted credentials either.
    # @return [Boolean]
    def console_administers?(store)
      return false if store.nil?

      store.project_id.to_s == console[:project_id] && store.location.to_s == console[:location]
    end

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

    # What a human does in the Secrets Console to create one parameter. Only
    # correct when the console administers the store Zimmer resolves from — see
    # {.console_administers?}.
    #
    # @return [Array<String>]
    def console_steps(path)
      [
        "Sign in to the Secrets Console with the Workspace account that holds the admin identity.",
        "Create a managed parameter at exactly #{path}. The path is the lookup key — Zimmer compares " \
        "it against the one it asked for and ignores a parameter whose path does not match, so a " \
        "missing segment reads as \"still not set\" rather than as a typo.",
        "Mark it secret, so the bytes land in Secret Manager and the parameter only points at them.",
        "Paste the value and save. The console writes the envelope and the IAM binding that lets the " \
        "parameter dereference its own secret."
      ]
    end

    # What a human does when the console administers a DIFFERENT project than the
    # one Zimmer resolves from — which is the case today, and is by design.
    #
    # The third step is the one that is easy to leave out and impossible to debug
    # from the outside: Parameter Manager's `:render` dereferences the `__REF__`
    # as the PARAMETER's own principal, not as the caller's credential. That
    # principal needs `secretmanager.secretAccessor` ON THE SECRET, and without it
    # every resolution of this variable fails with a 400 SECRET_REFERENCE_ERROR —
    # while the Connectors store banner still reports a healthy credential,
    # because that banner reflects a testIamPermissions probe of the RESOLVER,
    # which is a different principal entirely.
    #
    # @return [Array<String>]
    def admin_steps(store)
      [
        "The Secrets Console administers #{console_project_id}. This variable resolves from " \
        "#{store.project_id} — a separate Google Cloud project, deliberately, because Zimmer's " \
        "resolver reads secret values and that console's identity is defined by not doing so. " \
        "A value saved in the console will be accepted and will never reach this variable.",
        "So this one is created with the admin identity on #{store.project_id}: a Secret Manager " \
        "secret holding the value, a Parameter Manager parameter of the same id, an IAM binding " \
        "letting that parameter read that secret, and the envelope version below joining them.",
        "The IAM binding is the step that fails silently if skipped: :render dereferences the " \
        "__REF__ as the parameter's own principal, not as Zimmer's, so the parameter itself needs " \
        "roles/secretmanager.secretAccessor on the secret. Without it every read 400s while the " \
        "store banner above stays green.",
        "docs/operate/secrets-parameter-store has the four commands in full."
      ]
    end

    private

    # ENV values are bytes TAGGED UTF-8 and nothing guarantees they are — a
    # truncated paste is tagged identically — and `presence` goes through
    # `blank?`, which RAISES on those bytes. Without this guard a mangled console
    # override would take down the render of every connector row rather than
    # leaving the default console in place. Same hazard, same treatment, as
    # ParameterStore::Resolver.from_env.
    def env_value(key)
      value = ENV[key]
      return nil unless value.is_a?(String) && value.valid_encoding?

      value.presence
    end

    def parameter_store_provider(chain)
      chain.providers.find { |provider| provider.is_a?(SecretProviders::ParameterStoreProvider) }
    end

    def parameter_store_instructions(variable_name, store)
      path = store.path_for(variable_name)
      administered = console_administers?(store)

      {
        variable: variable_name,
        store_name: parameter_store_name,
        headline: "#{variable_name} is not set. It belongs at #{path} " \
                  "in Google Cloud project #{store.project_id} (#{store.location}).",
        path: path,
        project_id: store.project_id,
        location: store.location,
        console_url: console_url,
        console_administers: administered,
        console_caption: administered ?
          "Set it in the Secrets Console — it administers #{store.project_id}:" :
          "The Secrets Console does not administer this variable's project:",
        steps: administered ? console_steps(path) : admin_steps(store),
        snippet: administered ? nil : envelope_json(variable_name, store.project_id),
        snippet_caption: administered ? nil :
          "The envelope the parameter version carries — generated, because the path field has to be " \
          "exactly this and the id below it is a lossy fold of that path:",
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
        console_url: console_url,
        # No Parameter Store is configured, so nothing on this page resolves from
        # a console-administered project. Saying so is the point: the console is
        # the obvious place to go looking, and it holds none of this.
        console_administers: false,
        console_caption: "The Secrets Console holds none of Zimmer's variables right now:",
        steps: [
          "Zimmer has no Parameter Store resolver configured, so every ${VAR} on this page comes from " \
          "the encrypted credentials file below and then from the process environment. The Secrets " \
          "Console administers #{console_project_id}, which Zimmer is not reading — a value set there " \
          "will not reach this variable.",
          "Open the encrypted file with the command below and add the entry under `mcp_secrets:`.",
          "Wire the store up (docs/operate/secrets-parameter-store) and this variable moves to a " \
          "console-shaped flow; until then the encrypted file is the supported home, not a workaround."
        ],
        command: edit_command,
        command_caption: "Open the encrypted file from the repo root:",
        snippet: yaml_snippet(variable_name),
        snippet_caption: "Add, under `mcp_secrets:`:",
        followup: credentials_followup
      }
    end
  end
end
