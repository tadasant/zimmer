# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# What the iOS app's token reaches beyond the sessions controller, action by
# action (`accepts_native_app_tokens only:`). Each controller the app reads or
# drives is open for exactly those actions; every other action on it answers the
# app's token with the same 401 a bad key gets.
class NativeAppAccessTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers
  include WorkBacklogHelpers
  include ActiveJob::TestHelper

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_native_access"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = API_KEY
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "a read-only controller answers the app's reads and refuses its writes" do
    headers = bearer(token)
    session = build_zimmer_session(status: :needs_input)
    log = session.logs.create!(content: "Cloned the repo", level: "info")

    get "/api/v1/sessions/#{session.id}/logs", headers: headers
    assert_response :success
    get "/api/v1/sessions/#{session.id}/logs/#{log.id}", headers: headers
    assert_response :success

    post "/api/v1/sessions/#{session.id}/logs", params: { log: { content: "forged", level: "info" } }, headers: headers
    assert_response :unauthorized
    delete "/api/v1/sessions/#{session.id}/logs/#{log.id}", headers: headers
    assert_response :unauthorized
    assert_equal [ "Cloned the repo" ], session.logs.pluck(:content)
  end

  test "logs can leave the verbose level out, as the web UI's Show Logs does" do
    session = build_zimmer_session(status: :running)
    session.logs.create!(content: "Cloned the repo", level: "info")
    session.logs.create!(content: "raw cli output", level: Log::VERBOSE_LEVEL)

    get "/api/v1/sessions/#{session.id}/logs", params: { exclude_level: Log::VERBOSE_LEVEL }, headers: bearer(token)

    assert_response :success
    assert_equal [ "Cloned the repo" ], JSON.parse(response.body)["logs"].map { |l| l["content"] }
  end

  test "the app reads and manages a session's queue but adds to it only through follow_up" do
    headers = bearer(token)
    session = build_zimmer_session(status: :running)
    first = session.enqueued_messages.create!(content: "first", position: 1, status: "pending")
    second = session.enqueued_messages.create!(content: "second", position: 2, status: "pending")

    get "/api/v1/sessions/#{session.id}/enqueued_messages", headers: headers
    assert_response :success

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{second.id}/reorder", params: { position: 1 }, headers: headers
    assert_response :success

    delete "/api/v1/sessions/#{session.id}/enqueued_messages/#{first.id}", headers: headers
    assert_response :success
    assert_not EnqueuedMessage.exists?(first.id)

    post "/api/v1/sessions/#{session.id}/enqueued_messages", params: { content: "sneaked in" }, headers: headers
    assert_response :unauthorized
  end

  test "editing a queued message from an app that acts on its approver's behalf records it as theirs" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    session = build_zimmer_session(status: :running)
    queued = session.enqueued_messages.create!(content: "deploy", position: 1, status: "pending")
    from_key = session.enqueued_messages.create!(content: "other", position: 2, status: "pending")

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{queued.id}", params: { content: "deploy to staging only" }, headers: headers
    assert_response :success
    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{from_key.id}", params: { content: "from a script" }, headers: { "X-API-Key" => API_KEY }
    assert_response :success

    message = session.human_messages.sole
    assert_equal "deploy to staging only", message.content
    assert_equal HumanMessage::ASSISTANT, message.channel
    assert_equal "ios_app.enqueued_message_edited", message.provenance["entry_point"]
  end

  test "a session started from an app that acts on its approver's behalf records its prompt as theirs" do
    AgentSessionJob.stubs(:enqueue_new_session).returns(OpenStruct.new(job_id: "job-1"))

    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "Rotate the staging deploy key" },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :created
    from_phone = Session.find(JSON.parse(response.body)["session"]["id"])

    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "From a script" }, headers: { "X-API-Key" => API_KEY }
    assert_response :created
    from_key = Session.find(JSON.parse(response.body)["session"]["id"])

    message = from_phone.human_messages.sole
    assert_equal "Rotate the staging deploy key", message.content
    assert_equal "ios_app.new_session", message.provenance["entry_point"]
    assert_empty from_key.human_messages
  end

  test "a relay-only app's edit records nothing" do
    session = build_zimmer_session(status: :running)
    queued = session.enqueued_messages.create!(content: "deploy", position: 1, status: "pending")

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{queued.id}", params: { content: "changed" }, headers: bearer(token)

    assert_response :success
    assert_empty session.human_messages
  end

  test "notifications, triggers, costs, health and the catalogs answer the app's reads" do
    headers = bearer(token)

    [ "/api/v1/notifications", "/api/v1/notifications/badge", "/api/v1/triggers", "/api/v1/costs",
      "/api/v1/health", "/api/v1/configs", "/api/v1/mcp_servers", "/api/v1/skills", "/api/v1/hooks", "/api/v1/plugins",
      "/api/v1/model_catalog_entries" ].each do |path|
      get path, headers: headers
      assert_response :success, "#{path} did not answer the app's token"
    end
  end

  test "what the web offers no person stays closed to the app" do
    headers = bearer(token)
    # The token is refused before the record is looked up, so no row needs to exist:
    # a 401 here, rather than the 404 an API key would get, is the boundary.

    post "/api/v1/notifications/push", params: { title: "t", body: "b" }, headers: headers
    assert_response :unauthorized
    post "/api/v1/costs/backfill", headers: headers
    assert_response :unauthorized
    post "/api/v1/model_catalog_entries", params: { runtime: "claude_code", model: "x" }, headers: headers
    assert_response :unauthorized
    # A gate's, a groomer's and an analyzer's writes: no form on any page offers them.
    post "/api/v1/gate_decisions", params: { gate: "pr_merge", surface: "zimmer", entry: {} }, headers: headers
    assert_response :unauthorized
    post "/api/v1/work_backlog_items", params: { key: "zimmer#1" }, headers: headers
    assert_response :unauthorized
    post "/api/v1/work_backlog_items/pull", params: { count: 1 }, headers: headers
    assert_response :unauthorized
    post "/api/v1/outcome_analyses", params: { session_id: 0 }, headers: headers
    assert_response :unauthorized
  end

  test "the app creates, edits and deletes a trigger and fetches the form's pickers, as the web form does" do
    headers = bearer(token)
    condition = { condition_type: "slack", configuration: { channel_id: "C1", channel_name: "alerts", event_type: "new_message" } }

    post "/api/v1/triggers", params: { name: "From the phone", agent_root_name: "zimmer", prompt_template: "Look at {{link}}",
      trigger_conditions_attributes: [ condition ] }, headers: headers, as: :json
    assert_response :created
    trigger = Trigger.find(JSON.parse(response.body)["trigger"]["id"])

    patch "/api/v1/triggers/#{trigger.id}", params: { name: "Renamed on the phone" }, headers: headers, as: :json
    assert_response :success
    assert_equal "Renamed on the phone", trigger.reload.name

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:list_channels).returns([ OpenStruct.new(id: "C1", name: "alerts", is_private: false, num_members: 2) ])
    get "/api/v1/triggers/channels", headers: headers
    assert_response :success
    assert_equal [ "C1" ], JSON.parse(response.body)["channels"].map { |c| c["id"] }

    WhatsappService.stubs(:configured?).returns(true)
    WhatsappService.any_instance.stubs(:list_chats).returns([ { "id" => "1@g.us", "name" => "Family", "is_group" => true } ])
    get "/api/v1/triggers/whatsapp_chats", headers: headers
    assert_response :success
    assert_equal [ "1@g.us" ], JSON.parse(response.body)["chats"].map { |c| c["id"] }

    delete "/api/v1/triggers/#{trigger.id}", headers: headers
    assert_response :no_content
    assert_not Trigger.exists?(trigger.id)
  end

  test "the app runs every operator action on the health page, in a cooldown bucket of its own" do
    ErrorReporter.stubs(:report_message)
    headers = bearer(token)
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    GoodJob::Job.delete_all

    post "/api/v1/health/cleanup_processes", headers: headers
    assert_response :success
    post "/api/v1/health/retry_sessions", headers: headers
    assert_response :success
    post "/api/v1/health/archive_old", params: { days: 365 }, headers: headers
    assert_response :success

    # The cooldown is per caller. The app's token presents no key, and it must not
    # share the web dashboard's anonymous bucket or the API key's.
    post "/api/v1/health/cleanup_processes", headers: headers
    assert_response :too_many_requests
    post "/api/v1/health/cleanup_processes", headers: { "X-API-Key" => API_KEY }
    assert_response :success

    post "/api/v1/health/enter_queue_recovery_mode", params: { reason: "from the phone", ttl_minutes: 5 }, headers: headers
    assert_response :success
    assert JSON.parse(response.body)["active"]
    get "/api/v1/health/queue_recovery_mode", headers: headers
    assert_response :success
    post "/api/v1/health/exit_queue_recovery_mode", headers: headers
    assert_response :success
    assert_equal false, JSON.parse(response.body)["active"]

    post "/api/v1/health/run_post_deploy_tasks", headers: headers
    assert_response :success

    2.times { enqueue_good_job }
    get "/api/v1/health/queued_jobs", params: { queue_name: "pollers" }, headers: headers
    assert_response :success
    assert_equal 2, JSON.parse(response.body)["matched"]
    post "/api/v1/health/reschedule_queued_jobs", params: { queue_name: "pollers", expected_count: 2, delay_minutes: 5 }, headers: headers
    assert_response :success
    post "/api/v1/health/discard_queued_jobs", params: { queue_name: "pollers", expected_count: 2, reason: "stale" }, headers: headers
    assert_response :success
    assert_equal 2, JSON.parse(response.body)["affected"]
  ensure
    Rails.cache = original_cache
    GoodJob::Job.delete_all
    GoodJob::Setting.delete_all
    AppSetting.delete_all
  end

  test "the app reads the work backlog and holds a stranded row, and the human-only levers take a grant that acts as you" do
    relay = bearer(token)
    as_you = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    to_pin = backlog_item(key: "zimmer#1")
    to_start = backlog_item(key: "zimmer#2")
    to_remove = backlog_item(key: "zimmer#3")

    get "/api/v1/work_backlog_items", headers: relay
    assert_response :success
    get "/api/v1/work_backlog_items/#{to_pin.id}", headers: relay
    assert_response :success

    # A relay-only grant is refused before the lookup — so with the sentence the
    # app shows, not a 404 — and nothing moves.
    post "/api/v1/work_backlog_items/0/start_now", headers: relay
    assert_response :forbidden
    assert_equal "This sign-in may not act as you; sign in again and allow acting as you", JSON.parse(response.body)["message"]
    patch "/api/v1/work_backlog_items/0/pin", params: { precedence: 10 }, headers: relay
    assert_response :forbidden
    patch "/api/v1/work_backlog_items/0/unpin", headers: relay
    assert_response :forbidden
    post "/api/v1/work_backlog_items/#{to_remove.id}/remove", params: { reason: "no" }, headers: relay
    assert_response :forbidden
    assert to_remove.reload.queued?

    patch "/api/v1/work_backlog_items/#{to_pin.id}/pin", params: { precedence: 10 }, headers: as_you
    assert_response :success
    assert to_pin.reload.pinned?
    patch "/api/v1/work_backlog_items/#{to_pin.id}/unpin", headers: as_you
    assert_response :success
    assert_not to_pin.reload.pinned?
    post "/api/v1/work_backlog_items/#{to_start.id}/start_now", headers: as_you
    assert_response :created
    post "/api/v1/work_backlog_items/#{to_remove.id}/remove", params: { reason: "already fixed upstream" }, headers: as_you
    assert_response :success
    assert_equal "removed", to_remove.reload.status

    # `hold` is not a human-only lever — an agent may hold a row too — so a
    # relay-only grant may.
    sessions(:archived).update!(archived_at: 3.days.ago)
    stranded = backlog_item(key: "zimmer#4")
    stranded.mark_started!(session: sessions(:archived), by: nil, now: 4.days.ago)
    stranded.record_liveness!(WorkBacklogItem::LIVENESS_NO_PR)
    post "/api/v1/work_backlog_items/#{stranded.id}/hold", params: { reason: "pick one" }, headers: relay
    assert_response :success
    assert stranded.reload.held_until.present?
  end

  test "the app reads the gate decision ledger, the outcome analyses and the goal checks" do
    headers = bearer(token)
    decision = GateDecision.create!(gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: "https://github.com/tadasant/zimmer/pull/1", decided_at: Date.new(2026, 8, 15), decision: "auto-merge",
      payload: { "title" => "A change", "reason" => "It was fine." })
    analyzed = sessions(:archived)
    root = { id: "S0", trigger: { kind: "New", source: "user" }, goal: { text: "Ship it", kind: "Action" },
             outcome: { kind: "Success", explanation: "It shipped." }, meta: {}, children: [] }
    post "/api/v1/outcome_analyses", params: { session_id: analyzed.id, root: root }, headers: { "X-API-Key" => API_KEY }, as: :json
    assert_response :created

    get "/api/v1/gate_decisions", headers: headers
    assert_response :success
    get "/api/v1/gate_decisions/#{decision.id}", headers: headers
    assert_response :success
    get "/api/v1/outcome_analyses", headers: headers
    assert_response :success
    get "/api/v1/outcome_analyses/#{analyzed.id}", headers: headers
    assert_response :success
    assert_equal "S0", JSON.parse(response.body).dig("outcome_analysis", "root", "id")
    get "/api/v1/goal_checks", headers: headers
    assert_response :success
  end

  test "the app reads the CLI status and asks for a refresh or a cache clear, as the /clis page does" do
    headers = bearer(token)

    get "/api/v1/clis/status", headers: headers
    assert_response :success
    assert_enqueued_with(job: CliStatusRefreshJob) { post "/api/v1/clis/refresh", headers: headers }
    assert_response :success
    assert_enqueued_with(job: CacheClearJob) { post "/api/v1/clis/clear_cache", headers: headers }
    assert_response :success
  end

  test "the hook and plugin catalogs answer an API key with the catalog's entries" do
    get "/api/v1/hooks", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal HooksConfig.all.map(&:id), JSON.parse(response.body)["hooks"].map { |h| h["id"] }

    get "/api/v1/plugins", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal PluginsConfig.all.map(&:id), JSON.parse(response.body)["plugins"].map { |p| p["id"] }
  end

  test "the app lists a session's open prompts and answers one when it acts on its approver's behalf" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    session = build_zimmer_session(status: :needs_input)
    open_prompt = create_elicitation(session, message: "Send the email?")
    too_late = create_elicitation(session, message: "Too late", expires_at: 1.minute.ago)
    create_elicitation(session, message: "Answered").update!(status: "accept", responded_at: Time.current)

    get "/api/v1/sessions/#{session.id}/elicitations", headers: headers
    assert_response :success
    listed = JSON.parse(response.body)["elicitations"]
    assert_equal [ open_prompt.id ], listed.map { |e| e["id"] }, "only the prompt that can still be answered"
    assert_equal "pending", too_late.reload.status, "a read leaves expiry to the sweep"
    assert_equal %w[to confirmed], listed.first["field_order"]
    assert_equal "boolean", listed.first.dig("requested_schema", "properties", "confirmed", "type")

    patch "/api/v1/elicitations/#{open_prompt.id}/respond", params: { action_type: "accept", content: { confirmed: true } },
      headers: headers, as: :json
    assert_response :success
    assert_equal "accept", open_prompt.reload.status
    assert_equal({ "confirmed" => true }, open_prompt.response_content)
  end

  test "a relay-only app reads a prompt but may not answer it, and never raises or polls one" do
    headers = bearer(token)
    session = build_zimmer_session(status: :needs_input)
    prompt = create_elicitation(session, message: "Send the email?")

    get "/api/v1/sessions/#{session.id}/elicitations", headers: headers
    assert_response :success

    patch "/api/v1/elicitations/#{prompt.id}/respond", params: { action_type: "accept" }, headers: headers
    assert_response :forbidden
    assert_equal "pending", prompt.reload.status

    patch "/api/v1/elicitations/0/respond", params: { action_type: "accept" }, headers: headers
    assert_response :forbidden, "refused before the lookup, so it cannot tell which ids exist"

    get "/api/v1/elicitations/#{prompt.request_id}", headers: headers
    assert_response :unauthorized
    post "/api/v1/elicitations", params: { message: "forged", _meta: { "com.pulsemcp/request-id" => "r" } }, headers: headers
    assert_response :unauthorized
  end

  test "a session's open prompts answer an API key too, and an unknown session is a 404" do
    session = build_zimmer_session(status: :needs_input)
    prompt = create_elicitation(session, message: "Send the email?")

    get "/api/v1/sessions/#{session.id}/elicitations", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal [ prompt.id ], JSON.parse(response.body)["elicitations"].map { |e| e["id"] }

    get "/api/v1/sessions/0/elicitations", headers: { "X-API-Key" => API_KEY }
    assert_response :not_found
  end

  test "a controller the app does not use refuses its token outright" do
    get "/api/v1/external_app/triggers", headers: bearer(token)
    assert_response :unauthorized
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def token(privilege: OauthServer::RELAY_ONLY)
    verifier, challenge = pkce
    post "/oauth/authorize", params: { response_type: "code", client_id: CLIENT_ID, redirect_uri: REDIRECT,
      code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: RESOURCE, scope: "mcp",
      decision: "approve", privilege: privilege }
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: REDIRECT, resource: RESOURCE }
    assert_response :success
    JSON.parse(response.body).fetch("access_token")
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }

  def enqueue_good_job(job_class: "CanaryJob", queue_name: "pollers")
    id = SecureRandom.uuid
    GoodJob::Job.create!(
      id: id, active_job_id: id, job_class: job_class, queue_name: queue_name, priority: 0, scheduled_at: Time.current,
      serialized_params: { "job_class" => job_class, "job_id" => id, "queue_name" => queue_name, "priority" => 0,
                           "arguments" => [], "executions" => 0, "locale" => "en" }
    )
  end

  def create_elicitation(session, message:, expires_at: 10.minutes.from_now)
    Elicitation.create!(session: session, request_id: "req-#{SecureRandom.hex(6)}", mode: "form", message: message,
      requested_schema: { type: "object", properties: { to: { type: "string" }, confirmed: { type: "boolean" } } },
      expires_at: expires_at)
  end

  def build_zimmer_session(**attrs)
    Session.create!({ git_root: "https://github.com/tadasant/zimmer.git", branch: "main", prompt: "p" }.merge(attrs))
  end
end
