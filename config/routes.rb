Rails.application.routes.draw do
  namespace :supervisor do
    resources :account_rotation_events
    # Read-only: both tables are measurements of API calls that already happened,
    # written by TokenUsageIngestionService from transcripts. There is nothing to
    # hand-author, and a corrected row comes from re-running ingestion.
    resources :adhoc_token_usages, only: [ :index, :show ]
    # Read-only plus destroy: rows are written by TranscriptHooks::GithubCommentAuthorshipHook
    # from what a session actually did, so there is nothing to hand-author — but a row
    # recorded in error must be removable, since it suppresses a comment fleet-wide.
    resources :agent_posted_github_comments, only: [ :index, :show, :destroy ]
    resources :app_settings
    resources :catalog_pins
    resources :categories
    resources :claude_accounts
    resources :claude_account_quota_snapshots
    resources :elicitations
    resources :enqueued_messages
    # Read-only, both of them. A GateDecision is append-only — it refuses update
    # and destroy — because a ledger that can be edited after the fact is not
    # evidence of anything; a correction is a new row recorded through the API or
    # the MCP tool. Feedback additionally has no create: its whole value is that
    # a machine did not write it, so the author is resolved from the
    # authenticated human at the web-UI boundary rather than typed into a form.
    resources :gate_decisions, only: [ :index, :show ]
    resources :gate_decision_feedbacks, only: [ :index, :show ]
    # Read-only: every write to the queue goes through WorkBacklog::Ranking's
    # lock and re-rank (the API and MCP tools), and a row edited here would
    # skip both.
    resources :work_backlog_items, only: [ :index, :show ]
    # Read-only: both tables are derived, and both are re-derived on a cron —
    # BurnRateRecomputeJob every 20 minutes, QuotaCapacityCalibrationJob every 15.
    # A hand-edited rate or capacity would be overwritten on the next run, and in
    # the meantime the spot gate would be spending against a figure the ledger
    # does not support.
    resources :harness_model_burn_rates, only: [ :index, :show ]
    # Read-only, with no destroy: a HumanMessage refuses update AND direct
    # destroy, precisely so a record of what a human said cannot be edited or
    # quietly removed after the fact. Hand-authoring one would forge an author,
    # and a Delete button here would only 500. A record goes away with its
    # session or not at all.
    resources :human_messages, only: [ :index, :show ]
    resources :logs
    # Read-only, like the gate ledger above: rows are append-only facts about
    # what Zimmer wrote to the Parameter Store, and an editable audit log is not
    # an audit log. The dashboard's FORM_ATTRIBUTES is empty for the same reason.
    resources :managed_secret_writes, only: [ :index, :show ]
    resources :mcp_oauth_credentials
    resources :mcp_oauth_pending_flows
    # Read-only plus destroy: an analysis is a reading a specific analyzer took of
    # a specific transcript, so there is nothing to hand-author and editing one
    # would forge it. A row saved in error is superseded by saving another, or
    # removed here.
    resources :outcome_analyses, except: [ :new, :create, :edit, :update ]
    # Read-only: a row records whether a one-time post-deploy task ran against
    # this environment. Hand-marking one succeeded would assert an application
    # nothing performed, and deleting one would make the task run again. Re-arm a
    # failed task from the health page.
    resources :post_deploy_task_runs, only: [ :index, :show ]
    # No create: a batch exists because someone clicked Analyze All. Edit is
    # limited to `status`/`state` (the dashboards' FORM_ATTRIBUTES) — the escape
    # hatch for a batch or item wedged in `running` that the pump cannot resolve.
    resources :outcome_analysis_batches, except: [ :new, :create ]
    resources :outcome_analysis_batch_items, except: [ :new, :create ]
    # Read-only, and derived on the same cron footing as the burn rates above.
    resources :quota_capacity_estimates, only: [ :index, :show ]
    resources :runtime_login_attempts
    resources :session_token_usages, only: [ :index, :show ]
    resources :token_usage_backfills, only: [ :index, :show ]
    resources :token_usage_features, only: [ :index, :show ]
    resources :session_experimental_flags, only: [ :index, :show ]
    resources :sessions
    # No create: a summary row exists because a session asked for one. Edit is
    # limited to `state` (the dashboard's FORM_ATTRIBUTES), which is how an
    # operator clears a generation wedged in `pending`; destroy makes the next
    # status change regenerate from scratch.
    resources :session_status_summaries, except: [ :new, :create ]
    # No create or edit: an edge is a record that one session actually queued or
    # interrupted another, written only by Sessions::RecordUncleEdge, which is
    # where the acyclicity invariant lives. Destroy is offered because the edge
    # is self-declared and unverified, so a mistaken one needs a way out until
    # there is a first-class detach (issue #299).
    resources :session_uncle_links, only: [ :index, :show, :destroy ]
    resources :subagent_transcripts
    resources :trigger_conditions
    resources :triggers
    # The roster of named humans. Full CRUD: this is where a Slack user ID is
    # linked to a person, which used to require an env var and a deploy.
    resources :users
    resources :x_oauth_credentials

    root to: "sessions#index"
  end

  # GoodJob dashboard for job monitoring
  mount GoodJob::Engine, at: "/jobs"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The deep check: 200 only when the database, the cache and Redis each answered
  # a real round trip, 503 naming the one that did not. `/up` above cannot make
  # that claim -- a container with a dead database boots and answers it 200 --
  # so a deploy gate that asks only `/up` passes a fully broken deploy.
  get "up/deep" => "health#deep", as: :deep_health_check

  # Zimmer's native MCP server (streamable HTTP). Scoped variants are selected
  # with query params: /mcp?tool_groups=self_session[&allowed_agent_roots=a,b].
  # The SDK's transport dispatches POST / GET / DELETE itself (GET and DELETE are
  # 405 in stateless mode), so every verb routes to the same action.
  match "mcp", to: "mcp#handle", via: [ :post, :get, :delete ], as: :mcp

  # API routes
  namespace :api do
    get "secrets/keys", to: "secrets#keys"

    # REST API v1
    namespace :v1 do
      resources :configs, only: [ :index ]
      resources :mcp_servers, only: [ :index ]
      resources :skills, only: [ :index ]

      # Token-spend ledger. `index` is the rollups the Costs page renders;
      # `records` is the row-level export the cost-vs-performance analysis needs.
      get "costs", to: "costs#index"
      get "costs/records", to: "costs#records"
      # Ops action, not a shell: sweep every transcript into the ledger.
      post "costs/backfill", to: "costs#backfill"

      # Organizational categories for the sessions dashboard.
      resources :categories, only: [ :index, :create, :update, :destroy ] do
        collection do
          # Persist a new top-to-bottom ordering of the whole category stack.
          post :reorder
        end
      end

      # Push notifications
      post "notifications/push", to: "notifications#push"

      resources :sessions do
        collection do
          get :search
          post :refresh_all
          post :bulk_archive
        end

        member do
          post :archive
          post :unarchive
          post :follow_up
          post :pause
          post :sleep, action: :sleep_session
          post :restart
          post :fork
          post :regenerate_status_summary
          post :refresh
          patch :mcp_servers, action: :update_mcp_servers
          patch :catalog_skills, action: :update_catalog_skills
          patch :catalog_hooks, action: :update_catalog_hooks
          patch :catalog_plugins, action: :update_catalog_plugins
          patch :model, action: :update_model
          get :transcript
          patch :notes, action: :update_notes
          post :toggle_favorite
          patch :visibility, action: :update_visibility
          patch :heartbeat, action: :update_heartbeat
          patch :set_category
        end

        resources :logs
        resources :subagent_transcripts
        resources :enqueued_messages do
          member do
            patch :reorder
            post :interrupt
          end
        end
      end

      # The gate decision ledger: what `pr-merge-gate` and `issue-work-gate` rated,
      # and why. Read and append only — a GateDecision is immutable once written,
      # so there is no update and no destroy here or anywhere else.
      #
      # No feedback-append action on purpose: `human_feedback` is writable only
      # from the browser (GateDecisionFeedbacksController), because the API key
      # this namespace authenticates is shared by the whole agent fleet and so
      # establishes a caller but not a person.
      resources :gate_decisions, only: [ :index, :show, :create ]

      # The work backlog: the ranked queue of gate-cleared issues. `create` and
      # `pull` mirror the append_work_backlog_item / pull_work_backlog_items MCP
      # tools; `start_now`, `pin`, `unpin` and `remove` are the human-only
      # operations and deliberately have NO MCP counterpart. :id on the member
      # routes is the row id or the item's key ("zimmer#498").
      # The id constraint lets a key with a dot in it ("next.js#5") route.
      resources :work_backlog_items, only: [ :index, :show, :create ], constraints: { id: %r{[^/]+} } do
        collection do
          post :pull
        end
        member do
          post :start_now
          patch :pin
          patch :unpin
          post :remove
        end
      end

      # Outcome analyses of archived session transcripts (the Outcomes view).
      # `create` is the REST half of the `save_outcome_analysis` MCP tool; :id on
      # the member routes is the ANALYZED SESSION's id or slug, not the analysis
      # row's, because a caller has a handle on the session.
      resources :outcome_analyses, only: [ :index, :show, :create ]

      # MCP server fallback elicitations
      resources :elicitations, only: [ :create, :show ] do
        member do
          patch :respond
        end
      end

      resources :triggers do
        member do
          post :toggle
          post :invoke
        end
        collection do
          get :channels
        end
      end

      resources :notifications, only: [ :index, :show ] do
        member do
          patch :mark_read
          delete :dismiss
        end
        collection do
          get :badge
          patch :mark_all_read
          delete :dismiss_all_read
        end
      end

      # Health monitoring
      resource :health, only: [ :show ], controller: :health do
        post :cleanup_processes
        post :retry_sessions
        post :archive_old
        # The queue escape hatch (QueueRecoveryMode). Named for the queues, not
        # for sessions — "recovery" elsewhere in this app means session recovery.
        get :queue_recovery_mode
        post :enter_queue_recovery_mode
        post :exit_queue_recovery_mode
        # Re-arm and kick the one-time post-deploy tasks. Their status is already
        # in the health report this endpoint's #show returns.
        post :run_post_deploy_tasks
      end

      # Transcript archive download and status
      scope :transcript_archive, controller: :transcript_archives do
        get "/download", action: :download, as: :transcript_archive_download
        get "/status", action: :status, as: :transcript_archive_status
      end

      # CLI tools status
      scope :clis, controller: :clis do
        get "/status", action: :status, as: :api_clis_status
        post "/refresh", action: :refresh, as: :api_clis_refresh
        post "/clear_cache", action: :clear_cache, as: :api_clis_clear_cache
      end
    end
  end

  # Health dashboard routes
  get "health", to: "health#dashboard", as: :health_dashboard
  get "health/refresh", to: "health#refresh", as: :refresh_health
  post "health/cleanup_processes", to: "health#cleanup_processes", as: :cleanup_processes_health
  post "health/retry_sessions", to: "health#retry_sessions", as: :retry_sessions_health
  post "health/archive_old", to: "health#archive_old", as: :archive_old_health
  get "health/export_diagnostics", to: "health#export_diagnostics", as: :export_diagnostics_health
  post "health/enter_queue_recovery_mode", to: "health#enter_queue_recovery_mode", as: :enter_queue_recovery_mode_health
  post "health/exit_queue_recovery_mode", to: "health#exit_queue_recovery_mode", as: :exit_queue_recovery_mode_health
  post "health/run_post_deploy_tasks", to: "health#run_post_deploy_tasks", as: :run_post_deploy_tasks_health

  # Polled by every page for the "live updates paused" banner. Deliberately plain
  # HTTP: the condition it reports is the broadcast circuit breaker being open,
  # which is when Turbo Stream broadcasts are the thing that isn't working.
  get "live_updates/status", to: "live_updates#status", as: :live_updates_status

  # Push notification subscriptions (for service worker)
  resources :push_subscriptions, only: [ :create, :destroy ]

  # Notifications page and badge
  resources :notifications, only: [ :index ] do
    member do
      patch :mark_read
      get :click  # Mark as read and redirect to session
      delete :dismiss
    end
    collection do
      get :badge
      patch :mark_all_read
      delete :dismiss_all_read
    end
  end

  # Settings page
  get "settings", to: "settings#show", as: :settings
  patch "settings/catalog_pins", to: "catalog_pins#update", as: :catalog_pins
  patch "settings/session_defaults", to: "app_settings#update", as: :app_settings

  # Inference page (per-runtime via ?runtime=claude_code|codex|pi)
  # Costs sits beside Inference: same posture question, different source.
  # Inference reads Anthropic's rate-limit headers; Costs reads our own token
  # ledger.
  get "costs", to: "costs#show", as: :costs
  # Re-scan every transcript into the ledger. An ops action with a button rather
  # than a rake task, because nobody is meant to need a shell on the box.
  post "costs/backfill", to: "costs#backfill", as: :costs_backfill
  get "inference", to: "inference#show", as: :inference
  # The surface was called Quotas until it grew a Pi tab that has no quota in
  # it. The old address is kept — permanently, not as a deprecation window —
  # because it is in the wild: Slack messages, alert bodies, and the runbooks
  # this repo has already shipped all point at it. `?runtime=` rides along, so a
  # bookmarked tab lands on the same tab.
  get "quotas", to: redirect { |params, request|
    query = request.query_string.presence
    query ? "/inference?#{query}" : "/inference"
  }, as: :quotas
  post "inference/refresh_all", to: "inference#refresh_all", as: :refresh_all_inference
  post "inference/refresh_account/:id", to: "inference#refresh_account", as: :refresh_account_inference
  post "inference/switch_account/:id", to: "inference#switch_account", as: :switch_account
  post "inference/add_account", to: "inference#add_account", as: :add_account_inference
  delete "inference/account/:id", to: "inference#destroy_account", as: :destroy_account_inference
  # UI-driven OAuth/device-auth login flow (the "Authenticate" button)
  post "inference/accounts/:id/login", to: "inference#start_login", as: :start_login_inference
  get "inference/login/:attempt_id", to: "inference#login_status", as: :login_status_inference
  post "inference/login/:attempt_id/code", to: "inference#submit_login_code", as: :submit_login_code_inference
  post "inference/login/:attempt_id/cancel", to: "inference#cancel_login", as: :cancel_login_inference
  # The Pi tab's OpenRouter API key. Create/update and delete only: there is
  # deliberately no route that reads the value back out — see
  # ManagedSecret::OpenrouterKey.
  put "inference/pi/openrouter_key", to: "inference#update_openrouter_key", as: :openrouter_key_inference
  delete "inference/pi/openrouter_key", to: "inference#destroy_openrouter_key", as: :destroy_openrouter_key_inference
  # The spot gate card, which lives on this page because it reads the quota
  # windows this page reports: the policy form, then one click per genesis kind.
  patch "inference/spot_policy", to: "spot_policies#update", as: :spot_policy
  patch "inference/genesis/:genesis", to: "genesis_classes#update", as: :genesis_class
  delete "inference/genesis", to: "genesis_classes#destroy", as: :reset_genesis_classes

  # Outcomes: the transcript-outcome analysis ledger, one transcript's
  # flamegraph drilldown, and the separate summary-stats surface. Every write
  # here spawns agent sessions, so all of them are POSTs — nothing analyzes on a
  # page load.
  get "outcomes", to: "outcomes#index", as: :outcomes
  get "outcomes/stats", to: "outcomes#stats", as: :outcomes_stats
  post "outcomes/analyze_all", to: "outcomes#analyze_all", as: :analyze_all_outcomes
  post "outcomes/batches/:id/cancel", to: "outcomes#cancel_batch", as: :cancel_outcome_batch
  post "outcomes/:id/analyze", to: "outcomes#analyze", as: :analyze_outcome
  # Last in the group so it cannot shadow "stats" as a session identifier.
  get "outcomes/:id", to: "outcomes#show", as: :outcome

  # Gate Decisions: the browsable ledger of every rating the PR-merge and
  # issue-work gates have made. Read-only — decisions are append-only and written
  # by the gates, so there is no create, update or destroy here.
  #
  # The nested feedbacks#create is the page's one write, and it is browser-only
  # by design: GateDecisionFeedbacksController is an ApplicationController
  # descendant, so no API key and no MCP tool reaches it. Read the honest limits
  # of that boundary on the controller itself — Zimmer's browser surface
  # authenticates nobody.
  resources :gate_decisions, only: [ :index, :show ] do
    resources :feedbacks, only: [ :create ], controller: "gate_decision_feedbacks"
  end

  # Issues: the fleet's work backlog joined to what is going on in GitHub across
  # the five repos the fleet works. GitHub is read at request time and cached for
  # a few minutes; `refresh` is the button that drops that cache, and it is a POST
  # because it costs ten `gh` calls and must not be re-run by a prefetch.
  #
  # The promote action is the page's one write, and it is browser-only by design:
  # WorkBacklogPromotionsController is an ApplicationController descendant, so no
  # API key and no MCP tool reaches it. Read the honest limits of that boundary on
  # the controller itself — Zimmer's browser surface authenticates nobody.
  get "issues", to: "issues#index", as: :issues
  post "issues/refresh", to: "issues#refresh", as: :refresh_issues
  post "issues/backlog/:id/promote", to: "work_backlog_promotions#create", as: :promote_work_backlog_item

  # Connectors page: every catalog MCP server with its auth status. Each row's
  # status is fetched individually by a lazy Turbo Frame hitting #show, so the
  # list renders before any probe resolves.
  resources :connectors, only: [ :index, :show ], param: :name, constraints: { name: /[^\/]+/ } do
    collection do
      # Which secret store is wired up, and what it can do. Its own lazy frame:
      # answering means an IAM probe against Google, which must never sit in
      # front of the page.
      get :secret_store, path: "secret-store"
    end
  end

  # Deleting a stored OAuth credential (the "Disconnect" button on Connectors).
  resources :mcp_oauth_credentials, only: [ :destroy ], path: "connector_credentials"

  # MCP elicitation response routes
  resources :elicitations, only: [] do
    member do
      patch :respond, action: :respond_to_elicitation
    end
  end

  # MCP OAuth routes
  scope :mcp_oauth, controller: :mcp_oauth do
    get "status/:session_id", action: :status, as: :mcp_oauth_status
    post "initiate", action: :initiate, as: :mcp_oauth_initiate
    get "callback", action: :callback, as: :mcp_oauth_callback
    post "complete", action: :complete, as: :mcp_oauth_complete
  end

  # Catalog refresh
  post "catalogs/refresh", to: "catalogs#refresh", as: :refresh_catalogs

  # CLI tools management
  get "clis", to: "clis#index", as: :clis
  get "clis/status", to: "clis#status", as: :clis_status
  get "clis/badge", to: "clis#badge", as: :clis_badge
  get "clis/refresh", to: "clis#refresh", as: :refresh_clis
  post "clis/clear_cache", to: "clis#clear_cache", as: :clear_cache_clis

  # Triggers for automated session creation
  resources :triggers do
    member do
      post :toggle
      post :toggle_enqueue_messages
      post :toggle_resuscitate_archived
      post :invoke
    end
    collection do
      get :channels
    end
  end

  # Sessions resource
  # Redirect /sessions to root to ensure canonical URL and avoid stale page issues
  # Preserves query parameters (e.g., /sessions?show_archived=true -> /?show_archived=true)
  get "sessions", to: redirect { |_params, request|
    query = request.query_string
    query.present? ? "/?#{query}" : "/"
  }

  resources :sessions, only: [ :new, :create, :show ] do
    member do
      post :archive
      post :unarchive
      post :undo_archive
      post :follow_up
      post :refresh
      post :pause
      post :restart
      # "Start it now" — the Ranked view's ⋮ menu, and the ⋮ menu is where the
      # queue is managed. Named :start_now rather than :start so the helper does
      # not read like the new-session form.
      post :start_now
      post :touch_activity
      patch :update_title
      patch :update_notes
      patch :update_mcp_servers
      patch :update_catalog_skills
      patch :update_catalog_hooks
      patch :update_catalog_plugins
      patch :update_model
      patch :update_auto_compact_window
      patch :update_scheduling_class
      patch :update_precedence
      patch :reorder_precedence
      patch :update_goal
      patch :toggle_favorite
      # Board visibility: hide / snooze / restore a card. Presentation only — it
      # does not sleep the session, and no route here does.
      patch :update_visibility
      patch :toggle_push_notifications
      patch :toggle_heartbeat
      patch :update_heartbeat_interval
      patch :set_category
      get :timeline_items
      # The dashboard drawer's variant of #show: the same detail body, wrapped in
      # <turbo-frame id="session_detail"> and rendered without the layout. It is a
      # distinct PATH rather than a Turbo-Frame-header variant of /sessions/:id so
      # that the framed and frameless bodies never share a cache key — see the
      # comment on SessionsController#drawer.
      get :drawer
      get :transcript
      post :fork
      post :regenerate_status_summary
      post :upload_images
      post :upload_files
    end
    collection do
      post :bulk_archive
      post :refresh_all
      post :refresh_category
      post :refresh_starred
      post :quick_prompt
      post :chat_bubble
      post :upload_images, as: :upload_images_new_session
      post :upload_files, as: :upload_files_new_session
    end

    # Enqueued messages nested under sessions
    resources :enqueued_messages, only: [ :create, :destroy, :update ] do
      member do
        patch :reorder
        post :interrupt
      end
    end
  end

  # Organizational categories for the sessions dashboard.
  resources :categories, only: [ :create, :update, :destroy ] do
    collection do
      # Persist a drag-and-drop / context-menu reordering of the whole category
      # stack. Accepts the new top-to-bottom order of category ids.
      post :reorder
    end
  end

  # Defines the root path route ("/")
  root "sessions#index"

  # Catch-all for unmatched paths. MUST stay last so it never shadows a real route.
  # Without it, an unmatched path raises ActionController::RoutingError, which Rails'
  # default DebugExceptions middleware logs at ERROR — and a single ERROR line trips
  # the critical "Zimmer ERROR logs present" Grafana alert. Routing here
  # instead renders a normal 404 (JSON for /api/*, the static 404 page otherwise) and
  # logs at INFO. Real exceptions raised inside controllers are unaffected.
  #
  # The glob is OPTIONAL — "(*unmatched)" rather than "*unmatched" — so it also matches
  # the bare root path. `root` only handles GET /; without the optional glob a non-GET
  # request to / (e.g. a scanner's POST /) matches no route and raises RoutingError,
  # re-tripping the alert via a different vector.
  match "(*unmatched)", to: "errors#not_found", via: :all
end
