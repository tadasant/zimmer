Rails.application.routes.draw do
  namespace :supervisor do
    resources :account_rotation_events
    resources :app_settings
    resources :catalog_pins
    resources :categories
    resources :claude_accounts
    resources :claude_account_quota_snapshots
    resources :elicitations
    resources :enqueued_messages
    resources :logs
    resources :mcp_oauth_credentials
    resources :mcp_oauth_pending_flows
    resources :runtime_login_attempts
    resources :sessions
    resources :subagent_transcripts
    resources :trigger_conditions
    resources :triggers

    root to: "sessions#index"
  end

  # GoodJob dashboard for job monitoring
  mount GoodJob::Engine, at: "/jobs"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Browsers fall back to requesting /favicon.ico at the root when no <link rel="icon">
  # is honored. The app ships PNG icons under /icons but no favicon.ico, so without this
  # the request raises ActionController::RoutingError (logged at ERROR). Return 204 No
  # Content so favicon probes stay quiet.
  get "/favicon.ico", to: ->(_env) { [ 204, {}, [] ] }

  # API routes
  namespace :api do
    get "secrets/keys", to: "secrets#keys"

    # REST API v1
    namespace :v1 do
      resources :configs, only: [ :index ]
      resources :mcp_servers, only: [ :index ]
      resources :skills, only: [ :index ]

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
          get :dependency_graph
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
          post :refresh
          patch :mcp_servers, action: :update_mcp_servers
          patch :catalog_skills, action: :update_catalog_skills
          patch :catalog_hooks, action: :update_catalog_hooks
          patch :catalog_plugins, action: :update_catalog_plugins
          patch :model, action: :update_model
          get :transcript
          patch :notes, action: :update_notes
          post :toggle_favorite
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

      # MCP server fallback elicitations
      resources :elicitations, only: [ :create, :show ] do
        member do
          patch :respond
        end
      end

      resources :triggers do
        member do
          post :toggle
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

  # Quotas page (per-runtime via ?runtime=claude_code|codex)
  get "quotas", to: "quotas#show", as: :quotas
  post "quotas/refresh_all", to: "quotas#refresh_all", as: :refresh_all_quotas
  post "quotas/refresh_account/:id", to: "quotas#refresh_account", as: :refresh_account_quotas
  post "quotas/switch_account/:id", to: "quotas#switch_account", as: :switch_account
  post "quotas/add_account", to: "quotas#add_account", as: :add_account_quotas
  delete "quotas/account/:id", to: "quotas#destroy_account", as: :destroy_account_quotas
  post "quotas/sync_from_filesystem", to: "quotas#sync_from_filesystem", as: :sync_from_filesystem_quotas
  # UI-driven OAuth/device-auth login flow (the "Authenticate" button)
  post "quotas/accounts/:id/login", to: "quotas#start_login", as: :start_login_quotas
  get "quotas/login/:attempt_id", to: "quotas#login_status", as: :login_status_quotas
  post "quotas/login/:attempt_id/code", to: "quotas#submit_login_code", as: :submit_login_code_quotas
  post "quotas/login/:attempt_id/cancel", to: "quotas#cancel_login", as: :cancel_login_quotas

  # API documentation page
  get "api_docs", to: "api_docs#show", as: :api_docs

  # OAuth Status page (view and manage OAuth credentials)
  resources :mcp_oauth_credentials, only: [ :index, :destroy ], path: "oauth_status", as: :oauth_status

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
      post :touch_activity
      patch :update_title
      patch :update_notes
      patch :update_mcp_servers
      patch :update_catalog_skills
      patch :update_catalog_hooks
      patch :update_catalog_plugins
      patch :update_model
      patch :update_auto_compact_window
      patch :update_goal
      patch :toggle_favorite
      patch :toggle_autonomous
      patch :toggle_push_notifications
      patch :set_category
      patch :mark_blocked
      patch :unmark_blocked
      get :timeline_items
      get :transcript
      post :fork
      post :upload_images
      post :upload_files
    end
    collection do
      post :bulk_archive
      post :refresh_all
      post :refresh_category
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
  # the critical "Agent Orchestrator ERROR logs present" Grafana alert. Routing here
  # instead renders a normal 404 (JSON for /api/*, the static 404 page otherwise) and
  # logs at INFO. Real exceptions raised inside controllers are unaffected.
  #
  # The glob is OPTIONAL — "(*unmatched)" rather than "*unmatched" — so it also matches
  # the bare root path. `root` only handles GET /; without the optional glob a non-GET
  # request to / (e.g. a scanner's POST /) matches no route and raises RoutingError,
  # re-tripping the alert via a different vector.
  match "(*unmatched)", to: "errors#not_found", via: :all
end
