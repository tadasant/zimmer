# frozen_string_literal: true

# The browser extension's way in (tadasant/zimmer#175): the Quick Router bubble,
# reachable from any page on the web instead of only from Zimmer's own.
#
# This is deliberately the narrowest controller in the API. It does one thing —
# create a Quick Router session from a message, the page it was typed on, and
# the spot on that page the human pinned — and answers with the new session's id
# and URL. There is no index, no show, no read of anything. The credential it
# takes is an ApiKey with the `quick_router` grant, which `authenticate` refuses
# everywhere else; so what a stolen extension key buys is exactly the ability to
# start router sessions, and nothing it can read back.
#
# It is an API controller and not a web UI one because it has no CSRF token to
# check: the request comes from an extension service worker, whose origin is the
# extension itself. Nothing here needs CORS — Chrome exempts an extension's own
# fetches to hosts in its `host_permissions` — so Zimmer still has none.
#
# The one thing it does that the rest of the API does not is record the message
# as a HumanMessage. The API's rule is that a shared key names a caller and not a
# person, which is why `Api::V1::SessionsController` records nothing. A
# `quick_router` key is different by construction: it is a minted key, so it is
# out of every agent session's reach, and its only holder is the browser of the
# one human the deployment serves. The actor at this boundary is established.
class Api::V1::QuickRouterController < Api::BaseController
  PAGE_URL_MAX_LENGTH = 2_048
  PAGE_TITLE_MAX_LENGTH = 300

  # Sessions this endpoint will start per client IP per minute. A human drops a
  # handful of pins an hour; this is the ceiling on what a leaked key can spend
  # from one address, not something anyone typing should meet.
  RATE_LIMIT = 10
  RATE_LIMIT_WINDOW = 1.minute

  SOURCE = "browser_extension"
  ENTRY_POINT = "browser_extension.quick_router"

  before_action :enforce_rate_limit

  # POST /api/v1/quick_router
  def create
    prompt = params[:prompt].to_s.strip
    if prompt.blank?
      return render_api_error("Unprocessable Entity", "prompt can't be blank", status: :unprocessable_entity)
    end
    if prompt.length > Session::PROMPT_MAX_LENGTH
      return render_api_error("Unprocessable Entity",
        "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)", status: :unprocessable_entity)
    end

    page_url = params[:page_url].to_s.strip.truncate(PAGE_URL_MAX_LENGTH)
    page_title = params[:page_title].to_s.strip.truncate(PAGE_TITLE_MAX_LENGTH)
    # The pin's own fields are capped separately in QuickRouterPrompt, so a long
    # page never truncates away the thing that was pinned.
    page_context = params[:page_context].to_s.strip.truncate(QuickRouterPrompt::PAGE_CONTEXT_MAX_LENGTH)
    pin = QuickRouterPrompt.normalize_pin(params[:pin])

    augmented_prompt = QuickRouterPrompt.augment(
      prompt: prompt, page_context: page_context, current_url: page_url, page_title: page_title, pin: pin
    )
    if augmented_prompt.length > Session::PROMPT_MAX_LENGTH
      return render_api_error("Unprocessable Entity",
        "prompt and page context together are too long; send less of the page", status: :unprocessable_entity)
    end

    session = Session.create_from_agent_root!(
      agent_root_name: AgentRootsConfig.router_root_name,
      prompt: augmented_prompt,
      metadata: { source: SOURCE, original_prompt: prompt, current_url: page_url, page_title: page_title, pin: pin }.compact_blank,
      # A human typed this, in a browser — the same genesis as the in-app bubble,
      # and priority for the same reason: they are waiting.
      genesis: SessionGenesis::WEB_UI,
      skip_enqueue: true
    )

    # The human's own words, not the page block Zimmer wrapped around them.
    HumanMessageCapture.record_web_ui_message(session: session, content: prompt, entry_point: ENTRY_POINT)

    AgentSessionJob.enqueue_new_session(session.id)

    render json: { session_id: session.id, session_url: "#{AppUrl.base_url}#{session_path(session)}" }, status: :created
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render_api_error("Unprocessable Entity", "Router agent root not configured: #{e.message}", status: :unprocessable_entity)
  end

  private

  # Only a `quick_router` key opens this controller — see Api::BaseController.
  def api_key_grant
    ApiKey::QUICK_ROUTER_GRANT
  end

  # One counter per client address per window. Read at request time rather than
  # captured at class load, so a store swapped in for a test — or a cache that
  # comes up after boot — is the one consulted. A store that cannot count (the
  # null store, a Redis that is down) returns nil and the request goes through:
  # the key is the boundary, and this is the brake behind it.
  def enforce_rate_limit
    count = Rails.cache.increment("quick_router:rate:#{request.remote_ip}", 1, expires_in: RATE_LIMIT_WINDOW)
    return if count.nil? || count <= RATE_LIMIT

    render_api_error("Too Many Requests",
      "at most #{RATE_LIMIT} Quick Router sessions a minute from one address",
      status: :too_many_requests, retry_after: RATE_LIMIT_WINDOW.to_i)
  end
end
