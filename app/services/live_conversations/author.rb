# frozen_string_literal: true

module LiveConversations
  # The human a Live Mode client request is authenticated as, established at the
  # boundary that accepted the request and never from anything in it.
  #
  # Two boundaries produce one:
  #
  # * the web UI (LiveConversationsController), behind the sign-in wall that
  #   only the deployment's one human passes — User.admin, the same rule as
  #   HumanMessageCapture.record_web_ui_message;
  # * the iOS app (Api::V1::LiveConversationsController), on a grant that acts as
  #   its person — User.for_email(grant.user_email), the same rule as
  #   HumanMessageCapture.record_assistant_message.
  #
  # Every other way into a conversation — `action_live_conversation` over an API
  # key above all — passes no Author, so the turns it writes carry no author and
  # nothing they cause is recorded as a human's. See
  # HumanMessageCapture.record_live_mode_message.
  Author = Data.define(:user, :provenance) do
    def key = user.key

    # @return [Author, nil] nil when the configured admin key names no roster row
    def self.web_ui
      user = User.admin
      user && new(user: user, provenance: { "via" => "web_ui" })
    end

    # @param grant [OauthServer::Grant, nil] the grant the iOS app's request authenticated with
    # @return [Author, nil] nil unless the grant acts as its person and that person is on the roster
    def self.native_app(grant)
      return nil if grant.nil? || !grant.acts_as_human?

      user = User.for_email(grant.user_email)
      user && new(user: user, provenance: { "via" => "ios_app", "oauth_grant_id" => grant.id, "grant_user_email" => grant.user_email })
    end
  end
end
