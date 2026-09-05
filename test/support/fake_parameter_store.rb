# frozen_string_literal: true

# An in-memory Parameter Manager + Secret Manager, behind the HTTP seam.
#
# This is deliberately a fake TRANSPORT rather than a fake client: the code under
# test is the production ParameterStore::GcpClient, and only the network is
# substituted. A fake client would let the envelope decoding, the `:render`
# join, the namespace fence and the pagination all rot untested.
#
# The single most valuable assertion it enables is the canary: a secret value
# must live in the Secret Manager half and appear in NO Parameter Manager
# payload. `parameter_payloads` exists for exactly that check.
class FakeParameterStore
  PROJECT = "zimmer-secrets-test"
  LOCATION = "global"
  PM_BASE = "https://pm.test"
  SM_BASE = "https://sm.test"

  REF = %r{\A__REF__\("//secretmanager\.googleapis\.com/projects/([^/]+)/secrets/([^/]+)/versions/([^"]+)"\)\z}

  Parameter = Struct.new(:labels, :versions, keyword_init: true)

  # What Parameter Manager calls `policyMember.iamPolicyUidPrincipal`: the
  # parameter's OWN principal, which is what `:render` dereferences a `__REF__`
  # as. Modelled rather than hand-waved because the binding that grants it
  # access to the secret is the step whose absence fails silently in production
  # — see ParameterStore::WriteClient.
  def self.principal_for(id) = "principal://parametermanager.googleapis.com/parameter/#{id}"

  attr_reader :parameters, :secrets, :requests, :secret_policies, :secret_labels

  def initialize(project_id: PROJECT, location: LOCATION)
    @project_id = project_id
    @location = location
    @parameters = {}
    @secrets = {}
    # secret id => the members holding roles/secretmanager.secretAccessor on it.
    @secret_policies = Hash.new { |h, k| h[k] = [] }
    # secret id => its GCP labels. The delete guard reads managed-by off these.
    @secret_labels = {}
    @requests = []
    @held_permissions = []
    @failure = nil
  end

  # --- seeding ---------------------------------------------------------------

  # Store a secret the way the console does: bytes in Secret Manager, a pointer
  # in the Parameter Manager envelope. `path:` overrides the canonical path,
  # which is how a test seeds the PRE-RENAME namespace.
  # @param encoding [String, nil] what the envelope DECLARES about the Secret
  #   Manager bytes. nil — the field is absent — means the literal bytes, which
  #   is what every value seeded before the encoding existed carries.
  def seed_secret(variable, value, env: Rails.env, path: nil, encoding: nil)
    path ||= ParameterStore::Namespace.parameter_path(variable, env)
    id = ParameterStore::Namespace.parameter_id(path)

    @secrets[id] = [ value ]
    @secret_labels[id] = { "managed-by" => ParameterStore::GcpClient::MANAGED_BY }
    @secret_policies[id] = [ self.class.principal_for(id) ]
    envelope = {
      "path" => path, "secret" => true,
      "value" => %(__REF__("//secretmanager.googleapis.com/projects/#{@project_id}/secrets/#{id}/versions/latest"))
    }
    envelope["encoding"] = encoding unless encoding.nil?
    put_parameter(id, { secret: "true" }, envelope)
    path
  end

  # A secret written the way strad's Secrets Console writes one: the Secret
  # Manager bytes are base64url TEXT of the real value, and the envelope declares
  # it. Every secret that console has written since it started encoding is this
  # shape — see `servers/secrets/shared/src/parameter-wire.ts` in tadasant/strad.
  def seed_console_secret(variable, value, env: Rails.env, path: nil)
    seed_secret(variable, Base64.urlsafe_encode64(value.to_s, padding: false),
      env: env, path: path, encoding: ParameterStore::GcpClient::VALUE_ENCODING)
  end

  # A non-secret parameter: the value sits in the envelope itself.
  def seed_plain(variable, value, env: Rails.env, path: nil)
    path ||= ParameterStore::Namespace.parameter_path(variable, env)
    id = ParameterStore::Namespace.parameter_id(path)
    put_parameter(id, { secret: "false" }, { "path" => path, "secret" => false, "value" => value })
    path
  end

  # A parameter in the project that Zimmer did not write.
  def seed_unmanaged(id, envelope)
    put_parameter(id, {}, envelope, managed: false)
  end

  def held_permissions=(permissions)
    @held_permissions = permissions
  end

  # Make every subsequent call fail with this HTTP status.
  def fail_with!(status)
    @failure = status
  end

  def recover!
    @failure = nil
  end

  # Every base64 payload ever written to Parameter Manager, decoded. A secret
  # value appearing here would mean the pointer indirection had been lost.
  def parameter_payloads
    @parameters.values.flat_map { |parameter| parameter.versions.map { |v| v[:data] } }
  end

  # --- the transport ---------------------------------------------------------

  def client(account: stub_account)
    ParameterStore::GcpClient.new(project_id: @project_id, account: account, location: @location,
      pm_api_base: PM_BASE, sm_api_base: SM_BASE, transport: self)
  end

  def provider(namespaces: ParameterStore::Namespace.read_namespaces)
    SecretProviders::ParameterStoreProvider.new(client, namespaces: Array(namespaces))
  end

  # The WRITE half, pointed at the same in-memory store the resolver reads, so a
  # test can write through the production client and read back through the
  # production chain.
  def write_client(account: stub_account)
    ParameterStore::WriteClient.new(project_id: @project_id, account: account, location: @location,
      pm_api_base: PM_BASE, sm_api_base: SM_BASE, transport: self)
  end

  # A whole SecretProviders chain over this store, with no Rails-credentials or
  # ENV link — so "the value resolves" means "it resolves FROM THE STORE".
  def chain(namespaces: ParameterStore::Namespace.read_namespaces)
    SecretProviders::Chain.new([ provider(namespaces: namespaces) ])
  end

  # Break the IAM binding the way a forgotten `add-iam-policy-binding` does:
  # everything is present, everything reports success, and every render 400s.
  def revoke_parameter_binding!(variable, env: Rails.env, path: nil)
    @secret_policies[ParameterStore::Namespace.parameter_id(
      path || ParameterStore::Namespace.parameter_path(variable, env)
    )] = []
  end

  # ParameterStore::HttpTransport's interface.
  def request(method, url, _headers, body)
    @requests << [ method, url ]
    return [ @failure, JSON.generate({ error: { code: @failure } }) ] if @failure

    route(method, url, body)
  end

  private

  def stub_account
    Class.new do
      def access_token(**) = "fake-token"
    end.new
  end

  def put_parameter(id, labels, envelope, managed: true)
    labels = labels.transform_keys(&:to_s)
    labels["managed-by"] = ParameterStore::GcpClient::MANAGED_BY if managed
    parameter = (@parameters[id] ||= Parameter.new(labels: labels, versions: []))
    parameter.labels = labels
    parameter.versions << { id: "v#{parameter.versions.size + 1}", data: JSON.generate(envelope) }
  end

  def route(method, url, body)
    query = url.split("?")[1].to_s
    path = url.split("?").first.sub("#{PM_BASE}/v1/", "").sub("#{SM_BASE}/v1/", "")

    return test_iam_permissions if url.include?("cloudresourcemanager")
    return list_parameters if path.match?(%r{\Aprojects/[^/]+/locations/[^/]+/parameters\z}) && method == "GET"

    if (m = path.match(%r{parameters/([^/]+)/versions\z})) && method == "GET"
      return list_versions(m[1])
    end
    if (m = path.match(%r{parameters/([^/]+)/versions/([^:]+):render\z})) && method == "GET"
      return render_version(m[1], m[2])
    end

    write_route(method, path, query, body) || [ 404, JSON.generate({ error: { code: 404 } }) ]
  end

  # --- the write verbs -------------------------------------------------------

  def write_route(method, path, query, body)
    payload = body.blank? ? {} : JSON.parse(body)

    case [ method, path ]
    in [ "POST", %r{\Aprojects/[^/]+/secrets\z} ]
      create_secret(param(query, "secretId"))
    in [ "POST", %r{\Aprojects/[^/]+/secrets/([^:]+):addVersion\z} => p ]
      add_secret_version(p[%r{secrets/([^:]+):}, 1], payload)
    in [ "GET", %r{\Aprojects/[^/]+/secrets/([^:]+):getIamPolicy\z} => p ]
      [ 200, JSON.generate({ bindings: policy_bindings(p[%r{secrets/([^:]+):}, 1]) }) ]
    in [ "POST", %r{\Aprojects/[^/]+/secrets/([^:]+):setIamPolicy\z} => p ]
      set_iam_policy(p[%r{secrets/([^:]+):}, 1], payload)
    in [ "GET", %r{\Aprojects/[^/]+/secrets/([^/]+)\z} => p ]
      get_secret(p[%r{secrets/([^/]+)\z}, 1])
    in [ "DELETE", %r{\Aprojects/[^/]+/secrets/([^/]+)\z} => p ]
      delete_secret(p[%r{secrets/([^/]+)\z}, 1])
    in [ "POST", %r{\Aprojects/[^/]+/locations/[^/]+/parameters\z} ]
      create_parameter(param(query, "parameterId"))
    in [ "GET", %r{parameters/([^/]+)\z} => p ]
      get_parameter(p[%r{parameters/([^/]+)\z}, 1])
    in [ "POST", %r{parameters/([^/]+)/versions\z} => p ]
      create_parameter_version(p[%r{parameters/([^/]+)/versions\z}, 1], param(query, "parameterVersionId"), payload)
    in [ "DELETE", %r{parameters/([^/]+)/versions/([^/]+)\z} => p ]
      delete_parameter_version(*p.match(%r{parameters/([^/]+)/versions/([^/]+)\z}).captures)
    in [ "DELETE", %r{parameters/([^/]+)\z} => p ]
      delete_parameter(p[%r{parameters/([^/]+)\z}, 1])
    else
      nil
    end
  end

  def param(query, key) = Rack::Utils.parse_nested_query(query)[key]

  def create_secret(id)
    return [ 409, JSON.generate({ error: { code: 409 } }) ] if @secrets.key?(id)

    @secret_labels[id] = { "managed-by" => ParameterStore::GcpClient::MANAGED_BY }
    @secrets[id] = []
    [ 200, JSON.generate({ name: "projects/#{@project_id}/secrets/#{id}" }) ]
  end

  def add_secret_version(id, payload)
    return [ 404, JSON.generate({ error: { code: 404 } }) ] unless @secrets.key?(id)

    @secrets[id] << Base64.decode64(payload.dig("payload", "data").to_s)
    [ 200, JSON.generate({ name: "projects/#{@project_id}/secrets/#{id}/versions/#{@secrets[id].size}" }) ]
  end

  def policy_bindings(id)
    members = @secret_policies[id]
    members.empty? ? [] : [ { "role" => ParameterStore::WriteClient::ACCESSOR_ROLE, "members" => members } ]
  end

  def set_iam_policy(id, payload)
    binding = Array(payload.dig("policy", "bindings"))
      .find { |b| b["role"] == ParameterStore::WriteClient::ACCESSOR_ROLE }
    @secret_policies[id] = Array(binding&.[]("members"))
    [ 200, JSON.generate({ bindings: policy_bindings(id) }) ]
  end

  def get_secret(id)
    return [ 404, JSON.generate({ error: { code: 404 } }) ] unless @secrets.key?(id)

    [ 200, JSON.generate({ "name" => "projects/#{@project_id}/secrets/#{id}",
                           "labels" => @secret_labels[id] || {} }) ]
  end

  def delete_secret(id)
    return [ 404, JSON.generate({ error: { code: 404 } }) ] unless @secrets.key?(id)

    @secrets.delete(id)
    @secret_policies.delete(id)
    @secret_labels.delete(id)
    [ 200, "{}" ]
  end

  def create_parameter(id)
    return [ 409, JSON.generate({ error: { code: 409 } }) ] if @parameters.key?(id)

    @parameters[id] = Parameter.new(
      labels: { "managed-by" => ParameterStore::GcpClient::MANAGED_BY }, versions: []
    )
    [ 200, JSON.generate(parameter_body(id)) ]
  end

  def get_parameter(id)
    return [ 404, JSON.generate({ error: { code: 404 } }) ] unless @parameters.key?(id)

    [ 200, JSON.generate(parameter_body(id)) ]
  end

  def parameter_body(id)
    {
      "name" => "projects/#{@project_id}/locations/#{@location}/parameters/#{id}",
      "labels" => @parameters[id].labels,
      "policyMember" => { "iamPolicyUidPrincipal" => self.class.principal_for(id) }
    }
  end

  def create_parameter_version(id, version_id, payload)
    return [ 404, JSON.generate({ error: { code: 404 } }) ] unless @parameters.key?(id)

    @parameters[id].versions << { id: version_id, data: Base64.decode64(payload.dig("payload", "data").to_s) }
    [ 200, "{}" ]
  end

  def delete_parameter_version(id, version_id)
    parameter = @parameters[id]
    return [ 404, JSON.generate({ error: { code: 404 } }) ] if parameter.nil?

    parameter.versions.reject! { |v| v[:id] == version_id }
    [ 200, "{}" ]
  end

  # Parameter Manager refuses to delete a parameter that still has versions.
  def delete_parameter(id)
    parameter = @parameters[id]
    return [ 404, JSON.generate({ error: { code: 404 } }) ] if parameter.nil?
    return [ 400, JSON.generate({ error: { code: 400 } }) ] if parameter.versions.any?

    @parameters.delete(id)
    [ 200, "{}" ]
  end

  def test_iam_permissions
    [ 200, JSON.generate({ permissions: @held_permissions }) ]
  end

  def list_parameters
    entries = @parameters.map do |id, parameter|
      { "name" => "projects/#{@project_id}/locations/#{@location}/parameters/#{id}", "labels" => parameter.labels }
    end
    [ 200, JSON.generate({ parameters: entries }) ]
  end

  def list_versions(id)
    parameter = @parameters[id]
    return [ 404, JSON.generate({ error: { code: 404 } }) ] if parameter.nil?

    entries = parameter.versions.map do |version|
      { "name" => "projects/#{@project_id}/locations/#{@location}/parameters/#{id}/versions/#{version[:id]}" }
    end
    [ 200, JSON.generate({ parameterVersions: entries }) ]
  end

  # The one place the two stores are joined — exactly as Parameter Manager's own
  # `:render` verb does it.
  def render_version(id, version_id)
    parameter = @parameters[id]
    version = parameter&.versions&.find { |v| v[:id] == version_id }
    return [ 404, JSON.generate({ error: { code: 404 } }) ] if version.nil?

    envelope = JSON.parse(version[:data])
    envelope.each do |key, value|
      next unless value.is_a?(String)

      match = REF.match(value)
      next if match.nil?

      versions = @secrets[match[2]]
      return [ 404, JSON.generate({ error: { code: 404 } }) ] if versions.blank?
      # SECRET_REFERENCE_ERROR: `:render` dereferences as the PARAMETER's own
      # principal, so without the binding the parameter cannot read its own
      # secret — and this 400 is the only outward sign of it.
      unless @secret_policies[match[2]].include?(self.class.principal_for(id))
        return [ 400, JSON.generate({ error: { code: 400, status: "SECRET_REFERENCE_ERROR" } }) ]
      end

      envelope[key] = versions.last
    end

    [ 200, JSON.generate({ renderedPayload: Base64.strict_encode64(JSON.generate(envelope)) }) ]
  end
end
