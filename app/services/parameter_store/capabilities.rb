# frozen_string_literal: true

module ParameterStore
  # What Zimmer's resolver credential can actually do, asked of Google rather
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
    # The exact permission strings. Zimmer's credential is expected to hold the
    # first two and NONE of the rest; the audit in the provisioning runbook
    # asserts precisely that.
    READ_SECRET_VALUE = "secretmanager.versions.access"
    RENDER_PARAMETER = "parametermanager.parameterVersions.render"
    CREATE_PARAMETER = "parametermanager.parameters.create"
    WRITE_PARAMETER = "parametermanager.parameterVersions.create"
    CREATE_SECRET = "secretmanager.secrets.create"
    WRITE_SECRET_VALUE = "secretmanager.versions.add"

    PROBED_PERMISSIONS = [
      READ_SECRET_VALUE, RENDER_PARAMETER,
      CREATE_PARAMETER, WRITE_PARAMETER, CREATE_SECRET, WRITE_SECRET_VALUE
    ].freeze

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

    # Either read path counts. Parameter Manager's `:render` dereferences a
    # `__REF__` as the PARAMETER's principal rather than the caller's, so a
    # credential holding render alone can still come back with a value.
    def read_secret_values?
      held.include?(READ_SECRET_VALUE) || held.include?(RENDER_PARAMETER)
    end

    # The permissions Zimmer's resolver must NOT hold. Their absence is the
    # "reads values, writes nothing" claim — checked, not asserted.
    def write_permissions
      held & [ CREATE_PARAMETER, WRITE_PARAMETER, CREATE_SECRET, WRITE_SECRET_VALUE ]
    end

    def writes?
      write_permissions.any?
    end

    # True when the credential is exactly the intended shape: it can read values
    # and cannot write any.
    def least_privilege?
      probed? && read_secret_values? && !writes?
    end
  end
end
