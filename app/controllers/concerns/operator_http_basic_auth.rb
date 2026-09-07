# frozen_string_literal: true

# The one HTTP Basic realm in front of Zimmer's operator surfaces.
#
# Zimmer is a [single circle of trust](docs/src/content/docs/intro/philosophy.md) and the
# network perimeter is the authentication boundary, so this is not "who are you" but "are
# you inside the perimeter at all" — one shared credential, no user model, no audit trail.
# It exists for the two surfaces whose blast radius the perimeter alone does not cover:
#
# - `/supervisor`, because Administrate renders `mcp_oauth_credentials.access_token` and its
#   siblings as *editable* fields (#42), and
# - the mutating `POST /health/*` actions, because they terminate processes, rewrite session
#   rows in bulk and halt the fleet's demand-side job queues (#312, #371).
#
# **The second one is why the realm is shared rather than per-surface.** The caller the
# `/health` gate is aimed at is not an outsider — it is an agent session, which runs on the
# production host, inside the tailnet, holding a valid `API_KEYS` entry in its own
# environment and in its `.mcp.json`. So a gate keyed on `API_KEYS` (the REST and MCP
# surfaces' credential) would gate nothing against it. `SUPERVISOR_PASSWORD` is the one
# credential the fleet's own sessions do not hold, because `CliSpawnEnv` clears it out of
# every spawned process's environment. Add it to that blocklist if you ever move this realm
# onto a different variable, or the gate quietly stops being one.
#
# Sharing one realm string across both surfaces is also deliberate on the human side: a
# browser caches Basic credentials per origin *and realm*, so an operator who has opened
# `/supervisor` is already carrying what `/health`'s buttons ask for.
#
# **It fails closed.** With `SUPERVISOR_PASSWORD` unset or blank every gated request is
# refused, and the refusal is logged with the variable's name in it. An unconfigured
# deployment gets no operator surface rather than an anonymous one.
module OperatorHttpBasicAuth
  extend ActiveSupport::Concern

  USERNAME_ENV = "SUPERVISOR_USERNAME"
  PASSWORD_ENV = "SUPERVISOR_PASSWORD"
  DEFAULT_USERNAME = "supervisor"
  REALM = "Zimmer supervisor"

  private

  def authenticate_operator
    # `blank?`, not `empty?`: a password of "   " is a misconfiguration (a trailing space in
    # an env file, a secret that resolved to whitespace), and treating it as a usable
    # credential would open the surface to one space.
    expected_password = ENV[PASSWORD_ENV].to_s
    return refuse_operator_unconfigured if expected_password.blank?

    expected_username = ENV[USERNAME_ENV].presence || DEFAULT_USERNAME

    authenticated = authenticate_with_http_basic do |username, password|
      # `&`, not `&&`: compare both halves every time, so a wrong username costs the same as
      # a wrong password and neither leaks which one was wrong.
      secure_compare(username, expected_username) & secure_compare(password, expected_password)
    end

    refuse_operator unless authenticated
  end

  # Refusing and *challenging* are two different things. The 401 is the gate saying no; the
  # `WWW-Authenticate: Basic` header on it is a separate instruction — "ask the human for a
  # credential". Hosts that have a reason not to challenge (a speculative request, a JSON
  # client) override this.
  def refuse_operator(realm_configured: true)
    request_http_basic_authentication(REALM)
  end

  # Without the log line an operator sees a browser prompt that never accepts anything and
  # nothing at all in the log, which is a miserable thing to debug — the whole point of
  # failing closed is lost if nobody can tell why.
  def refuse_operator_unconfigured
    Rails.logger.warn(
      "[operator_auth] refusing #{request.request_method} #{request.path}: " \
      "#{PASSWORD_ENV} is unset or blank, so the operator surfaces are closed"
    )
    refuse_operator(realm_configured: false)
  end

  # Constant-time comparison, mirroring Api::BaseController#authenticate_api_key.
  # `secure_compare` (as opposed to `fixed_length_secure_compare`) digests both sides first,
  # so it tolerates unequal lengths without leaking them.
  def secure_compare(given, expected)
    ActiveSupport::SecurityUtils.secure_compare(given.to_s, expected.to_s)
  end
end
