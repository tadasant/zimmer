# frozen_string_literal: true

module ParameterStore
  # Reads Zimmer's secrets out of Google Parameter Manager + Secret Manager.
  #
  # This is the RESOLVER half of the store only: list a namespace and render the
  # values in it. There is deliberately no create/rotate/destroy here, and that
  # absence is structural rather than an oversight — Zimmer's resolver credential
  # holds no write permission (see docs/operate/secrets-parameter-store.md), and
  # keeping the verbs out of the class the SecretProviders chain holds is what
  # makes "the resolver cannot write" checkable by reading one file.
  #
  # The write verbs live in {WriteClient}, built from a separate credential by
  # {Writer} and reached only from the Inference page's Pi tab. Everything else
  # is still set by a human through the Secrets Console or `gcloud`.
  #
  # ## How a value is actually stored
  #
  # Two resources per secret, joined by GCP itself:
  #
  #   * A Parameter Manager parameter, whose JSON payload is an *envelope*:
  #     `{"path": "...", "secret": true, "value": "__REF__(\"//secretmanager...\")"}`.
  #     The envelope holds a POINTER, not the secret.
  #   * A Secret Manager secret holding the bytes.
  #
  # ## The envelope declares its own encoding
  #
  # A secret's bytes may be stored **base64url** rather than literally, and the
  # envelope says so with `"encoding":"base64url"`. That is not decoration: a
  # rendered payload is assembled by SUBSTITUTING the secret's bytes into the
  # payload TEXT, so a value carrying a quote, a brace or a newline is rejected
  # by Parameter Manager's injection detector with `400 injection detected`.
  # Encoding to `[A-Za-z0-9_-]` is what makes an arbitrary credential storable
  # at all, and it is what strad's Secrets Console — the sanctioned human write
  # surface for this store — does to every secret it writes.
  #
  # The field's ABSENCE is a documented state, not an unknown one: it means the
  # literal bytes. That is what a parameter seeded without the field carries,
  # and it is what {WriteClient} writes. So the encoding is honoured only when
  # declared, and an encoding this Zimmer does not implement is REFUSED rather
  # than guessed at — see {#decoded_value}.
  #
  # `GET .../versions/{v}:render` dereferences the `__REF__` server-side and hands
  # back the envelope with the real value in it. That single verb is the whole read
  # path: this client calls Parameter Manager (and Cloud Resource Manager, to probe
  # its own permissions) and never calls Secret Manager, so the caller needs
  # `parametermanager.parameterVersions.render` and the dereference is authorized as
  # the PARAMETER's principal, not the caller's. `secretmanager.versions.access` on
  # the resolver is what the seeding flow and the provisioning audit assert against —
  # nothing here reads through it.
  #
  # Because a rendered payload contains a secret, no response body is ever logged
  # or interpolated into an error message.
  class GcpClient
    PM_API_BASE = "https://parametermanager.googleapis.com"
    SM_API_BASE = "https://secretmanager.googleapis.com"
    # Cloud Resource Manager, where a project-level IAM binding — including one
    # inherited from a folder or the org — is actually evaluated.
    CRM_API_BASE = "https://cloudresourcemanager.googleapis.com"

    # The one value encoding this resolver implements: base64url of the real
    # bytes, unpadded, alphabet `[A-Za-z0-9_-]`. The writer that produces it
    # states the same rule in `src/secrets/parameters/wire.ts` in tadasant/strad.
    VALUE_ENCODING = "base64url"

    # Only parameters carrying this label are considered. It keeps a hand-created
    # or foreign parameter in the same project from being read as Zimmer config.
    MANAGED_BY = "zimmer"

    # Read at most this many parameters' versions concurrently. Resolving a
    # namespace is one list plus a render per parameter, so an unbounded fan-out
    # against a large namespace is a self-inflicted rate limit.
    FANOUT = 8

    # What {#resolve_all} answers: the `namespace => {VARIABLE => value}` map
    # every caller already expects, plus two side-channels about the envelopes
    # behind it.
    #
    # A Hash subclass rather than a wrapper because the map is the interface —
    # `fetch`, `[]`, `keys` and equality against a plain Hash all keep working,
    # so nothing downstream has to learn about an envelope to keep resolving.
    # A caller that has only a plain Hash (the cold-cache `{}`, or the result of
    # a `select` — Hash's own methods return plain Hashes) must guard with
    # `is_a?` rather than assume these readers exist.
    #
    # Both side-channels are keyed by NAMESPACE, like the map itself, because
    # every question asked of them is namespace-scoped: a name refused at the
    # pre-rename path but served from the canonical one resolves normally, and
    # a name refused at the pre-rename path is still sitting there.
    class Snapshot < Hash
      # @return [Hash{String => Array<String>}] per namespace, variables the
      #   store HOLDS whose envelope declared a value encoding this resolver
      #   does not implement, or declared base64url over bytes that are not.
      #   They are absent from the maps above: a value whose encoding is not
      #   understood is not a value.
      attr_reader :undecodable

      # @return [Hash{String => Array<String>}] per namespace, variables whose
      #   envelope DECLARED an encoding and was decoded. {WriteClient} cannot
      #   re-declare one, so anything copying a value out of here has to know
      #   (see {NamespaceMigration}).
      attr_reader :encoded

      def initialize(namespaces = [])
        super()
        @undecodable = {}
        @encoded = {}
        namespaces.each do |namespace|
          self[namespace] = {}
          @undecodable[namespace] = []
          @encoded[namespace] = []
        end
      end
    end

    # `account` is exposed so the write path can reuse this credential when a
    # deployment has no separate writer key — see ParameterStore::Writer. It
    # does not make this client writable; there is still no write verb here.
    attr_reader :project_id, :location, :account

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

    # Every VARIABLE_NAME => value under `namespace`.
    #
    # A parameter whose envelope path does not actually start with `namespace` is
    # skipped: `Namespace.parameter_id` is a lossy fold, so a resolving id is not
    # proof the parameter is the one asked for.
    #
    # @param namespace [String] e.g. "/zimmer/production/secrets/static/"
    # @return [Hash{String => String}]
    # @raise [StoreError, AuthError] when the store could not be consulted.
    def resolve(namespace)
      resolve_all([ namespace ]).fetch(namespace)
    end

    # The same, for SEVERAL namespaces, in ONE pass over the project.
    #
    # This exists because the read cost is per-project, not per-namespace: a
    # resolve is one `parameters.list` plus a `:render` per managed parameter,
    # and the namespace is a fence applied to the rendered envelope afterwards.
    # Calling {#resolve} twice would therefore double every API call to answer a
    # question one pass already answered — which matters, because reading the
    # pre-rename namespace alongside the canonical one is the whole transition
    # (see {Namespace.read_namespaces}).
    #
    # Each namespace gets its own map, so the caller can apply precedence AND say
    # which namespace answered. A parameter matching more than one namespace
    # (possible only if one is a prefix of another) appears under each.
    #
    # @param namespaces [Array<String>]
    # @return [Snapshot] a `Hash{String => Hash{String => String}}` in which every
    #   namespace asked for is a key, empty map and all, and whose
    #   {Snapshot#undecodable} names what was held back.
    # @raise [StoreError, AuthError] when the store could not be consulted.
    def resolve_all(namespaces)
      namespaces = Array(namespaces)
      out = Snapshot.new(namespaces)

      rendered_envelopes(namespaces).each do |envelope|
        path = envelope["path"].to_s
        variable = Namespace.variable_of(path)
        next if variable.blank?

        matching = namespaces.select { |namespace| path.start_with?(namespace) }
        next if matching.empty?

        value = decoded_value(envelope, variable)
        if value.nil?
          matching.each { |namespace| out.undecodable[namespace] << variable }
          next
        end

        matching.each do |namespace|
          out[namespace][variable] = value
          out.encoded[namespace] << variable unless envelope["encoding"].nil?
        end
      end

      out
    end

    # Which of `permissions` this credential actually holds on the project.
    #
    # Asked of Cloud Resource Manager rather than of the two secret APIs, because
    # that is where a project-level binding — including one inherited from a
    # folder or the org — is evaluated.
    #
    # @param permissions [Array<String>]
    # @return [Array<String>] the subset held
    # @raise [StoreError, AuthError]
    def held_permissions(permissions)
      body = post(
        "#{@crm_api_base}/v1/projects/#{ERB::Util.url_encode(project_id)}:testIamPermissions",
        { permissions: permissions }
      )
      Array(body["permissions"])
    end

    private

    def pm_parent = "projects/#{project_id}/locations/#{location}"
    def sm_parent = "projects/#{project_id}"

    # List the project's managed parameters, then render one version of each and
    # keep the envelopes falling inside any of `namespaces`.
    def rendered_envelopes(namespaces)
      ids = managed_parameter_ids

      ids.each_slice(FANOUT).flat_map do |slice|
        slice.filter_map { |id| rendered_envelope(id, namespaces) }
      end
    end

    def managed_parameter_ids
      ids = []
      page_token = nil

      loop do
        query = { pageSize: 100 }
        query[:pageToken] = page_token if page_token
        body = get("#{@pm_api_base}/v1/#{pm_parent}/parameters?#{query.to_query}")

        Array(body["parameters"]).each do |parameter|
          next unless parameter.dig("labels", "managed-by") == MANAGED_BY

          id = parameter["name"].to_s.split("/").last
          ids << id if id.present?
        end

        page_token = body["nextPageToken"].presence
        break if page_token.nil?
      end

      ids
    end

    def rendered_envelope(id, namespaces)
      version = current_version_id(id)
      return nil if version.nil?

      body = get("#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}/versions/#{version}:render")
      data = body["renderedPayload"].presence || body.dig("payload", "data").presence
      return nil if data.nil?

      envelope = decode_envelope(data)
      return nil if envelope.nil?
      # The namespace fence, applied to the envelope's own path rather than to
      # the flattened id.
      return nil unless namespaces.any? { |namespace| envelope["path"].to_s.start_with?(namespace) }

      envelope
    rescue StoreError => e
      # A parameter that vanished between the list and the render is not a
      # failure of the whole namespace.
      raise unless e.status == 404

      nil
    end

    # The greatest `v{n}` among a parameter's enabled versions.
    def current_version_id(id)
      body = get("#{@pm_api_base}/v1/#{pm_parent}/parameters/#{id}/versions?pageSize=100")

      Array(body["parameterVersions"])
        .reject { |version| version["disabled"] }
        .filter_map { |version| version["name"].to_s.split("/").last }
        .max_by { |name| name[/(\d+)\z/, 1].to_i }
    end

    # The envelope's `value`, with whatever encoding it DECLARES undone.
    #
    # Three outcomes, and the middle one is the whole point of this method:
    #
    #   * **No `encoding`** — the literal bytes, returned unchanged. This is not
    #     a fallback for an unknown state; it is the documented spelling for "the
    #     value is the value", and it covers a parameter seeded without the field
    #     as well as every one {WriteClient} writes.
    #   * **`base64url`** — decoded, and only if the bytes really are base64url
    #     of valid UTF-8.
    #   * **Anything else** — REFUSED. Passing through an encoding we do not
    #     implement would hand a session bytes we cannot vouch for and call it a
    #     credential, which is exactly the failure this method exists to end;
    #     the next format would land as silently as this one did.
    #
    # A refusal drops ONE name rather than failing the resolve: the alternative
    # takes every other `${VAR}` in the project down with it (the hazard
    # {WriteClient#upsert} refuses to create), and a dropped name is a miss, which
    # the SecretProviders chain is built to survive by falling through. It is not
    # silent — it is logged at error level naming the variable, and the Connectors
    # page lists it as held-but-not-served.
    #
    # @return [String, nil] nil when the value was refused.
    def decoded_value(envelope, variable)
      encoding = envelope["encoding"]
      value = envelope["value"].to_s
      return value if encoding.nil?

      unless encoding == VALUE_ENCODING
        return refuse(variable, "declares value encoding #{bounded(encoding)}, " \
          "which this Zimmer does not implement")
      end

      decoded = decode_base64url(value)
      return decoded unless decoded.nil?

      refuse(variable, "is labelled #{VALUE_ENCODING}, but its stored value does not decode " \
        "as #{VALUE_ENCODING} of UTF-8 text")
    end

    # Say why a value is being held back, and answer nil so the caller drops it.
    #
    # Everything interpolated here comes out of a store payload, so both halves
    # are bounded and inspected: `variable` is a path segment an envelope
    # chose, and a raw one could carry newlines and forge a second log line.
    # The VALUE is never named, only the reason.
    #
    # @return [nil] always.
    def refuse(variable, reason)
      Rails.logger.error "[ParameterStore] #{bounded(variable)} #{reason}; refusing to serve it"
      nil
    end

    def bounded(text) = text.to_s.truncate(64).inspect

    # Invert {VALUE_ENCODING} for one value, or answer nil if it is not that.
    #
    # Two refusals, and only the second is about the encoding proper:
    #
    #   * **Not base64url at all.** `urlsafe_decode64` raises on a bad alphabet
    #     or a bad length, and the re-encode is defence in depth behind it —
    #     cheap, and it does not depend on how strict a given Ruby's decoder is
    #     about trailing bits. The comparison canonicalises the stored spelling
    #     first: standard-alphabet base64, or a padded value, decodes correctly
    #     and must not be refused for how it is spelled.
    #   * **Not UTF-8.** A `${VAR}` becomes an environment variable, and Zimmer
    #     handles those as UTF-8 strings throughout — {Resolver.from_env}
    #     already switches the store off rather than serve bytes that are not.
    #     A binary credential is therefore out of scope for this store, and
    #     saying so here is better than handing one to a child process. It is
    #     written down in docs/limitations.
    def decode_base64url(value)
      decoded = Base64.urlsafe_decode64(value).force_encoding(Encoding::UTF_8)
      return nil unless decoded.valid_encoding?

      canonical = value.tr("+/", "-_").sub(/=+\z/, "")
      return nil unless Base64.urlsafe_encode64(decoded, padding: false) == canonical

      decoded
    rescue ArgumentError
      nil
    end

    def decode_envelope(base64)
      parsed = JSON.parse(Base64.decode64(base64))
      return nil unless parsed.is_a?(Hash) && parsed["path"].is_a?(String) && parsed["value"].is_a?(String)

      parsed
    rescue JSON::ParserError, ArgumentError
      # A rendered payload holds a secret, so the malformed body is NOT echoed.
      Rails.logger.warn "[ParameterStore] a parameter payload is not a Zimmer envelope; skipping it"
      nil
    end

    def get(url) = call("GET", url, nil)
    def post(url, body) = call("POST", url, JSON.generate(body))

    def call(method, url, body)
      status, response_body = @transport.request(method, url, {
        "authorization" => "Bearer #{@account.access_token}",
        "content-type" => "application/json"
      }, body)

      unless (200..299).cover?(status)
        # The path names a resource. The BODY is deliberately not included: on
        # the render and access verbs Google's error body can quote the payload.
        raise StoreError.new("#{method} #{sanitize(url)} failed: #{status}", status)
      end

      return {} if response_body.blank?

      JSON.parse(response_body)
    rescue JSON::ParserError
      raise StoreError.new("#{method} #{sanitize(url)} returned a body that is not JSON", 502)
    end

    # Keep the resource path, drop the query string (which can carry a page token).
    def sanitize(url)
      URI(url).path
    rescue URI::InvalidURIError
      "(unparseable url)"
    end
  end
end
