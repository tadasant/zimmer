import Foundation

// MARK: - The health report
//
// In the shape `GET /api/v1/health` renders (HealthMonitorService#full_health_report and
// QueueRecoveryMode::Status#as_json), so the fixture goes through the real parser and every
// section of the web page has something to show.
extension FakeZimmerAPI {
    static func sampleHealthJSON(now: Date, degraded: Bool) -> [String: Any] {
        func iso(_ offset: TimeInterval) -> String { now.addingTimeInterval(offset).formatted(.iso8601) }
        func status(_ word: String, _ message: String) -> [String: Any] { ["status": word, "message": message] }

        let sessions: [String: Any] = [
            "status": status("warning", "Failure rate 12.5% over the last day"),
            "sessions_by_status": ["running": 3, "waiting": 5, "needs_input": 2, "failed": 2, "archived": 4],
            "total_sessions": 16,
            "failure_rate": 0.125,
            "error_categories": ["api_error": 1, "timeout": 1],
            "failure_reasons": ["api_error_retries_exhausted": 1, "sigterm": 1],
            "average_duration_seconds": 1_840,
            "recent_failures": [
                ["id": 1027, "slug": "rotate-key", "title": "Rotate the staging deploy key", "status": "failed", "git_root": "zimmer",
                 "updated_at": iso(-3 * 3600), "last_error": "API error 529: overloaded", "failure_reason": "api_error_retries_exhausted"],
                ["id": 1019, "slug": "poller", "title": "Fix the flaky transcript poller test", "status": "failed", "git_root": "motet",
                 "updated_at": iso(-11 * 3600), "last_error": "SIGTERM during deploy", "failure_reason": "sigterm"],
            ],
        ]

        let queueStats: [String: Any] = [
            "pending_count": 14, "ready_count": 6, "scheduled_count": 8, "claimed_count": 3, "failed_count": 1,
            "ready_count_by_queue": ["pollers": 4, "triggers": 2],
            "ready_count_by_job_class": ["SlackTriggerPollerJob": 4, "TriggerEvaluationJob": 2],
            "oldest_ready_age_seconds_by_queue": ["pollers": 48, "triggers": 12],
            "head_of_line": ["queue": "pollers", "job_class": "SlackTriggerPollerJob", "age_seconds": 48],
            "claimed_count_by_queue": ["agents": 2, "default": 1],
            "claimed_count_by_job_class": ["AgentSessionJob": 2, "TokenUsageIngestionJob": 1],
            "oldest_claimed_age_seconds_by_queue": ["agents": 1_920, "default": 14],
            "youngest_claimed_age_seconds_by_queue": ["agents": 310, "default": 14],
            "processing_rate_per_hour": 412,
            "last_finished_at": iso(-20),
            "seconds_since_last_finished": 20,
        ]

        let system: [String: Any] = [
            "status": status("healthy", "Queues draining; every lane has executed in the last minute"),
            "queue_depth": 6,
            "queue_stats": queueStats,
            "worker_stats": ["total_workers": 2, "active_workers": 2, "worker_details": []],
            "recent_errors": [
                ["id": "log-9", "source": "session_log", "session_id": 1027, "content": "API error 529: overloaded", "created_at": iso(-25 * 60)],
                ["id": "job-4", "source": "job", "session_id": NSNull(), "content": "SlackTriggerPollerJob (pollers): Slack::Web::Api::Errors::TooManyRequestsError", "created_at": iso(-41 * 60)],
            ],
            "database_status": ["connected": true, "connections_in_use": 3, "pool_size": 10],
            "queue_liveness_watchdog": ["expected": true, "running": true],
        ]

        let egress: [String: Any] = degraded
            ? ["status": status("critical", "Primary resolver 100.100.100.100 cannot resolve api.anthropic.com"),
               "resolver": "100.100.100.100", "detail": "Primary resolver 100.100.100.100 cannot resolve api.anthropic.com",
               "degraded_since": iso(-35 * 60), "checked_at": iso(-50)]
            : ["status": status("healthy", "DNS egress resolving"), "resolver": "100.100.100.100", "detail": NSNull(),
               "degraded_since": NSNull(), "checked_at": iso(-50)]

        let retrySessions: [[String: Any]] = [
            ["id": 1035, "slug": "s", "title": "Reconnect the Linear MCP server", "status": "running", "git_root": "zimmer", "retry_count": 1,
             "updated_at": iso(-40 * 60)],
        ]

        let postDeploy: [String: Any] = [
            "status": status("warning", "1 post-deploy task failing, retry pending"),
            "total": 3, "pending": 0, "running": 0, "succeeded": 2, "failed": 1, "blocked": 0, "awaiting_first_tick": 1,
            "tasks": [
                ["version": "20261001120000", "name": "backfill_session_genesis", "status": "succeeded", "registered": true, "attempts": 1,
                 "failures": 0, "blocked": false, "stats": ["rows": 4_120], "started_at": iso(-13 * 86_400), "finished_at": iso(-13 * 86_400),
                 "last_ran_at": iso(-13 * 86_400), "next_attempt_at": NSNull(), "last_error": NSNull(), "last_error_at": NSNull()],
                ["version": "20261008090000", "name": "reprice_token_usage", "status": "succeeded", "registered": true, "attempts": 3,
                 "failures": 0, "blocked": false, "stats": ["cursor": 918_000, "rows": 918_000], "started_at": iso(-6 * 86_400),
                 "finished_at": iso(-5 * 86_400), "last_ran_at": iso(-5 * 86_400), "next_attempt_at": NSNull(), "last_error": NSNull(), "last_error_at": NSNull()],
                ["version": "20261013110000", "name": "reconcile_catalog_references", "status": "failed", "registered": false, "attempts": 2,
                 "failures": 2, "blocked": false, "stats": ["triggers": 14], "started_at": iso(-2 * 3600), "finished_at": NSNull(),
                 "last_ran_at": iso(-20 * 60), "next_attempt_at": iso(25 * 60),
                 "last_error": "AirCatalogService::ResolveFailed: air resolve exited 1\n  app/services/air_catalog_service.rb:88", "last_error_at": iso(-20 * 60)],
            ],
        ]

        let cron: [String: Any] = [
            "status": status("warning", "1 key is behind its cadence (session_health_monitor)"),
            "cron_running_since": iso(-3 * 86_400),
            "checked_at": iso(0),
            "history_window_seconds": 86_400,
            "stopped_in_window": 1,
            "counts": ["stale": 0, "overdue": 1, "disabled": 1, "exempt": 1, "fresh": 3],
            "keys": [
                ["key": "session_health_monitor", "job_class": "SystemHealthMonitorJob", "cron": "every 5 minutes", "queue": "maintenance",
                 "last_enqueued_at": iso(-23 * 60), "overdue_seconds": 1_080, "ticks_in_window": 281, "stopped_in_window": false,
                 "state": "overdue", "reason": "Due 18m ago; the last tick was 23m ago"],
                ["key": "warm_clone_refill", "job_class": "WarmClonePoolRefillJob", "cron": "every 10 minutes", "queue": "maintenance",
                 "last_enqueued_at": iso(-4 * 60), "overdue_seconds": 0, "ticks_in_window": 131, "stopped_in_window": false, "state": "disabled",
                 "reason": "Disabled in the GoodJob dashboard"],
                ["key": "burn_rate_recompute", "job_class": "BurnRateRecomputeJob", "cron": "computed", "queue": "maintenance",
                 "last_enqueued_at": iso(-50 * 60), "overdue_seconds": 0, "ticks_in_window": 24, "stopped_in_window": false, "state": "exempt",
                 "reason": "A computed schedule has no fixed cadence to judge"],
                ["key": "slack_poll", "job_class": "SlackTriggerPollerJob", "cron": "every minute", "queue": "pollers",
                 "last_enqueued_at": iso(-30), "overdue_seconds": 0, "ticks_in_window": 1_401, "stopped_in_window": true,
                 "longest_gap_seconds": 2_700, "gap_ended_at": iso(-9 * 3600), "state": "fresh", "reason": NSNull()],
                ["key": "token_usage_ingest", "job_class": "TokenUsageIngestionJob", "cron": "every 10 minutes", "queue": "maintenance",
                 "last_enqueued_at": iso(-7 * 60), "overdue_seconds": 0, "ticks_in_window": 144, "stopped_in_window": false, "state": "fresh", "reason": NSNull()],
                ["key": "log_retention", "job_class": "LogRetentionJob", "cron": "every hour", "queue": "maintenance",
                 "last_enqueued_at": iso(-22 * 60), "overdue_seconds": 0, "ticks_in_window": 24, "stopped_in_window": false, "state": "fresh", "reason": NSNull()],
            ],
        ]

        let queueRecovery: [String: Any] = degraded
            ? ["active": true, "entered_at": iso(-18 * 60), "expires_at": iso(42 * 60), "expires_in_seconds": 2_520,
               "reason": "trigger stampede, 900 jobs/hour", "entered_by": "tadas", "halted_queues": ["pollers", "triggers", "inference", "maintenance", "default"],
               "paused_queues": ["pollers", "triggers", "inference", "maintenance", "default", "exports"], "live_queues": ["agents"]]
            : ["active": false, "entered_at": NSNull(), "expires_at": NSNull(), "expires_in_seconds": NSNull(), "reason": NSNull(), "entered_by": NSNull(),
               "halted_queues": ["pollers", "triggers", "inference", "maintenance", "default"], "paused_queues": [], "live_queues": ["agents"]]

        let report: [String: Any] = [
            "process_health": [
                "status": status("warning", "1 orphaned process"),
                "active_count": 4, "orphaned_count": 1, "tracked_count": 3, "recorded_count": 3, "observable": true,
                "active_processes": [], "tracked_processes": [], "recorded_processes": [],
                "orphaned_processes": [["pid": 48_112, "command": "claude --print --session-id 7f1c… --resume"]],
            ],
            "session_health": sessions,
            "system_health": system,
            "egress_health": egress,
            "auth_health": [
                "status": status("healthy", "Current account holds a usable credential"),
                "credentials_state": "usable", "credentials_detail": "refreshed 12 minutes ago", "credentials_owner": "tadas@example.com",
                "available_accounts": 2, "serviceable_accounts": 3, "needs_reauth_accounts": 1, "refused_credential_accounts": 0, "checked_at": iso(-60),
            ],
            "retry_budget_health": [
                "budgets": [
                    ["name": "sigterm", "label": "SIGTERM", "count_key": "sigterm_retry_count", "stamp_key": "last_sigterm_at", "max_retries": 3,
                     "total_sessions": 9, "total_retries_attempted": 11, "successful_recovery_count": 7, "exhausted_retry_count": 1, "recent_count": 2,
                     "recent_sessions": retrySessions],
                    ["name": "api_error", "label": "API error", "count_key": "api_error_retry_count", "stamp_key": "last_api_error_at", "max_retries": 5,
                     "total_sessions": 14, "total_retries_attempted": 31, "successful_recovery_count": 12, "exhausted_retry_count": 2, "recent_count": 3,
                     "recent_sessions": retrySessions],
                    ["name": "stall", "label": "Stall nudge", "count_key": "stall_nudge_count", "stamp_key": "last_stall_nudge_at", "max_retries": 2,
                     "total_sessions": 3, "total_retries_attempted": 3, "successful_recovery_count": 3, "exhausted_retry_count": 0, "recent_count": 0,
                     "recent_sessions": []],
                ],
            ],
            "sigterm_retry_health": [
                "total_sigterm_sessions": 9, "total_retries_attempted": 11, "successful_recovery_count": 7, "exhausted_retry_count": 1,
                "recent_sigterm_count": 2, "rate_limit_pressure": false, "rate_limit_events_5min": 0, "current_delay_mode": "normal", "max_retries": 3,
                "recent_sigterm_sessions": [
                    ["id": 1035, "slug": "s", "title": "Reconnect the Linear MCP server", "status": "running", "git_root": "zimmer", "retry_count": 1,
                     "last_sigterm_at": iso(-40 * 60), "updated_at": iso(-40 * 60)],
                ],
            ],
            "api_error_retry_health": [
                "total_api_error_sessions": 14, "total_retries_attempted": 31, "successful_recovery_count": 12, "exhausted_retry_count": 2,
                "recent_api_error_count": 3, "quota_limit_sessions_count": 4, "recent_quota_limit_count": 1, "rate_limit_pressure": true,
                "rate_limit_events_5min": 6, "current_delay_mode": "escalated", "max_retries": 5,
                "recent_api_error_sessions": [
                    ["id": 1027, "slug": "s", "title": "Rotate the staging deploy key", "status": "failed", "git_root": "zimmer", "retry_count": 5,
                     "last_api_error_at": iso(-3 * 3600), "updated_at": iso(-3 * 3600)],
                ],
            ],
            "post_deploy_task_health": postDeploy,
            "cron_health": cron,
            "log_retention_health": [
                "status": status("healthy", "Oldest row is 13 days old, inside the 14-day window"),
                "estimated_rows": 1_240_000, "total_bytes": 2_740_000_000, "index_bytes": 610_000_000,
                "oldest_log_at": iso(-13 * 86_400), "oldest_verbose_log_at": iso(-2 * 86_400), "retention_days": 14, "verbose_retention_days": 3,
            ],
            "inbound_event_health": [
                "status": status("healthy", "Every webhook source delivered in the last 24 hours"),
                "window_seconds": 86_400,
                "sources": [
                    ["name": "github", "mode": "webhook", "last_delivery_at": iso(-6 * 60), "deliveries_in_window": 212, "webhook_claims_in_window": 41, "poll_claims_in_window": 2],
                    ["name": "slack", "mode": "poll", "last_delivery_at": NSNull(), "deliveries_in_window": 0, "webhook_claims_in_window": 0, "poll_claims_in_window": 88],
                ],
            ],
            "root_data_health": [
                "status": status("healthy", "3 namespaces; nothing overdue"),
                "namespaces": [
                    ["namespace": "zimmer", "collections": 4, "records": 1_812, "data_bytes": 9_400_000, "last_written_at": iso(-12 * 60)],
                    ["namespace": "motet", "collections": 2, "records": 214, "data_bytes": 1_100_000, "last_written_at": iso(-5 * 3600)],
                    ["namespace": "zimmer-orchestrator", "collections": 1, "records": 9_600, "data_bytes": 22_000_000, "last_written_at": iso(-90)],
                ],
                "total_records": 11_626, "total_data_bytes": 32_500_000, "overdue_expired_records": 0,
                "near_cap": [["namespace": "zimmer-orchestrator", "collection": "decisions", "records": 9_600]],
                "max_records_per_collection": 10_000,
            ],
            "warm_clone_pool_health": [
                "status": status("healthy", "4 of 4 pooled keys ready"),
                "enabled": true, "scope": "all", "size": 4, "max_clones": 6, "window_days": 7, "outcome_window_hours": 24,
                "outcomes": ["router": ["claimed": 38, "missed": 2], "other": ["claimed": 21, "missed": 9]],
                "last_pass": ["at": iso(-8 * 60), "built": 1, "recycled": 1],
                "targets": [
                    ["repo_url": "git@github.com:tadasant/zimmer.git", "branch": "main", "ready": 2, "size": 2, "newest_age_seconds": 480, "starts": 61,
                     "roots": ["zimmer": 44, "zimmer-orchestrator": 17], "error": NSNull()],
                    ["repo_url": "https://github.com/tadasant/motet.git", "branch": "main", "ready": 1, "size": 2, "newest_age_seconds": 3_900, "starts": 12,
                     "roots": ["motet": 12], "error": "fetch timed out after 60s"],
                ],
                "passed_over": [["repo_url": "https://github.com/tadasant/tadasant-internal.git", "branch": "main", "starts": 3, "reason": "below the 5-start floor"]],
            ],
            "warm_process_pool_health": [
                "status": status("healthy", "1 of 1 warm router process ready."),
                "enabled": true, "size": 1, "max_age_minutes": 30, "outcome_window_hours": 24, "published_at": iso(-60),
                "outcomes": ["claimed": 14, "missed": 2, "model_mismatch": 3, "pool_empty": 1],
                "last_pass": ["at": iso(-4 * 60), "built": 1, "recycled": 1, "recycled_reasons": ["aged_out"]],
                "entries": [["id": "warm-7f1c", "pid": 51_203, "state": "ready", "age_seconds": 740, "model": "claude-sonnet-4-5", "account": "tadas@example.com"]],
            ],
            "overall_status": status("warning", "One or more warnings detected"),
            "generated_at": iso(0),
        ]

        return [
            "health_report": report,
            "queue_recovery_mode": queueRecovery,
            "timestamp": iso(0),
            "rails_env": "production",
            "ruby_version": "3.4.6",
        ]
    }
}
