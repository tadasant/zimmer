# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_22_174500) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "account_rotation_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "reason"
    t.string "rotated_from_email"
    t.bigint "rotated_from_id"
    t.string "rotated_to_email"
    t.bigint "rotated_to_id"
    t.string "runtime"
    t.string "source", null: false
    t.string "triggered_by"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_account_rotation_events_on_created_at", order: :desc
    t.index ["runtime", "created_at"], name: "index_account_rotation_events_on_runtime_and_created_at"
    t.index ["source"], name: "index_account_rotation_events_on_source"
  end

  create_table "adhoc_token_usages", force: :cascade do |t|
    t.bigint "cache_creation_1h_tokens", default: 0, null: false
    t.bigint "cache_creation_5m_tokens", default: 0, null: false
    t.bigint "cache_creation_tokens", default: 0, null: false
    t.bigint "cache_read_tokens", default: 0, null: false
    t.datetime "called_at", null: false
    t.datetime "created_at", null: false
    t.bigint "input_tokens", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "model", null: false
    t.bigint "output_tokens", default: 0, null: false
    t.string "request_id", null: false
    t.string "service_tier"
    t.string "source", default: "unknown", null: false
    t.bigint "subject_session_id"
    t.string "transcript_path"
    t.datetime "updated_at", null: false
    t.integer "web_fetch_requests", default: 0, null: false
    t.integer "web_search_requests", default: 0, null: false
    t.index ["called_at"], name: "index_adhoc_token_usages_on_called_at"
    t.index ["request_id"], name: "index_adhoc_token_usages_on_request_id", unique: true
    t.index ["source", "called_at"], name: "index_adhoc_token_usages_on_source_and_called_at"
    t.index ["subject_session_id"], name: "index_adhoc_token_usages_on_subject_session_id"
  end

  create_table "agent_posted_github_comments", force: :cascade do |t|
    t.bigint "comment_id", null: false
    t.string "comment_type", null: false
    t.string "comment_url"
    t.datetime "created_at", null: false
    t.string "pr_url"
    t.bigint "session_id"
    t.datetime "updated_at", null: false
    t.index ["comment_type", "comment_id"], name: "index_agent_posted_github_comments_on_type_and_comment_id", unique: true
    t.index ["session_id"], name: "index_agent_posted_github_comments_on_session_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_model"
    t.string "default_runtime"
    t.jsonb "extension_states", default: {}, null: false
    t.jsonb "genesis_class_overrides", default: {}, null: false
    t.boolean "mcp_tool_search_enabled", default: true, null: false
    t.jsonb "queue_recovery_mode", default: {}, null: false
    t.boolean "quota_pool_available"
    t.datetime "quota_pool_available_changed_at"
    t.integer "spot_gate_five_hour_threshold_pct", default: 80, null: false
    t.integer "spot_gate_weekly_threshold_pct", default: 80, null: false
    t.boolean "spot_gating_enabled", default: false, null: false
    t.integer "spot_max_concurrent_sessions", default: 10, null: false
    t.integer "uncategorized_position", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "catalog_pins", force: :cascade do |t|
    t.string "catalog", null: false
    t.datetime "created_at", null: false
    t.string "ref", null: false
    t.datetime "updated_at", null: false
    t.index ["catalog"], name: "index_catalog_pins_on_catalog", unique: true
  end

  create_table "catalog_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "entries", null: false
    t.datetime "resolved_at", null: false
    t.datetime "updated_at", null: false
    t.index ["resolved_at"], name: "index_catalog_snapshots_on_resolved_at"
  end

  create_table "categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "is_frozen", default: false, null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["position"], name: "index_categories_on_position"
  end

  create_table "claude_account_quota_snapshots", force: :cascade do |t|
    t.string "account_email"
    t.string "account_runtime"
    t.integer "active_session_count"
    t.bigint "claude_account_id"
    t.datetime "created_at", null: false
    t.string "overage_disabled_reason"
    t.string "overage_status"
    t.string "rate_limit_tier"
    t.datetime "reset_5h"
    t.datetime "reset_7d"
    t.string "status_5h"
    t.string "status_7d"
    t.string "subscription_type"
    t.string "trigger"
    t.datetime "updated_at", null: false
    t.float "utilization_5h"
    t.float "utilization_7d"
    t.index ["claude_account_id", "created_at"], name: "idx_quota_snapshots_account_time"
    t.index ["claude_account_id"], name: "index_claude_account_quota_snapshots_on_claude_account_id"
  end

  create_table "claude_accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.boolean "is_current", default: false, null: false
    t.datetime "last_rotated_to_at"
    t.datetime "last_stale_refresh_failure_at"
    t.jsonb "oauth_config", default: {}
    t.integer "priority", default: 0, null: false
    t.integer "quota_hit_count", default: 0, null: false
    t.datetime "reauth_alerted_at"
    t.string "runtime", default: "claude_code", null: false
    t.integer "stale_refresh_failures", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email", "runtime"], name: "index_claude_accounts_on_email_and_runtime", unique: true
    t.index ["is_current"], name: "index_claude_accounts_on_is_current"
    t.index ["runtime"], name: "index_claude_accounts_on_runtime"
    t.index ["status", "priority"], name: "index_claude_accounts_on_status_and_priority"
  end

  create_table "elicitations", force: :cascade do |t|
    t.text "context"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "mcp_session_id"
    t.text "message", null: false
    t.jsonb "meta", default: {}
    t.string "mode", null: false
    t.string "request_id", null: false
    t.jsonb "requested_schema", default: {}, null: false
    t.datetime "responded_at"
    t.jsonb "response_content"
    t.bigint "session_id", null: false
    t.string "status", default: "pending", null: false
    t.string "tool_name"
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_elicitations_on_expires_at"
    t.index ["request_id"], name: "index_elicitations_on_request_id", unique: true
    t.index ["session_id", "status"], name: "index_elicitations_on_session_id_and_status"
    t.index ["session_id"], name: "index_elicitations_on_session_id"
  end

  create_table "enqueued_messages", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.jsonb "files", default: [], null: false
    t.text "goal"
    t.jsonb "images", default: [], null: false
    t.string "origin", default: "caller", null: false
    t.integer "position", null: false
    t.bigint "session_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id", "status"], name: "index_enqueued_messages_on_session_id_and_status"
    t.unique_constraint ["session_id", "position"], deferrable: :deferred, name: "index_enqueued_messages_on_session_id_and_position"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at", where: "((retried_good_job_id IS NULL) AND (finished_at IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "human_messages", force: :cascade do |t|
    t.string "author", null: false
    t.string "channel", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "provenance", default: {}, null: false
    t.bigint "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id", "occurred_at", "id"], name: "index_human_messages_on_session_id_and_occurred_at_and_id"
  end

  create_table "logs", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.string "level"
    t.integer "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["level"], name: "index_logs_on_level"
    t.index ["session_id", "created_at"], name: "index_logs_on_session_id_and_created_at"
    t.index ["session_id"], name: "index_logs_on_session_id"
  end

  create_table "mcp_oauth_credentials", force: :cascade do |t|
    t.text "access_token", null: false
    t.string "client_id", null: false
    t.string "client_secret"
    t.datetime "created_at", null: false
    t.string "credential_key", null: false
    t.datetime "expires_at"
    t.text "refresh_token"
    t.boolean "refresh_token_unsupported", default: false, null: false
    t.string "resource"
    t.string "scopes"
    t.string "server_name", null: false
    t.string "server_url", null: false
    t.string "token_endpoint"
    t.datetime "updated_at", null: false
    t.index ["credential_key"], name: "index_mcp_oauth_credentials_on_credential_key", unique: true
    t.index ["server_name", "server_url"], name: "index_mcp_oauth_credentials_on_server_name_and_server_url", unique: true
  end

  create_table "mcp_oauth_pending_flows", force: :cascade do |t|
    t.string "authorization_endpoint", null: false
    t.string "client_id", null: false
    t.string "client_secret"
    t.string "code_verifier", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.boolean "manual", default: false, null: false
    t.jsonb "mcp_server_config", null: false
    t.string "redirect_uri", null: false
    t.string "registration_endpoint"
    t.string "resource"
    t.string "scopes"
    t.string "server_name", null: false
    t.string "server_url", null: false
    t.bigint "session_id"
    t.string "state", null: false
    t.string "token_endpoint", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_mcp_oauth_pending_flows_on_expires_at"
    t.index ["session_id", "server_name"], name: "index_mcp_oauth_pending_flows_on_session_id_and_server_name", unique: true
    t.index ["session_id"], name: "index_mcp_oauth_pending_flows_on_session_id"
    t.index ["state"], name: "index_mcp_oauth_pending_flows_on_state", unique: true
  end

  create_table "notifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "notification_type", null: false
    t.boolean "read", default: false, null: false
    t.bigint "session_id", null: false
    t.boolean "stale", default: false, null: false
    t.integer "transition_marker"
    t.datetime "updated_at", null: false
    t.index ["read"], name: "index_notifications_on_read"
    t.index ["session_id", "notification_type", "transition_marker"], name: "idx_notifications_unique_transition", unique: true, where: "(transition_marker IS NOT NULL)"
    t.index ["session_id", "stale"], name: "index_notifications_on_session_id_and_stale"
    t.index ["session_id"], name: "index_notifications_on_session_id"
    t.index ["stale"], name: "index_notifications_on_stale"
  end

  create_table "outcome_analyses", force: :cascade do |t|
    t.string "agent_root"
    t.string "agent_runtime", null: false
    t.datetime "analyzed_at", null: false
    t.bigint "analyzer_session_id"
    t.datetime "created_at", null: false
    t.integer "failure_segment_count", default: 0, null: false
    t.integer "max_depth", default: 0, null: false
    t.string "model"
    t.text "notes"
    t.jsonb "root", null: false
    t.string "root_outcome", null: false
    t.string "schema_version", default: "1", null: false
    t.integer "segment_count", default: 0, null: false
    t.datetime "session_created_at", null: false
    t.bigint "session_id", null: false
    t.datetime "superseded_at"
    t.datetime "updated_at", null: false
    t.index ["analyzer_session_id"], name: "index_outcome_analyses_on_analyzer_session_id", where: "(analyzer_session_id IS NOT NULL)"
    t.index ["session_created_at", "agent_runtime", "model", "agent_root"], name: "index_outcome_analyses_stats", where: "(superseded_at IS NULL)"
    t.index ["session_id", "analyzed_at"], name: "index_outcome_analyses_on_session_and_analyzed_at"
    t.index ["session_id"], name: "index_outcome_analyses_current_per_session", unique: true, where: "(superseded_at IS NULL)"
  end

  create_table "outcome_analysis_batch_items", force: :cascade do |t|
    t.bigint "analysis_session_id"
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.bigint "outcome_analysis_batch_id", null: false
    t.integer "position", default: 0, null: false
    t.bigint "session_id", null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["analysis_session_id"], name: "index_outcome_analysis_batch_items_on_analysis_session_id", where: "(analysis_session_id IS NOT NULL)"
    t.index ["outcome_analysis_batch_id", "session_id"], name: "index_outcome_batch_items_on_batch_session", unique: true
    t.index ["outcome_analysis_batch_id", "state", "position"], name: "index_outcome_batch_items_on_batch_state_position"
  end

  create_table "outcome_analysis_batches", force: :cascade do |t|
    t.integer "concurrency", default: 1, null: false
    t.datetime "created_at", null: false
    t.jsonb "filters", default: {}, null: false
    t.datetime "finished_at"
    t.string "status", default: "running", null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["status", "id"], name: "index_outcome_analysis_batches_on_status_and_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key", null: false
    t.datetime "created_at", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
  end

  create_table "runtime_login_attempts", force: :cascade do |t|
    t.string "account_email"
    t.bigint "claude_account_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "expires_at", null: false
    t.datetime "heartbeat_at"
    t.string "pasted_code"
    t.integer "pid"
    t.string "runtime", null: false
    t.string "status", default: "starting", null: false
    t.datetime "updated_at", null: false
    t.string "verification_code"
    t.string "verification_url"
    t.index ["claude_account_id", "created_at"], name: "idx_on_claude_account_id_created_at_edf6f8e6f6"
    t.index ["claude_account_id"], name: "index_runtime_login_attempts_on_claude_account_id"
    t.index ["status"], name: "index_runtime_login_attempts_on_status"
  end

  create_table "session_experimental_flags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "first_observed_at"
    t.datetime "last_observed_at"
    t.bigint "session_id", null: false
    t.string "setting_key", null: false
    t.string "source", default: "observed", null: false
    t.datetime "updated_at", null: false
    t.boolean "value_at_end"
    t.boolean "value_at_start"
    t.index ["session_id", "setting_key"], name: "index_session_experimental_flags_on_session_and_key", unique: true
    t.index ["setting_key", "source"], name: "index_session_experimental_flags_on_key_and_source"
  end

  create_table "session_status_summaries", force: :cascade do |t|
    t.datetime "backstop_attempted_at"
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "fork_session_id"
    t.datetime "generated_at"
    t.datetime "requested_at"
    t.integer "requested_line_count"
    t.bigint "session_id", null: false
    t.string "state", default: "idle", null: false
    t.text "summary"
    t.integer "transcript_line_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["fork_session_id"], name: "index_session_status_summaries_on_fork_session_id"
    t.index ["session_id"], name: "index_session_status_summaries_on_session_id", unique: true
  end

  create_table "session_token_usages", force: :cascade do |t|
    t.string "agent_root"
    t.string "agent_runtime", default: "claude_code", null: false
    t.bigint "cache_creation_1h_tokens", default: 0, null: false
    t.bigint "cache_creation_5m_tokens", default: 0, null: false
    t.bigint "cache_creation_tokens", default: 0, null: false
    t.bigint "cache_read_tokens", default: 0, null: false
    t.datetime "called_at", null: false
    t.datetime "created_at", null: false
    t.bigint "input_tokens", default: 0, null: false
    t.string "model", null: false
    t.bigint "output_tokens", default: 0, null: false
    t.string "request_id", null: false
    t.string "runtime_session_id"
    t.string "service_tier"
    t.bigint "session_id"
    t.boolean "subagent", default: false, null: false
    t.string "transcript_path"
    t.datetime "updated_at", null: false
    t.integer "web_fetch_requests", default: 0, null: false
    t.integer "web_search_requests", default: 0, null: false
    t.index ["agent_root", "called_at"], name: "index_session_token_usages_on_agent_root_and_called_at"
    t.index ["called_at"], name: "index_session_token_usages_on_called_at"
    t.index ["model"], name: "index_session_token_usages_on_model"
    t.index ["request_id"], name: "index_session_token_usages_on_request_id", unique: true
    t.index ["session_id", "called_at"], name: "index_session_token_usages_on_session_id_and_called_at"
    t.index ["session_id"], name: "index_session_token_usages_on_session_id"
  end

  create_table "session_uncle_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "session_id", null: false
    t.string "source"
    t.bigint "uncle_session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id", "uncle_session_id"], name: "index_session_uncle_links_on_pair", unique: true
    t.index ["uncle_session_id"], name: "index_session_uncle_links_on_uncle_session_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.string "agent_runtime", default: "claude_code", null: false
    t.datetime "archived_at"
    t.integer "auto_compact_window", default: 1000000, null: false
    t.string "branch", default: "main", null: false
    t.jsonb "catalog_hooks", default: []
    t.jsonb "catalog_plugins", default: []
    t.jsonb "catalog_skills", default: []
    t.bigint "category_id"
    t.json "config"
    t.datetime "created_at", null: false
    t.jsonb "custom_metadata", default: {}
    t.string "execution_provider", default: "local_filesystem", null: false
    t.boolean "favorited", default: false, null: false
    t.string "genesis"
    t.string "git_root"
    t.text "goal"
    t.boolean "heartbeat_enabled", default: false, null: false
    t.integer "heartbeat_interval_seconds", default: 60, null: false
    t.datetime "heartbeat_last_beat_at"
    t.boolean "is_autonomous", default: true, null: false
    t.string "job_id"
    t.datetime "last_broadcast_to_index_at"
    t.datetime "last_timeline_entry_at"
    t.json "mcp_server_env"
    t.json "mcp_server_headers"
    t.json "mcp_servers"
    t.json "metadata", default: {}
    t.bigint "parent_session_id"
    t.integer "precedence", default: 0, null: false
    t.text "prompt"
    t.boolean "push_notifications_enabled", default: false, null: false
    t.string "repository_name"
    t.string "running_job_id"
    t.string "scheduling_class"
    t.string "session_id"
    t.text "session_notes"
    t.datetime "session_notes_updated_at"
    t.string "slug"
    t.integer "sort_order", default: 0, null: false
    t.integer "status", default: 1
    t.string "subdirectory"
    t.string "title"
    t.json "transcript"
    t.datetime "trash_after"
    t.datetime "updated_at", null: false
    t.index "((config ->> 'model'::text))", name: "index_sessions_on_config_model"
    t.index "((custom_metadata ->> 'github_pull_request_urls'::text))", name: "index_sessions_on_custom_metadata_pr_urls", where: "((custom_metadata ->> 'github_pull_request_urls'::text) IS NOT NULL)"
    t.index "((custom_metadata ->> 'router_session_id'::text))", name: "index_sessions_on_router_session_id"
    t.index "((metadata ->> 'agent_root_key'::text))", name: "index_sessions_on_agent_root_key"
    t.index "status, ((metadata ->> 'clone_path'::text))", name: "index_sessions_on_status_clone_path_expression", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["agent_runtime"], name: "index_sessions_on_agent_runtime"
    t.index ["category_id"], name: "index_sessions_on_category_id"
    t.index ["created_at"], name: "index_sessions_on_created_at"
    t.index ["execution_provider"], name: "index_sessions_on_execution_provider"
    t.index ["favorited"], name: "index_sessions_on_favorited"
    t.index ["genesis"], name: "index_sessions_on_genesis"
    t.index ["heartbeat_enabled"], name: "index_sessions_on_heartbeat_enabled", where: "heartbeat_enabled"
    t.index ["id"], name: "index_sessions_on_id_where_transcript_present", where: "(transcript IS NOT NULL)"
    t.index ["id"], name: "index_sessions_on_pr_url_active_id", where: "((status <> ALL (ARRAY[3, 4])) AND ((custom_metadata ->> 'github_pull_request_urls'::text) IS NOT NULL))"
    t.index ["job_id"], name: "index_sessions_on_job_id"
    t.index ["parent_session_id"], name: "index_sessions_on_parent_session_id"
    t.index ["precedence", "created_at", "id"], name: "index_sessions_on_precedence_ranked", order: { precedence: :desc }, where: "(status <> 3)"
    t.index ["scheduling_class"], name: "index_sessions_on_scheduling_class", where: "(scheduling_class IS NOT NULL)"
    t.index ["session_id"], name: "index_sessions_on_session_id", unique: true
    t.index ["slug"], name: "index_sessions_on_slug", unique: true
    t.index ["sort_order"], name: "index_sessions_on_sort_order"
    t.index ["status", "archived_at", "id"], name: "index_sessions_on_archived_stale_clone_candidates", where: "((trash_after IS NULL) AND (archived_at IS NOT NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))"
    t.index ["status", "trash_after"], name: "index_sessions_on_status_trash_after_with_clone_path", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["status", "updated_at", "id"], name: "index_sessions_on_failed_stale_clone_candidates", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["status", "updated_at", "id"], name: "index_sessions_on_legacy_archived_stale_clone_candidates", where: "((trash_after IS NULL) AND (archived_at IS NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))"
    t.index ["status"], name: "index_sessions_on_status"
    t.index ["trash_after"], name: "index_sessions_on_trash_after", where: "(trash_after IS NOT NULL)"
  end

  create_table "subagent_transcripts", force: :cascade do |t|
    t.string "agent_id", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.integer "duration_ms"
    t.string "filename"
    t.integer "message_count", default: 0
    t.bigint "session_id", null: false
    t.string "status", default: "running"
    t.string "subagent_type"
    t.integer "tool_use_count"
    t.string "tool_use_id"
    t.integer "total_tokens"
    t.text "transcript"
    t.datetime "updated_at", null: false
    t.index ["session_id", "agent_id"], name: "index_subagent_transcripts_on_session_id_and_agent_id", unique: true
    t.index ["session_id"], name: "index_subagent_transcripts_on_session_id"
    t.index ["tool_use_id"], name: "index_subagent_transcripts_on_tool_use_id"
  end

  create_table "token_usage_backfills", force: :cascade do |t|
    t.bigint "adhoc_rows", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "cursor"
    t.integer "directories_done", default: 0, null: false
    t.integer "directories_total", default: 0, null: false
    t.bigint "files_scanned", default: 0, null: false
    t.datetime "finished_at"
    t.text "last_error"
    t.datetime "last_ran_at"
    t.bigint "session_rows", default: 0, null: false
    t.datetime "started_at"
    t.string "transcript_root", null: false
    t.string "trigger", default: "automatic", null: false
    t.datetime "updated_at", null: false
    t.index "((finished_at IS NULL))", name: "index_token_usage_backfills_one_unfinished", unique: true, where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_token_usage_backfills_on_created_at"
    t.index ["finished_at"], name: "index_token_usage_backfills_on_finished_at"
  end

  create_table "token_usage_features", force: :cascade do |t|
    t.string "agent_root"
    t.bigint "cache_creation_1h_tokens", default: 0, null: false
    t.bigint "cache_creation_5m_tokens", default: 0, null: false
    t.bigint "cache_creation_tokens", default: 0, null: false
    t.bigint "cache_read_tokens", default: 0, null: false
    t.datetime "called_at", null: false
    t.bigint "chars", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "feature", null: false
    t.bigint "input_tokens", default: 0, null: false
    t.string "model", null: false
    t.integer "occurrences", default: 0, null: false
    t.bigint "output_tokens", default: 0, null: false
    t.string "request_id", null: false
    t.bigint "session_id"
    t.boolean "subagent", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_root", "called_at"], name: "index_token_usage_features_on_agent_root_and_called_at"
    t.index ["called_at"], name: "index_token_usage_features_on_called_at"
    t.index ["feature", "called_at"], name: "index_token_usage_features_on_feature_and_called_at"
    t.index ["request_id", "feature"], name: "index_token_usage_features_on_request_id_and_feature", unique: true
    t.index ["session_id", "called_at"], name: "index_token_usage_features_on_session_id_and_called_at"
  end

  create_table "trigger_conditions", force: :cascade do |t|
    t.string "condition_type", null: false
    t.jsonb "configuration", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "last_message_ts"
    t.datetime "last_polled_at"
    t.datetime "last_triggered_at"
    t.bigint "trigger_id", null: false
    t.datetime "updated_at", null: false
    t.index ["condition_type"], name: "index_trigger_conditions_on_condition_type"
    t.index ["trigger_id"], name: "index_trigger_conditions_on_trigger_id"
  end

  create_table "triggers", force: :cascade do |t|
    t.string "agent_root_name", null: false
    t.datetime "burst_active_until"
    t.integer "burst_window_count", default: 0, null: false
    t.jsonb "burst_window_session_ids", default: [], null: false
    t.datetime "burst_window_started_at"
    t.jsonb "catalog_hooks", default: [], null: false
    t.jsonb "catalog_plugins", default: [], null: false
    t.jsonb "catalog_skills", default: [], null: false
    t.datetime "created_at", null: false
    t.boolean "enqueue_messages", default: false, null: false
    t.datetime "failed_at"
    t.text "goal"
    t.text "last_error"
    t.bigint "last_session_id"
    t.datetime "last_triggered_at"
    t.integer "max_sessions_per_minute"
    t.jsonb "mcp_servers", default: [], null: false
    t.string "name", null: false
    t.integer "precedence"
    t.text "prompt_template", null: false
    t.boolean "resuscitate_archived", default: false, null: false
    t.boolean "reuse_session", default: false, null: false
    t.string "scheduling_class"
    t.integer "sessions_created_count", default: 0
    t.string "status", default: "enabled", null: false
    t.datetime "updated_at", null: false
    t.index ["last_session_id"], name: "index_triggers_on_last_session_id"
    t.index ["status"], name: "index_triggers_on_status"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email"
    t.string "key", null: false
    t.text "notes"
    t.string "slack_user_ids", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["key"], name: "index_users_on_key", unique: true
    t.index ["slack_user_ids"], name: "index_users_on_slack_user_ids", using: :gin
  end

  create_table "x_oauth_credentials", force: :cascade do |t|
    t.text "access_token"
    t.string "access_token_env_var", null: false
    t.string "account_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_refresh_attempted_at"
    t.string "last_refresh_error"
    t.datetime "last_refreshed_at"
    t.text "refresh_token"
    t.string "scopes"
    t.string "token_endpoint", default: "https://api.x.com/2/oauth2/token", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token_env_var"], name: "index_x_oauth_credentials_on_access_token_env_var", unique: true
    t.index ["account_key"], name: "index_x_oauth_credentials_on_account_key", unique: true
  end

  add_foreign_key "account_rotation_events", "claude_accounts", column: "rotated_from_id", on_delete: :nullify
  add_foreign_key "account_rotation_events", "claude_accounts", column: "rotated_to_id", on_delete: :nullify
  add_foreign_key "agent_posted_github_comments", "sessions", on_delete: :nullify
  add_foreign_key "claude_account_quota_snapshots", "claude_accounts", on_delete: :nullify
  add_foreign_key "elicitations", "sessions", on_delete: :cascade
  add_foreign_key "enqueued_messages", "sessions", on_delete: :cascade
  add_foreign_key "human_messages", "sessions", on_delete: :cascade
  add_foreign_key "logs", "sessions", on_delete: :cascade
  add_foreign_key "mcp_oauth_pending_flows", "sessions", on_delete: :cascade
  add_foreign_key "notifications", "sessions", on_delete: :cascade
  add_foreign_key "outcome_analyses", "sessions", column: "analyzer_session_id", on_delete: :nullify
  add_foreign_key "outcome_analyses", "sessions", on_delete: :cascade
  add_foreign_key "outcome_analysis_batch_items", "outcome_analysis_batches", on_delete: :cascade
  add_foreign_key "outcome_analysis_batch_items", "sessions", column: "analysis_session_id", on_delete: :nullify
  add_foreign_key "outcome_analysis_batch_items", "sessions", on_delete: :cascade
  add_foreign_key "runtime_login_attempts", "claude_accounts", on_delete: :nullify
  add_foreign_key "session_experimental_flags", "sessions", on_delete: :cascade
  add_foreign_key "session_status_summaries", "sessions", column: "fork_session_id", on_delete: :nullify
  add_foreign_key "session_status_summaries", "sessions", on_delete: :cascade
  add_foreign_key "session_token_usages", "sessions", on_delete: :nullify
  add_foreign_key "session_uncle_links", "sessions", column: "uncle_session_id", on_delete: :cascade
  add_foreign_key "session_uncle_links", "sessions", on_delete: :cascade
  add_foreign_key "sessions", "categories", on_delete: :nullify
  add_foreign_key "sessions", "sessions", column: "parent_session_id", on_delete: :nullify
  add_foreign_key "subagent_transcripts", "sessions", on_delete: :cascade
  add_foreign_key "token_usage_features", "session_token_usages", column: "request_id", primary_key: "request_id", on_delete: :cascade
  add_foreign_key "token_usage_features", "sessions", on_delete: :nullify
  add_foreign_key "trigger_conditions", "triggers"
end
