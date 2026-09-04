# frozen_string_literal: true

module ParameterStore
  # The WRITE half of the store: create, rotate and destroy one Zimmer-managed
  # secret. Kept out of {GcpClient} on purpose — that class is the resolver, and
  # "the resolver cannot write" is a property this codebase would like to be
  # structural rather than a comment. Nothing here is reachable from a
  # SecretProviders chain.
  #
  # ## The four resources, and the one that fails silently
  #
  # A Zimmer secret is a Secret Manager secret holding the bytes, a Parameter
  # Manager parameter of the same id whose JSON payload is an ENVELOPE pointing
  # at it, and — the part that is easy to miss — an IAM binding letting the
  # parameter read that secret. `:render` dereferences the `__REF__` as the
  # PARAMETER's own principal, not as the caller's, so without
  # `roles/secretmanager.secretAccessor` on the secret every read 400s with
  # SECRET_REFERENCE_ERROR while the store banner stays green. That is why
  # {#upsert} grants the binding itself instead of leaving it to whoever clicked
  # Save; the sequence mirrors the four commands in
  # docs/operate/secrets-parameter-store, "Adding a secret".
  #
  # ## Rotation writes one resource, not four
  #
  # The envelope points at `versions/latest`, so changing a value is a single
  # Secret Manager version. The create calls below tolerate 409 ALREADY_EXISTS
  # for exactly that reason: {#upsert} is one code path whether the variable is
  # new or being rotated.
  #
  # ## No value is ever logged
  #
  # Same rule as the resolver: request bodies carry the secret, and Google's
  # error bodies on these verbs can quote the payload, so neither is ever
  # interpolated into a message. Failures name the verb and the status.
  class WriteClient
    PM_API_BASE = GcpClient::PM_API_BASE
    SM_API_BASE = GcpClient::SM_API_BASE
    CRM_API_BASE = GcpClient::CRM_API_BASE

    # Only parameters and secrets carrying this label are Zimmer's. {#delete}
    # refuses to touch a resource without it, so a mis-folded id can never
    # destroy a parameter some other system owns in the same project.
    MANAGED_BY = GcpClient::MANAGED_BY

    ACCESSOR_ROLE = "roles/secretmanager.secretAccessor"

    attr_reader :project_id, :location

    def initialize(project_id:, account:, location: "global",
      pm_api_base: PM_API_BASE, sm_api_base: SM_API_BASE, crm_api_base: CRM_API_BASE,
      transport: HttpTransport.new)
      @project_id = project_id
      @location = location.presence || "global"
      @account = account
      @pm_api_base = pm_api_base.presence || PM_API_BASE
      @sm_api_base = sm_api_base.presence || SM_API_BASE
      @crm_api_base = crm_api_base.presence || CRM_API_BASE
      @transport = transport
    end

    # Which of `permissions` THIS credential holds — the writer's, which is a
    # different principal from the resolver's and must be asked about
    # separately. Same verb and same reasoning as GcpClient#held_permissions;
    # {Capabilities.probe} takes either client.
    #
    # @param permissions [Array<String>]
    # @return [Array<String>]
    # @raise [StoreError, AuthError]
    def held_permissions(permissions)
      body = call("POST",
        "#{@crm_api_base}/v1/projects/#{ERB::Util.url_encode(project_id)}:testIamPermissions",
        { permissions: permissions })
      Array(body["permissions"])
    end

    # Create or rotate `variable`.
    #
    # @param variable [String] an environment-variable name, e.g. OPENROUTER_API_KEY
    # @param value [String] the secret bytes
    # @param env [String] the Rails environment whose namespace to write into
    # @return [String] the GCP resource id both resources share
    # @raise [StoreError, AuthError]
    def upsert(variable, value, env: Rails.env)
      path = Namespace.parameter_path(variable, env)
      id = Namespace.parameter_id(path)

      create_secret(id)
      add_secret_version(id, value)

      principal = create_parameter(id)
      # No principal means no binding, and an envelope written without the
      # binding is worse than no envelope at all: `:render` 400s on it forever,
      # and GcpClient#rendered_envelope re-raises anything that is not a 404 —
      # so ONE such parameter fails the resolve of the WHOLE project, taking
      # every other `${VAR}` down with it. Refuse before writing it.
      if principal.blank?
        raise StoreError.new(
          "refusing to write #{id}: Parameter Manager returned no policyMember for it, so the " \
          "parameter could not be granted access to its own secret and every :render would fail", 409
        )
      end

      grant_accessor(id, principal)

      write_envelope(id, path) if parameter_version_ids(id).empty?

      id
    end

    # Destroy both resources behind `variable`. Versions first: Parameter
    # Manager refuses to delete a parameter that still has any.
    #
    # A 404 anywhere is success, not failure — the caller asked for the value to
    # be gone, and a half-created pair is exactly the state Delete exists to
    # clean up.
    #
    # @param path [String, nil] the path whose fold names the pair to remove.
    #   Defaults to the variable's canonical path; {NamespaceMigration} passes
    #   the pre-rename one, which folds to a different id, to delete the copy it
    #   has just verified out of.
    # @return [String] the resource id that was removed
    # @raise [StoreError, AuthError]
    def delete(variable, env: Rails.env, path: nil)
      # `path:` decides the id on its own, so `variable` would otherwise be
      # decorative and `delete("A", path: path_of("B"))` would remove B. The
      # label fence below cannot catch that — every Zimmer pair carries the same
      # label — so the two have to be checked against each other here.
      if path.present? && Namespace.variable_of(path) != variable
        raise ArgumentError, "path #{path} does not name #{variable}"
      end

      id = Namespace.parameter_id(path.presence || Namespace.parameter_path(variable, env))
      refuse_unmanaged!(id)

      parameter_version_ids(id).each do |version|
        call("DELETE", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}/versions/#{version}", nil, allow: [ 404 ])
      end
      call("DELETE", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}", nil, allow: [ 404 ])
      call("DELETE", "#{@sm_api_base}/v1/#{sm_parent}/secrets/#{id}", nil, allow: [ 404 ])

      id
    end

    private

    # `Namespace.parameter_id` is a LOSSY fold — two different paths can collapse
    # onto one id — so a resolving id is not proof the resource is ours. Every
    # read applies the envelope-path fence for that reason (GcpClient#resolve);
    # a delete cannot, because the writer holds no `:render`. The label is the
    # fence it can apply, and it is the same one GcpClient#managed_parameter_ids
    # uses to decide what counts as Zimmer's.
    #
    # Anything present and unlabelled belongs to something else in this project
    # and is left alone, loudly. Anything absent is fine: a delete of a
    # half-created pair is exactly what this method exists to allow.
    def refuse_unmanaged!(id)
      [
        [ "parameter", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}" ],
        [ "secret", "#{@sm_api_base}/v1/#{sm_parent}/secrets/#{id}" ]
      ].each do |kind, url|
        body = call("GET", url, nil, allow: [ 404 ])
        next if body.empty?
        next if body.dig("labels", "managed-by") == MANAGED_BY

        raise StoreError.new(
          "refusing to delete #{kind} #{id}: it is not labelled managed-by=#{MANAGED_BY}", 409
        )
      end
    end

    def pm_parent = "projects/#{project_id}/locations/#{location}"
    def sm_parent = "projects/#{project_id}"

    # 409 means it is already there, which is the rotate case.
    def create_secret(id)
      call("POST", "#{@sm_api_base}/v1/#{sm_parent}/secrets?secretId=#{ERB::Util.url_encode(id)}",
        { replication: { automatic: {} }, labels: { "managed-by" => MANAGED_BY } },
        allow: [ 409 ])
    end

    def add_secret_version(id, value)
      call("POST", "#{@sm_api_base}/v1/#{sm_parent}/secrets/#{id}:addVersion",
        { payload: { data: Base64.strict_encode64(value) } })
    end

    # @return [String, nil] the parameter's own principal, which is what the IAM
    #   binding below is granted to. Read from the create response, or from a GET
    #   when the parameter was already there.
    def create_parameter(id)
      body = call("POST", "#{@pm_api_base}/v1/#{pm_parent}/parameters?parameterId=#{ERB::Util.url_encode(id)}",
        { format: "JSON", labels: { "managed-by" => MANAGED_BY } }, allow: [ 409 ])

      principal = body.dig("policyMember", "iamPolicyUidPrincipal")
      return principal if principal.present?

      call("GET", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}", nil)
        .dig("policyMember", "iamPolicyUidPrincipal")
    end

    # Merge, never replace: the secret's policy may carry bindings this code did
    # not put there, and a blind setIamPolicy would drop them.
    def grant_accessor(id, principal)
      # GET, not POST: Secret Manager v1 defines `:getIamPolicy` as a GET and only
      # `:setIamPolicy` as a POST.
      policy = call("GET", "#{@sm_api_base}/v1/#{sm_parent}/secrets/#{id}:getIamPolicy", nil)
      bindings = Array(policy["bindings"]).map { |binding| binding.dup }

      accessor = bindings.find { |binding| binding["role"] == ACCESSOR_ROLE }
      if accessor
        return if Array(accessor["members"]).include?(principal)

        accessor["members"] = Array(accessor["members"]) + [ principal ]
      else
        bindings << { "role" => ACCESSOR_ROLE, "members" => [ principal ] }
      end

      call("POST", "#{@sm_api_base}/v1/#{sm_parent}/secrets/#{id}:setIamPolicy",
        { policy: policy.merge("bindings" => bindings) })
    end

    def write_envelope(id, path)
      envelope = JSON.generate({
        path: path,
        secret: true,
        value: "__REF__(\"//secretmanager.googleapis.com/projects/#{project_id}/secrets/#{id}/versions/latest\")"
      })

      call("POST", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}/versions?parameterVersionId=v1",
        { payload: { data: Base64.strict_encode64(envelope) } })
    end

    # Paged, because a partial answer here is not a smaller delete — it is a
    # parameter left with versions, which Parameter Manager then refuses to
    # delete at all.
    def parameter_version_ids(id)
      ids = []
      page_token = nil

      loop do
        query = { pageSize: 100 }
        query[:pageToken] = page_token if page_token
        body = call("GET", "#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}/versions?#{query.to_query}",
          nil, allow: [ 404 ])

        ids.concat(Array(body["parameterVersions"])
          .filter_map { |version| version["name"].to_s.split("/").last.presence })

        page_token = body["nextPageToken"].presence
        break if page_token.nil?
      end

      ids
    end

    # @param allow [Array<Integer>] statuses treated as success, returning {}.
    def call(method, url, body, allow: [])
      status, response_body = @transport.request(method, url, {
        "authorization" => "Bearer #{@account.access_token}",
        "content-type" => "application/json"
      }, body.nil? ? nil : JSON.generate(body))

      return {} if allow.include?(status)

      unless (200..299).cover?(status)
        # The path names a resource. The BODY is deliberately not included: on
        # these verbs Google's error body can quote the payload we just sent.
        raise StoreError.new("#{method} #{sanitize(url)} failed: #{status}", status)
      end

      return {} if response_body.blank?

      JSON.parse(response_body)
    rescue JSON::ParserError
      raise StoreError.new("#{method} #{sanitize(url)} returned a body that is not JSON", 502)
    end

    def sanitize(url)
      URI(url).path
    rescue URI::InvalidURIError
      "(unparseable url)"
    end
  end
end
