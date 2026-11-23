# frozen_string_literal: true

module ApplicationCable
  # Every Turbo Stream subscription arrives over this one WebSocket, so it is
  # the cable's half of the web login wall (WebSignInRequired is the HTTP half).
  # With the gate on, a browser without a valid sign-in cookie is refused at
  # connect. The stream names are signed as well, but a signature proves only
  # that the name came from a page Zimmer rendered, not who is asking now.
  #
  # Every refusal is counted in SecurityTelemetry (`web_cable`) and logged with
  # its reason and the client that asked, never the cookie. An ERROR pages, so
  # only a refusal an operator has to act on is one: see ORDINARY_REFUSALS.
  class Connection < ActionCable::Connection::Base
    # The gate doing its job for one browser. Logged at WARN, the lowest level
    # that leaves the container. Anything not listed here is logged at ERROR, so
    # a reason added later pages until someone decides it should not.
    ORDINARY_REFUSALS = %w[no_cookie expired signed_out_everywhere second_factor_missing].freeze

    MAX_HEADER_CHARS = 300

    identified_by :web_identity

    def connect
      configuration = WebAuth::Configuration.current
      return unless configuration.enabled?

      check = WebAuth::Cookies.check_sign_in(cookies, configuration)
      return self.web_identity = check.identity if check.identity

      # A gate that cannot sign anyone in refuses browsers for what looks like
      # an ordinary reason, so its own problems come first.
      problems = configuration.problems
      refuse("misconfigured", cookie: check.refusal, problems: problems.to_sentence) if problems.any?
      refuse(check.refusal)
    rescue WebAuth::Configuration::Unavailable => e
      refuse("configuration_unavailable", error: e.message)
    end

    private

    # Raises what `reject_unauthorized_connection` raises, so the socket is closed
    # the same way. That method is not called because it logs at ERROR with no
    # reason, whatever the reason was.
    def refuse(reason, **detail)
      SecurityTelemetry.record_auth_failure(:web_cable, reason)

      fields = { reason: reason, **detail, ip: client_ip, user_agent: request.user_agent, origin: request.headers["Origin"] }
      line = fields.map { |name, value| "#{name}=#{value.to_s.truncate(MAX_HEADER_CHARS).inspect}" }.join(" ")
      severity = ORDINARY_REFUSALS.include?(reason) ? :warn : :error
      Rails.logger.public_send(severity, "[web_auth] An unauthorized connection attempt was rejected: #{line}")

      raise ActionCable::Connection::Authorization::UnauthorizedError
    end

    # `remote_ip` raises when Client-Ip and X-Forwarded-For disagree, which must
    # not turn a refusal into a connection left open.
    def client_ip
      request.remote_ip
    rescue ActionDispatch::RemoteIp::IpSpoofAttackError
      "conflicting Client-Ip and X-Forwarded-For"
    end
  end
end
