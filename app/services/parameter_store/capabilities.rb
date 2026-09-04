# frozen_string_literal: true

module ParameterStore
  # What a Parameter Store credential can actually do, asked of Google rather
  # than read off a config flag.
  #
  # A flag can lie in both directions, and both lies are expensive. A config that
  # claims write access on a read-only key produces a UI that offers an operation
  # and 403s on every use of it; a config that claims read-only on a key that can
  # in fact write produces a security property that exists in prose and not in
  # IAM. `testIamPermissions` reports the permissions that will actually be
  # enforced, including any inherited from a folder or the organisation, which a
  # project-level `get-iam-policy` would not show.
  #
  # When the probe cannot run at all we fail CLOSED but say so distinctly:
  # `probed?` is false and `reason` carries a sentence a human can act on. "The
  # store denied this" and "I could not find out" want different words in front
  # of a person — reporting the second as the first is how someone widens IAM to
  # fix an API that was simply never enabled.
  class Capabilities
    # The exact permission strings. Zimmer's RESOLVER credential is expected to
    # hold the first two and NONE of the rest; the audit in the provisioning
    # runbook asserts precisely that. A separate WRITER credential is the one
    # expected to hold the write set — see Writer.
    READ_SECRET_VALUE = "secretmanager.versions.access"
    RENDER_PARAMETER = "parametermanager.parameterVersions.render"
    CREATE_PARAMETER = "parametermanager.parameters.create"
    GET_PARAMETER = "parametermanager.parameters.get"
    DELETE_PARAMETER = "parametermanager.parameters.delete"
    LIST_PARAMETER_VERSIONS = "parametermanager.parameterVersions.list"
    WRITE_PARAMETER = "parametermanager.parameterVersions.create"
    DELETE_PARAMETER_VERSION = "parametermanager.parameterVersions.delete"
    CREATE_SECRET = "secretmanager.secrets.create"
    GET_SECRET = "secretmanager.secrets.get"
    DELETE_SECRET = "secretmanager.secrets.delete"
    WRITE_SECRET_VALUE = "secretmanager.versions.add"
    # `:render` dereferences a `__REF__` as the PARAMETER's own principal, not as
    # the caller's, so the parameter needs roles/secretmanager.secretAccessor ON
    # THE SECRET. Granting it is the step that fails silently when skipped: the
    # write succeeds, the store banner stays green, and every read of that
    # variable 400s with SECRET_REFERENCE_ERROR. Zimmer therefore does it itself
    # rather than leaving it to whoever clicked Save.
    READ_SECRET_IAM_POLICY = "secretmanager.secrets.getIamPolicy"
    BIND_SECRET = "secretmanager.secrets.setIamPolicy"

    # The MUTATING permissions. Zimmer's RESOLVER credential must hold none of
    # them — that absence is the "reads values, writes nothing" claim, checked
    # rather than asserted. Deliberately excludes the read permissions a write
    # also needs (`parameters.get`, `parameterVersions.list`, `secrets.get`,
    # `secrets.getIamPolicy`): `roles/parametermanager.parameterViewer` grants
    # two of those to the resolver today, and counting them as writes would
    # report the intended credential as over-privileged.
    WRITE_PERMISSIONS = [
      CREATE_PARAMETER, WRITE_PARAMETER, DELETE_PARAMETER, DELETE_PARAMETER_VERSION,
      CREATE_SECRET, WRITE_SECRET_VALUE, DELETE_SECRET, BIND_SECRET
    ].freeze

    # Exactly what Writer#upsert calls, reads included. Delete is deliberately
    # separate: a deployment allowed to set a key but not to remove one is a
    # coherent posture, and reporting it as "cannot write" would be wrong.
    UPSERT_PERMISSIONS = [
      CREATE_SECRET, GET_SECRET, WRITE_SECRET_VALUE, READ_SECRET_IAM_POLICY, BIND_SECRET,
      CREATE_PARAMETER, GET_PARAMETER, LIST_PARAMETER_VERSIONS, WRITE_PARAMETER
    ].freeze

    # Exactly what Writer#delete calls. A parameter cannot be deleted while it
    # still has versions, so the versions go first.
    DELETE_PERMISSIONS = [
      LIST_PARAMETER_VERSIONS, DELETE_PARAMETER_VERSION, DELETE_PARAMETER, DELETE_SECRET
    ].freeze

    PROBED_PERMISSIONS = ([ READ_SECRET_VALUE, RENDER_PARAMETER ] +
      UPSERT_PERMISSIONS + DELETE_PERMISSIONS).uniq.freeze

    # Re-probe at most this often; a failed probe is retried sooner, since the
    # usual cause (an API not yet enabled) is something a human is actively fixing.
    TTL = 5.minutes
    FAILURE_TTL = 15.seconds

    attr_reader :held, :reason

    def initialize(held: [], probed: false, reason: nil)
      @held = held
      @probed = probed
      @reason = reason
    end

    # Fail closed: no capability is assumed without an answer from Google.
    def self.unprobed(reason)
      new(held: [], probed: false, reason: reason)
    end

    # @param client [GcpClient]
    # @return [Capabilities] never raises — an unreachable probe is a result.
    def self.probe(client)
      new(held: client.held_permissions(PROBED_PERMISSIONS), probed: true)
    rescue AuthError => e
      unprobed("could not mint an access token for this credential (#{e.message})")
    rescue StoreError => e
      unprobed(
        "projects:testIamPermissions returned #{e.status}. The Cloud Resource Manager API may not be " \
        "enabled on this project, or this credential may have no access to it."
      )
    rescue => e
      unprobed("projects:testIamPermissions did not complete (#{e.class})")
    end

    def probed? = @probed

    # Render is the read path — the only one. `GcpClient#resolve_all` lists a
    # namespace and calls `:render` on each parameter, and never touches Secret
    # Manager directly, so `secretmanager.versions.access` alone resolves exactly
    # nothing. (Render is also sufficient on its own: it dereferences a `__REF__`
    # as the PARAMETER's principal rather than the caller's, which is why the
    # credential can come back with a value it holds no `access` on.)
    #
    # ORing the two reported a credential that could read secrets but not render
    # parameters as healthy least-privilege while every `${VAR}` silently
    # resolved to nothing — the exact green-banner-nothing-works state this class
    # exists to prevent.
    def read_secret_values?
      held.include?(RENDER_PARAMETER)
    end

    # The permissions Zimmer's resolver must NOT hold. Their absence is the
    # "reads values, writes nothing" claim — checked, not asserted.
    def write_permissions
      held & WRITE_PERMISSIONS
    end

    def writes?
      write_permissions.any?
    end

    # True when the credential is exactly the intended shape: it can read values
    # and cannot write any.
    def least_privilege?
      probed? && read_secret_values? && !writes?
    end

    # --- The writer side -----------------------------------------------------

    # @return [Array<String>] the permissions a create/update needs and this
    #   credential does not hold. Empty means the write path is open.
    def missing_for_upsert = UPSERT_PERMISSIONS - held

    # @return [Array<String>] the permissions a delete needs and this credential
    #   does not hold.
    def missing_for_delete = DELETE_PERMISSIONS - held

    def can_upsert? = probed? && missing_for_upsert.empty?
    def can_delete? = probed? && missing_for_delete.empty?
  end
end
