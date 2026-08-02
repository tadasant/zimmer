# frozen_string_literal: true

# Records HumanMessage rows for input typed into the Zimmer web UI.
#
# Included ONLY by browser-facing controllers (ApplicationController
# descendants). That inclusion is the attribution: Zimmer has no login, and the
# deployment's single circle of trust means exactly one human can reach the web
# UI — so a request that arrived through these controllers was typed by
# HumanIdentity.web_ui.
#
# Api::BaseController descendants — the REST API, and McpController with it —
# must NOT include this. They authenticate an API key shared by the whole agent
# fleet, which establishes a caller but not a person. An agent session issuing
# `follow_up` over MCP and Tadas clicking Send in the browser produce the same
# `user`-role turn through the same delivery path; the controller that accepted
# the request is the only thing that tells them apart, so it is where the
# decision is made.
module WebUiHumanMessageCapture
  extend ActiveSupport::Concern

  private

  # @param session [Session]
  # @param content [String] the human's own words
  # @param entry_point [String] e.g. "web_ui.follow_up"
  # @return [HumanMessage, nil]
  def capture_web_ui_human_message(session, content, entry_point, occurred_at: Time.current)
    HumanMessageCapture.record_web_ui_message(
      session: session,
      content: content,
      entry_point: entry_point,
      occurred_at: occurred_at
    )
  end
end
