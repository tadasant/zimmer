# frozen_string_literal: true

module ApplicationCable
  # Every Turbo Stream subscription arrives over this one WebSocket, so it is
  # the cable's half of the web login wall (WebSignInRequired is the HTTP half).
  # With the gate on, a browser without a valid sign-in cookie is refused at
  # connect. The stream names are signed as well, but a signature proves only
  # that the name came from a page Zimmer rendered, not who is asking now.
  class Connection < ActionCable::Connection::Base
    identified_by :web_identity

    def connect
      configuration = WebAuth::Configuration.current
      return unless configuration.enabled?

      self.web_identity = WebAuth::Cookies.signed_in_identity(cookies, configuration) || reject_unauthorized_connection
    rescue WebAuth::Configuration::Unavailable
      reject_unauthorized_connection
    end
  end
end
