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

ActiveRecord::Schema[8.0].define(version: 2026_07_04_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "elicitations", force: :cascade do |t|
    t.bigint "session_id", null: false
    t.string "request_id", null: false
    t.string "status", default: "pending", null: false
    t.string "mode", null: false
    t.text "message", null: false
    t.jsonb "requested_schema", default: {}, null: false
    t.jsonb "meta", default: {}
    t.string "tool_name"
    t.text "context"
    t.string "mcp_session_id"
    t.datetime "expires_at"
    t.jsonb "response_content"
    t.datetime "responded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_elicitations_on_expires_at"
    t.index ["request_id"], name: "index_elicitations_on_request_id", unique: true
    t.index ["session_id", "status"], name: "index_elicitations_on_session_id_and_status"
    t.index ["session_id"], name: "index_elicitations_on_session_id"
  end

  create_table "enqueued_messages", force: :cascade do |t|
    t.bigint "session_id", null: false
    t.text "content", null: false
    t.text "goal"
    t.integer "position", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "images", default: [], null: false
    t.jsonb "files", default: [], null: false
    t.index ["session_id", "position"], name: "index_enqueued_messages_on_session_id_and_position", unique: true
    t.index ["session_id", "status"], name: "index_enqueued_messages_on_session_id_and_status"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
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

  create_table "logs", force: :cascade do |t|
    t.integer "session_id", null: false
    t.text "content"
    t.string "level"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["level"], name: "index_logs_on_level"
    t.index ["session_id", "created_at"], name: "index_logs_on_session_id_and_created_at"
    t.index ["session_id"], name: "index_logs_on_session_id"
  end

  create_table "mcp_oauth_credentials", force: :cascade do |t|
    t.string "server_name", null: false
    t.string "server_url", null: false
    t.string "credential_key", null: false
    t.string "client_id", null: false
    t.string "client_secret"
    t.text "access_token", null: false
    t.text "refresh_token"
    t.datetime "expires_at"
    t.string "scopes"
    t.string "token_endpoint"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "resource"
    t.index ["credential_key"], name: "index_mcp_oauth_credentials_on_credential_key", unique: true
    t.index ["server_name", "server_url"], name: "index_mcp_oauth_credentials_on_server_name_and_server_url", unique: true
  end

  create_table "mcp_oauth_pending_flows", force: :cascade do |t|
    t.bigint "session_id", null: false
    t.string "server_name", null: false
    t.string "server_url", null: false
    t.string "state", null: false
    t.string "code_verifier", null: false
    t.string "authorization_endpoint", null: false
    t.string "token_endpoint", null: false
    t.string "registration_endpoint"
    t.string "client_id", null: false
    t.string "client_secret"
    t.string "redirect_uri", null: false
    t.string "scopes"
    t.jsonb "mcp_server_config", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "resource"
    t.index ["expires_at"], name: "index_mcp_oauth_pending_flows_on_expires_at"
    t.index ["session_id", "server_name"], name: "index_mcp_oauth_pending_flows_on_session_id_and_server_name", unique: true
    t.index ["session_id"], name: "index_mcp_oauth_pending_flows_on_session_id"
    t.index ["state"], name: "index_mcp_oauth_pending_flows_on_state", unique: true
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "session_id", null: false
    t.string "notification_type", null: false
    t.boolean "read", default: false, null: false
    t.boolean "stale", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "transition_marker"
    t.index ["read"], name: "index_notifications_on_read"
    t.index ["session_id", "notification_type", "transition_marker"], name: "idx_notifications_unique_transition", unique: true, where: "(transition_marker IS NOT NULL)"
    t.index ["session_id", "stale"], name: "index_notifications_on_session_id_and_stale"
    t.index ["session_id"], name: "index_notifications_on_session_id"
    t.index ["stale"], name: "index_notifications_on_stale"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.string "auth_key", null: false
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
  end

  create_table "runtime_login_attempts", force: :cascade do |t|
    t.bigint "claude_account_id", null: false
    t.string "runtime", null: false
    t.string "status", default: "starting", null: false
    t.string "verification_url"
    t.string "verification_code"
    t.string "pasted_code"
    t.text "error_message"
    t.integer "pid"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["claude_account_id", "created_at"], name: "idx_on_claude_account_id_created_at_edf6f8e6f6"
    t.index ["claude_account_id"], name: "index_runtime_login_attempts_on_claude_account_id"
    t.index ["status"], name: "index_runtime_login_attempts_on_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.string "agent_runtime", default: "claude_code", null: false
    t.integer "status", default: 1
    t.json "config"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "prompt"
    t.json "mcp_servers"
    t.string "git_root"
    t.string "branch", default: "main", null: false
    t.string "execution_provider", default: "local_filesystem", null: false
    t.json "mcp_server_env"
    t.json "mcp_server_headers"
    t.json "transcript"
    t.string "session_id"
    t.json "metadata", default: {}
    t.string "job_id"
    t.string "title"
    t.string "repository_name"
    t.datetime "archived_at"
    t.string "subdirectory"
    t.string "slug"
    t.string "running_job_id"
    t.text "goal"
    t.datetime "last_timeline_entry_at"
    t.datetime "last_broadcast_to_index_at"
    t.jsonb "custom_metadata", default: {}
    t.boolean "favorited", default: false, null: false
    t.boolean "is_autonomous", default: true, null: false
    t.text "session_notes"
    t.datetime "session_notes_updated_at"
    t.jsonb "catalog_skills", default: []
    t.jsonb "catalog_hooks", default: []
    t.jsonb "catalog_plugins", default: []
    t.datetime "trash_after"
    t.bigint "parent_session_id"
    t.bigint "blocked_by_session_id"
    t.integer "sort_order", default: 0, null: false
    t.boolean "push_notifications_enabled", default: false, null: false
    t.integer "auto_compact_window", default: 200000, null: false
    t.bigint "category_id"
    t.index "((custom_metadata ->> 'github_pull_request_urls'::text))", name: "index_sessions_on_custom_metadata_pr_urls", where: "((custom_metadata ->> 'github_pull_request_urls'::text) IS NOT NULL)"
    t.index ["agent_runtime"], name: "index_sessions_on_agent_runtime"
    t.index ["id"], name: "index_sessions_on_id_where_transcript_present", where: "(transcript IS NOT NULL)"
    t.index ["id"], name: "index_sessions_on_pr_url_active_id", where: "((status <> ALL (ARRAY[3, 4])) AND ((custom_metadata ->> 'github_pull_request_urls'::text) IS NOT NULL))"
    t.index ["status", "archived_at", "id"], name: "index_sessions_on_archived_stale_clone_candidates", where: "((trash_after IS NULL) AND (archived_at IS NOT NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))"
    t.index ["status", "updated_at", "id"], name: "index_sessions_on_failed_stale_clone_candidates", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["status", "updated_at", "id"], name: "index_sessions_on_legacy_archived_stale_clone_candidates", where: "((trash_after IS NULL) AND (archived_at IS NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))"
    t.index ["blocked_by_session_id"], name: "index_sessions_on_blocked_by_session_id"
    t.index ["category_id"], name: "index_sessions_on_category_id"
    t.index ["created_at"], name: "index_sessions_on_created_at"
    t.index ["execution_provider"], name: "index_sessions_on_execution_provider"
    t.index ["favorited"], name: "index_sessions_on_favorited"
    t.index ["parent_session_id"], name: "index_sessions_on_parent_session_id"
    t.index ["job_id"], name: "index_sessions_on_job_id"
    t.index ["session_id"], name: "index_sessions_on_session_id", unique: true
    t.index ["slug"], name: "index_sessions_on_slug", unique: true
    t.index ["sort_order"], name: "index_sessions_on_sort_order"
    t.index ["status"], name: "index_sessions_on_status"
    t.index "status, ((metadata ->> 'clone_path'::text))", name: "index_sessions_on_status_clone_path_expression", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["status", "trash_after"], name: "index_sessions_on_status_trash_after_with_clone_path", where: "((metadata ->> 'clone_path'::text) IS NOT NULL)"
    t.index ["trash_after"], name: "index_sessions_on_trash_after", where: "(trash_after IS NOT NULL)"
  end

  create_table "subagent_transcripts", force: :cascade do |t|
    t.bigint "session_id", null: false
    t.string "agent_id", null: false
    t.text "transcript"
    t.string "filename"
    t.integer "message_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tool_use_id"
    t.string "subagent_type"
    t.string "description"
    t.string "status", default: "running"
    t.integer "duration_ms"
    t.integer "total_tokens"
    t.integer "tool_use_count"
    t.index ["session_id", "agent_id"], name: "index_subagent_transcripts_on_session_id_and_agent_id", unique: true
    t.index ["session_id"], name: "index_subagent_transcripts_on_session_id"
    t.index ["tool_use_id"], name: "index_subagent_transcripts_on_tool_use_id"
  end

  create_table "trigger_conditions", force: :cascade do |t|
    t.bigint "trigger_id", null: false
    t.string "condition_type", null: false
    t.jsonb "configuration", default: {}, null: false
    t.datetime "last_polled_at"
    t.datetime "last_triggered_at"
    t.string "last_message_ts"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["condition_type"], name: "index_trigger_conditions_on_condition_type"
    t.index ["trigger_id"], name: "index_trigger_conditions_on_trigger_id"
  end

  create_table "triggers", force: :cascade do |t|
    t.string "name", null: false
    t.string "status", default: "enabled", null: false
    t.string "agent_root_name", null: false
    t.jsonb "mcp_servers", default: [], null: false
    t.text "goal"
    t.text "prompt_template", null: false
    t.datetime "last_triggered_at"
    t.integer "sessions_created_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "reuse_session", default: false, null: false
    t.bigint "last_session_id"
    t.boolean "enqueue_messages", default: false, null: false
    t.boolean "resuscitate_archived", default: false, null: false
    t.jsonb "catalog_skills", default: [], null: false
    t.jsonb "catalog_hooks", default: [], null: false
    t.jsonb "catalog_plugins", default: [], null: false
    t.index ["last_session_id"], name: "index_triggers_on_last_session_id"
    t.index ["status"], name: "index_triggers_on_status"
  end

  create_table "account_rotation_events", force: :cascade do |t|
    t.bigint "rotated_from_id"
    t.bigint "rotated_to_id", null: false
    t.string "reason"
    t.string "source", null: false
    t.string "triggered_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_account_rotation_events_on_created_at", order: :desc
    t.index ["source"], name: "index_account_rotation_events_on_source"
  end

  create_table "app_settings", force: :cascade do |t|
    t.string "default_runtime"
    t.string "default_model"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "uncategorized_position", default: 0, null: false
    t.jsonb "extension_states", default: {}, null: false
  end

  create_table "catalog_pins", force: :cascade do |t|
    t.string "catalog", null: false
    t.string "ref", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["catalog"], name: "index_catalog_pins_on_catalog", unique: true
  end

  create_table "catalog_snapshots", force: :cascade do |t|
    t.jsonb "entries", null: false
    t.datetime "resolved_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["resolved_at"], name: "index_catalog_snapshots_on_resolved_at"
  end

  create_table "claude_accounts", force: :cascade do |t|
    t.string "email", null: false
    t.integer "status", default: 0, null: false
    t.jsonb "oauth_config", default: {}
    t.boolean "is_current", default: false, null: false
    t.integer "priority", default: 0, null: false
    t.integer "quota_hit_count", default: 0, null: false
    t.datetime "last_rotated_to_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "runtime", default: "claude_code", null: false
    t.index ["email", "runtime"], name: "index_claude_accounts_on_email_and_runtime", unique: true
    t.index ["is_current"], name: "index_claude_accounts_on_is_current"
    t.index ["runtime"], name: "index_claude_accounts_on_runtime"
    t.index ["status", "priority"], name: "index_claude_accounts_on_status_and_priority"
  end

  create_table "claude_account_quota_snapshots", force: :cascade do |t|
    t.bigint "claude_account_id", null: false
    t.string "subscription_type"
    t.string "rate_limit_tier"
    t.float "utilization_5h"
    t.float "utilization_7d"
    t.string "status_5h"
    t.string "status_7d"
    t.datetime "reset_5h"
    t.datetime "reset_7d"
    t.string "overage_status"
    t.string "overage_disabled_reason"
    t.string "trigger"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["claude_account_id", "created_at"], name: "idx_quota_snapshots_account_time"
    t.index ["claude_account_id"], name: "index_claude_account_quota_snapshots_on_claude_account_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.boolean "is_frozen", default: false, null: false
    t.index ["position"], name: "index_categories_on_position"
  end

  add_foreign_key "account_rotation_events", "claude_accounts", column: "rotated_from_id"
  add_foreign_key "account_rotation_events", "claude_accounts", column: "rotated_to_id"
  add_foreign_key "claude_account_quota_snapshots", "claude_accounts"
  add_foreign_key "elicitations", "sessions"
  add_foreign_key "enqueued_messages", "sessions"
  add_foreign_key "logs", "sessions"
  add_foreign_key "mcp_oauth_pending_flows", "sessions"
  add_foreign_key "notifications", "sessions"
  add_foreign_key "runtime_login_attempts", "claude_accounts"
  add_foreign_key "sessions", "categories", on_delete: :nullify
  add_foreign_key "sessions", "sessions", column: "blocked_by_session_id", on_delete: :nullify
  add_foreign_key "subagent_transcripts", "sessions"
  add_foreign_key "trigger_conditions", "triggers"
end
