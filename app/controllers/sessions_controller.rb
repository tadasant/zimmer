class SessionsController < ApplicationController
  require "path_sanitizer"
  require "automated_prompts"
  include ActionView::RecordIdentifier
  include SessionSearchable
  include PendingMessageDelivery

  # Pattern for validating temporary session IDs used for pre-session image uploads
  TEMP_SESSION_ID_PATTERN = /\Atemp_[a-f0-9\-]+\z/

  # Server-side cap on page context to prevent unbounded prompt inflation
  PAGE_CONTEXT_MAX_LENGTH = 50_000

  # Dashboard: number of session cards shown per category section page.
  SESSIONS_PER_PAGE = 50

  # Sentinel page key for the "Uncategorized" bucket (sessions with NULL category_id),
  # which has no Category record to key on. Namespaced page params look like
  # page[uncategorized]=2 alongside page[<category_id>]=2.
  UNCATEGORIZED_PAGE_KEY = "uncategorized".freeze

  # Dashboard view modes. "categories" is the existing category-grouped grid
  # (favorites pinned, custom drag ordering). The two flat modes completely
  # flatten that presentation into a single list sorted solely by one factor —
  # no category grouping, no per-category/custom ordering, no pinned float.
  VIEW_MODE_CATEGORIES = "categories".freeze
  VIEW_MODE_LAST_TOUCHED = "last_touched".freeze
  VIEW_MODE_CREATED_DESC = "created_desc".freeze
  VALID_VIEW_MODES = [ VIEW_MODE_CATEGORIES, VIEW_MODE_LAST_TOUCHED, VIEW_MODE_CREATED_DESC ].freeze

  # Cookie that persists an explicitly-chosen view mode across navigation. Only
  # written when the user picks a view via ?view=; absent until then so the
  # mobile/desktop default applies.
  VIEW_MODE_COOKIE = :sessions_view

  # SQL ordering for the "last touched" flat view. last_user_activity_at is not a
  # column — it lives in the metadata JSON (written as an ISO8601 string by
  # touch_user_activity!/touch_user_view!) and falls back to created_at when
  # never recorded. This reproduces Session#last_user_activity_at's fallback in
  # SQL so the ordering matches the model accessor: the value is cast to
  # timestamptz only when it looks like an ISO8601 datetime, otherwise (absent,
  # blank, or malformed) COALESCE degrades to created_at. The regex guard matters
  # because an unconditional ::timestamptz cast on a non-empty garbage string
  # would raise and 500 the whole dashboard, where the model accessor silently
  # degrades. The guard deliberately requires a full datetime (date + HH:MM), so
  # a bare date-only string would fall back to created_at here even though the
  # model's Time.parse would accept it — acceptable because the app always writes
  # this field as a full .iso8601 timestamp. No user input is interpolated, so
  # Arel.sql is safe.
  LAST_TOUCHED_ORDER = Arel.sql(
    "COALESCE(" \
      "CASE WHEN sessions.metadata->>'last_user_activity_at' ~ " \
      "'^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}' " \
      "THEN (sessions.metadata->>'last_user_activity_at')::timestamptz END, " \
      "sessions.created_at) DESC"
  )

  # User agents we treat as "mobile" for the purpose of choosing a default view.
  # This only affects the default when the user has not explicitly chosen a view;
  # the choice is always overridable and persisted, so a coarse heuristic is fine.
  MOBILE_USER_AGENT = /Mobile|Android|iPhone|iPod|IEMobile|BlackBerry|Opera Mini/i

  # TODO: Add proper authorization checks using a gem like Pundit or CanCanCan
  # Currently, all actions are accessible to any user
  # Recommended: Implement before_action :authorize_session for member actions
  # to ensure users can only access/modify their own sessions

  before_action :load_form_data, only: %i[new create]

  def index
    # Search inputs. A search is "active" when there is a free-text query OR an
    # agent-root filter; the transcript-contents toggle only widens an existing
    # text query, so it does not by itself count as an active search.
    @search_query = params[:q].to_s.strip
    @search_contents = params[:search_contents] == "1"
    @agent_root_filter = params[:agent_root].to_s.strip
    @search_active = @search_query.present? || @agent_root_filter.present?

    # Whether the user explicitly chose a trash visibility (e.g. clicked
    # "Show Trash"/"Hide Trash"). When they did, honor it verbatim. When they did
    # NOT, trash is included by default whenever a search is active, and hidden
    # otherwise. This lets "select an agent root, Search" surface trashed sessions
    # without a separate toggle, while still letting the user hide trash afterward.
    @show_archived_explicit = params[:show_archived].present?
    @show_archived =
      if @show_archived_explicit
        params[:show_archived] == "true"
      else
        @search_active
      end

    # Hide sessions that are manually "blocked by" a still-active session by default,
    # unless show_blocked param is present. A session is only effectively blocked while
    # its blocker is not yet archived (trashed); once trashed, it reappears automatically.
    @show_blocked = params[:show_blocked] == "true"

    # Build the base visibility scope, applying both the archived and blocked filters.
    # Used for every fresh scope constructed below so the filters stay consistent.
    base_scope = lambda do |scope|
      scope = scope.where.not(status: :archived) unless @show_archived
      scope = scope.not_effectively_blocked unless @show_blocked
      scope
    end

    sessions = base_scope.call(Session.all)

    # Roots offered in the Advanced Search agent-root autocomplete. Sourced from the
    # full catalog (not just user-invocable roots) so sessions from any root can be
    # filtered, sorted by name for a stable list.
    @agent_roots_for_filter = AgentRootsConfig.all.sort_by(&:name)

    if @search_query.present?
      sessions = filter_sessions_by_search(sessions, @search_query, include_contents: @search_contents)
    end

    if @agent_root_filter.present?
      sessions = filter_sessions_by_agent_root(sessions, @agent_root_filter)
    end

    # Resolve which view the dashboard renders in: the category-grouped grid, or
    # one of the two flat sort modes. Persists an explicit choice and applies the
    # mobile/desktop default otherwise.
    @view_mode = resolve_view_mode

    # Flat sort views completely flatten the presentation: a single list sorted
    # solely by the chosen factor, honoring the same filters/visibility but
    # ignoring category grouping, custom/per-category ordering, and the pinned
    # favorites float. They apply whether or not a search is active (search just
    # narrows the eligible set first).
    if @view_mode == VIEW_MODE_LAST_TOUCHED || @view_mode == VIEW_MODE_CREATED_DESC
      flat_sorted =
        if @view_mode == VIEW_MODE_LAST_TOUCHED
          sessions.order(LAST_TOUCHED_ORDER)
        else
          sessions.order(created_at: :desc)
        end
      @flat_sessions = flat_sorted.page(scalar_page_param).per(SESSIONS_PER_PAGE)
      @flat_view_title = @view_mode == VIEW_MODE_LAST_TOUCHED ? "Sorted by last touched" : "Sorted by created (newest first)"
      @any_sessions = @flat_sessions.any?
      return
    end

    # Shared ordering: favorites first, then newest. Used by both the flat search
    # results and every per-category window.
    ordered = sessions.order(favorited: :desc, created_at: :desc)

    # When a search is active, render a single flat results list and skip the
    # category-grouped grid entirely. The category sections (and their
    # drag-and-drop grid) only appear when no search is active.
    if @search_active
      @search_results = ordered.page(scalar_page_param).per(SESSIONS_PER_PAGE)
      @any_sessions = @search_results.any?
      return
    end

    # Per-category pagination. Each category section — including the "Uncategorized"
    # bucket — paginates its own sessions independently so paging one section never
    # disturbs the others. Page state is namespaced under page[...] so multiple
    # sections can sit on different pages at once without colliding:
    #   page[uncategorized]=2  → Uncategorized on page 2
    #   page[<category_id>]=3  → that category on page 3
    # A legacy/bookmarked scalar (?page=2) or a malformed array (?page[]=2) is not a
    # keyed hash, so it's ignored and every section falls back to page 1. Gate on the
    # concrete hash-like types — String and Array both respond to :[] but indexing them
    # with a string key would raise, so respond_to? is not a sufficient guard.
    page_params = params[:page]
    page_params = {} unless page_params.is_a?(ActionController::Parameters) || page_params.is_a?(Hash)

    @categories = Category.ordered.to_a

    # Starred (favorited) sessions are pinned into a single group above every category
    # section, regardless of which category they belong to, so the user's most important
    # sessions are immediately visible without scrolling. Every favorited session in the
    # current visibility scope is pinned (not just those on one global page — per-category
    # pagination has no single global page), and they are excluded from the per-category
    # windows below so each starred session appears exactly once, in the pinned group.
    @pinned_sessions = ordered.where(favorited: true)

    # Everything else feeds the paginated category sections. Favorited sessions are
    # filtered out here because they render in the pinned group above.
    unpinned = ordered.where(favorited: false)

    # Uncategorized: every non-favorited session with a NULL category_id. Keeps its own
    # Kaminari window driven by the "uncategorized" sentinel key.
    @uncategorized_sessions = unpinned.where(category_id: nil)
      .page(page_params[UNCATEGORIZED_PAGE_KEY]).per(SESSIONS_PER_PAGE)

    # One independent paginated window per category, keyed by the category id. Every
    # category renders a section — even empty ones — so it stays a valid drop target.
    @sessions_by_category = @categories.to_h do |category|
      [ category.id, unpinned.where(category_id: category.id)
        .page(page_params[category.id.to_s]).per(SESSIONS_PER_PAGE) ]
    end

    # Whether any session is visible at all (the pinned group plus every section's
    # current page), used to decide between the grid and the empty state. Each
    # per-section relation is its own paginated query (Kaminari also adds a COUNT for
    # total_pages), so this scans one window per category plus the pinned scope — fine at
    # the dashboard's category count; revisit with a single grouped query if categories
    # ever grow large.
    @any_sessions = @pinned_sessions.any? || @uncategorized_sessions.any? || @sessions_by_category.values.any?(&:any?)

    # Interleave the "Uncategorized" bucket (category_id = nil, the :uncategorized
    # sentinel) with the custom categories into one top-to-bottom stack. Uncategorized
    # has no Category row, so its slot is persisted separately on AppSetting and merged
    # in here by position. A tie (only possible before the first-ever reorder, when an
    # existing category also sits at position 0) puts Uncategorized first, preserving
    # its historical top slot.
    uncategorized_position = AppSetting.current.uncategorized_position
    @ordered_sections = (@categories + [ :uncategorized ]).sort_by do |section|
      section == :uncategorized ? [ uncategorized_position, 0 ] : [ section.position, 1 ]
    end
  end

  def new
    @session = Session.new
  end

  def create
    @session = Session.new(session_params)

    # Check if this is a clone-only session (no prompt)
    is_clone_only = @session.prompt.blank?

    # Set status based on whether this is clone-only or not
    # Clone-only sessions go straight to needs_input, ready for follow-up prompts
    # Note: We set status directly here since the session hasn't been saved yet
    # and the state machine is initialized after save. For clone-only sessions,
    # the default :waiting state will remain (needs_input comes from the state machine default).
    # Actually, AASM sets the initial state to :waiting by default, so we need to handle this correctly.
    @session.status = is_clone_only ? :needs_input : :waiting

    # Set branch, subdirectory, and model from agent root's defaults if not provided
    agent_root = nil
    if @session.git_root.present? && params[:agent_root_name].present?
      # Use the agent root name from the form to ensure we get the correct configuration
      agent_root = AgentRootsConfig.find(params[:agent_root_name])
      @session.branch = agent_root&.default_branch || "main" if @session.branch.blank?
      @session.subdirectory = agent_root&.subdirectory if @session.subdirectory.blank? && agent_root&.subdirectory.present?
      @session.metadata = (@session.metadata || {}).merge("agent_root_key" => params[:agent_root_name])
    elsif @session.git_root.present?
      # Fallback to URL-based lookup if agent_root_name is not provided (backward compatibility)
      agent_root = AgentRootsConfig.all.find { |ar| ar.url == @session.git_root }
      @session.branch = agent_root&.default_branch || "main" if @session.branch.blank?
      @session.subdirectory = agent_root&.subdirectory if @session.subdirectory.blank? && agent_root&.subdirectory.present?
    end

    # The global base defaults fill in only when neither the form nor the agent
    # root supplies a value (agent_root&.default_runtime/default_model already
    # fold the global in; this also covers the agent_root-less fallback path).
    app_setting = AppSetting.current

    # Resolve runtime: form selection wins, else the agent root's declared runtime,
    # else the global base default, else the default runtime. resolve_key normalizes
    # blank → default and raises on unregistered values, which we trap so a bad
    # param can never 500 the form.
    @session.agent_runtime = begin
      RuntimeRegistry.resolve_key(params[:agent_runtime].presence || agent_root&.default_runtime || app_setting.default_runtime)
    rescue KeyError
      RuntimeRegistry::DEFAULT_RUNTIME
    end

    # Set model in config, constrained to the resolved runtime's catalog:
    # form-selected model (if valid) → agent root default (if valid) → global base
    # default for the runtime (falling back to the runtime's catalog default).
    runtime = @session.agent_runtime
    requested_model = params[:model].to_s.strip.first(100).presence
    selected_model =
      if requested_model && ModelCatalog.valid_model?(runtime, requested_model)
        requested_model
      elsif ModelCatalog.valid_model?(runtime, agent_root&.default_model)
        agent_root.default_model
      else
        app_setting.resolved_default_model_for(runtime)
      end
    @session.config = (@session.config || {}).merge("model" => selected_model)

    # Parse images and files from temp session if provided
    temp_session_id = params[:temp_session_id]
    images = nil
    attached_files = nil

    success = with_db_retry do
      if @session.save
        # Copy images and files from temp session storage to real session storage
        if temp_session_id.present? && temp_session_id.match?(TEMP_SESSION_ID_PATTERN)
          images = ImageStorageService.copy_from_temp(
            temp_session_id: temp_session_id,
            new_session_id: @session.id
          )
          if images.present?
            @session.logs.create!(
              content: "Attached #{images.size} image(s) to initial prompt",
              level: "info"
            )
          end

          attached_files = FileStorageService.copy_from_temp(
            temp_session_id: temp_session_id,
            new_session_id: @session.id
          )
          if attached_files.present?
            @session.logs.create!(
              content: "Attached #{attached_files.size} file(s) to initial prompt",
              level: "info"
            )
          end
        end

        # Only enqueue job if there's a prompt (not clone-only)
        unless is_clone_only
          # Enqueue the background job to start the session
          AgentSessionJob.enqueue_new_session(@session.id, images: images.presence, files: attached_files.presence)
        else
          # For clone-only sessions, just enqueue the job to set up the clone
          # without providing a prompt
          AgentSessionJob.enqueue_for_clone_only(@session.id)
        end
        true
      else
        false
      end
    end

    if success == true
      notice_message = is_clone_only ?
        "Clone-only session created successfully. Ready for your first prompt." :
        "Session created successfully. Starting agent..."
      redirect_to @session, notice: notice_message
    elsif success != false
      # success is nil or some other truthy value - should not happen
      raise "Unexpected return value from with_db_retry: #{success.inspect}"
    else
      # success is false - either validation failure or max retries exceeded
      # Cleanup orphaned temp images and files on failure
      cleanup_temp_session_images(temp_session_id)
      cleanup_temp_session_files(temp_session_id)
      # Check if we already redirected (max retries) by checking performed?
      # Form data is already loaded by before_action :load_form_data
      render :new, status: :unprocessable_entity unless performed?
    end
  end

  def quick_prompt
    prompt = params[:prompt].to_s.strip

    if prompt.blank?
      redirect_to root_path, alert: "Prompt cannot be empty."
      return
    end

    if prompt.length > Session::PROMPT_MAX_LENGTH
      redirect_to root_path, alert: "Prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)."
      return
    end

    incoming_images = Array(params[:images]).reject { |f| f.is_a?(String) && f.empty? }
    incoming_files = Array(params[:files]).reject { |f| f.is_a?(String) && f.empty? }

    if incoming_images.size > MAX_IMAGES_PER_REQUEST
      redirect_to root_path, alert: "Maximum #{MAX_IMAGES_PER_REQUEST} images allowed."
      return
    end
    if incoming_files.size > MAX_FILES_PER_REQUEST
      redirect_to root_path, alert: "Maximum #{MAX_FILES_PER_REQUEST} files allowed."
      return
    end

    # Stage attachments under a temp session ID; copy into the real session
    # storage once the row is created and we know its ID. Same pattern used by
    # the chat_bubble and new session flows.
    temp_session_id = "temp_#{SecureRandom.uuid}"
    begin
      stage_uploads_or_raise!(incoming_images, incoming_files, temp_session_id)

      session = Session.create_from_agent_root!(
        agent_root_name: Session::ROUTER_AGENT_ROOT,
        prompt: prompt,
        metadata: { source: "quick_prompt" },
        skip_enqueue: true
      )

      images_to_attach, files_to_attach = copy_staged_uploads_to_session(
        temp_session_id, session, log_prefix: "quick prompt"
      )

      AgentSessionJob.enqueue_new_session(
        session.id,
        images: images_to_attach.presence,
        files: files_to_attach.presence
      )
    rescue ImageStorageService::ImageStorageError, FileStorageService::FileStorageError => e
      cleanup_temp_session_images(temp_session_id)
      cleanup_temp_session_files(temp_session_id)
      redirect_to root_path, alert: "Failed to upload attachment: #{e.message}"
      return
    rescue
      cleanup_temp_session_images(temp_session_id)
      cleanup_temp_session_files(temp_session_id)
      raise
    end

    redirect_to session, notice: "Router session created. The agent will route your request..."
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    redirect_to root_path, alert: "Router agent root not configured: #{e.message}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: "Failed to create session: #{e.message}"
  end

  # JSON endpoint for the global chat bubble.
  # Creates a router session with optional page context injected into the prompt.
  # Accepts multipart file uploads via images[] and files[] params.
  # Returns JSON so the client can decide whether to navigate or stay on the current page.
  def chat_bubble
    prompt = params[:prompt].to_s.strip
    page_context = params[:page_context].to_s.strip.truncate(PAGE_CONTEXT_MAX_LENGTH)
    current_url = params[:current_url].to_s.strip

    if prompt.blank?
      render json: { error: "Prompt cannot be empty." }, status: :unprocessable_entity
      return
    end

    if prompt.length > Session::PROMPT_MAX_LENGTH
      render json: { error: "Prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)." }, status: :unprocessable_entity
      return
    end

    # Build augmented prompt with page context
    augmented_prompt = prompt
    if page_context.present?
      context_block = "<context-about-user's-current-view>\n"
      context_block += "URL: #{current_url}\n\n" if current_url.present?
      context_block += "#{page_context}\n"
      context_block += "</context-about-user's-current-view>"
      augmented_prompt = "#{context_block}\n\n#{prompt}"
    end

    if augmented_prompt.length > Session::PROMPT_MAX_LENGTH
      render json: { error: "Combined prompt and page context is too long. Try a shorter prompt." }, status: :unprocessable_entity
      return
    end

    parent_session_id = nil
    if params[:parent_session_id].present?
      parent_id = params[:parent_session_id].to_i
      parent_session_id = parent_id if parent_id > 0
    end

    # Stage multipart uploads into a temp directory before creating the session,
    # then copy into the session's storage once we know its ID.
    incoming_images = Array(params[:images]).reject { |f| f.is_a?(String) && f.empty? }
    incoming_files = Array(params[:files]).reject { |f| f.is_a?(String) && f.empty? }
    if incoming_images.size > MAX_IMAGES_PER_REQUEST
      render json: { error: "Maximum #{MAX_IMAGES_PER_REQUEST} images allowed." }, status: :unprocessable_entity
      return
    end
    if incoming_files.size > MAX_FILES_PER_REQUEST
      render json: { error: "Maximum #{MAX_FILES_PER_REQUEST} files allowed." }, status: :unprocessable_entity
      return
    end

    temp_session_id = "temp_#{SecureRandom.uuid}"
    session = nil
    begin
      stage_uploads_or_raise!(incoming_images, incoming_files, temp_session_id)

      session = Session.create_from_agent_root!(
        agent_root_name: Session::ROUTER_AGENT_ROOT,
        prompt: augmented_prompt,
        parent_session_id: parent_session_id,
        metadata: { source: "chat_bubble", original_prompt: prompt, current_url: current_url },
        skip_enqueue: true
      )

      images_to_attach, files_to_attach = copy_staged_uploads_to_session(
        temp_session_id, session, log_prefix: "chat bubble prompt"
      )

      AgentSessionJob.enqueue_new_session(
        session.id,
        images: images_to_attach.presence,
        files: files_to_attach.presence
      )
    rescue ImageStorageService::ImageStorageError, FileStorageService::FileStorageError => e
      cleanup_temp_session_images(temp_session_id)
      cleanup_temp_session_files(temp_session_id)
      render json: { error: e.message }, status: :unprocessable_entity
      return
    rescue => e
      cleanup_temp_session_images(temp_session_id)
      cleanup_temp_session_files(temp_session_id)
      raise e
    end

    render json: { session_id: session.id, session_url: session_path(session) }
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render json: { error: "Router agent root not configured: #{e.message}" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to create session: #{e.message}" }, status: :unprocessable_entity
  end

  # Default number of timeline items to show on initial page load.
  INITIAL_TIMELINE_ITEMS_LIMIT = 100

  # How many items to fetch from each source (transcript + logs) when building
  # the tail of the timeline. Must be large enough that after filtering, we still
  # have INITIAL_TIMELINE_ITEMS_LIMIT items. 500 from each source gives us up to
  # 1000 items before filtering, which is more than enough.
  TAIL_FETCH_BUFFER = 500

  # Valid filter levels for timeline items
  # These correspond to the client-side log level filter values
  VALID_FILTER_LEVELS = %w[minimal condensed show-logs verbose].freeze

  def show
    @session = find_session

    # A genuine human view — opening the full page or lazy-loading the drawer
    # frame — counts as deliberate engagement. We only act on HTML requests
    # (initial page/drawer load, not passive Turbo Stream/AJAX polling) and skip
    # Turbo's hover-prefetch requests, which are speculative and not real views.
    if human_initiated_view?
      # Mark any unread notifications for this session as read.
      mark_session_notifications_read(@session)

      # Record the view as "last touched" user activity (best effort; a failure
      # here must never break rendering the session). touch_user_view! writes via
      # update_column so a mere view does not rebroadcast the card to the index.
      begin
        @session.touch_user_view!
      rescue => e
        Rails.logger.info("[SessionsController#show] touch_user_view! failed for session #{@session.id}: #{e.class}: #{e.message}")
      end
    end

    # Get filter level from params (for page load with filter param)
    # Default to "minimal" which matches the client-side default
    @filter_level = params[:filter].presence || "minimal"
    @filter_level = "minimal" unless VALID_FILTER_LEVELS.include?(@filter_level)

    # Performance optimization: instead of loading ALL logs and parsing the ENTIRE
    # transcript (which can be 280K+ logs and 9MB+ for long-running sessions),
    # only load the tail of each data source. We need enough items from each source
    # so that after merging, sorting, and filtering, we have at least
    # INITIAL_TIMELINE_ITEMS_LIMIT items to display.
    #
    # For the total count, we use cheap counting methods (SQL COUNT, line counting)
    # instead of loading all data into memory.
    @total_timeline_items_count = compute_filtered_count(@session, @filter_level)

    tail_items = build_timeline_items_tail(@session, @filter_level, TAIL_FETCH_BUFFER)
    filtered_items = filter_timeline_items(tail_items, @filter_level)

    # For initial page load, only show the last N filtered items
    if @total_timeline_items_count > INITIAL_TIMELINE_ITEMS_LIMIT
      @has_more_items = true
      @oldest_displayed_index = @total_timeline_items_count - [ filtered_items.count, INITIAL_TIMELINE_ITEMS_LIMIT ].min
      @timeline_items = filtered_items.last(INITIAL_TIMELINE_ITEMS_LIMIT)
    else
      @has_more_items = false
      @oldest_displayed_index = 0
      @timeline_items = filtered_items
    end

    # Timestamp cursor for infinite scroll pagination.
    # The oldest displayed item's timestamp is used as the cursor for loading earlier items.
    @oldest_displayed_timestamp = @timeline_items.first&.dig(:sort_time)&.iso8601(6)

    # Load MCP servers for the editable MCP selector
    @servers_for_select = ServersConfig.all.map do |server|
      { name: server.name, title: server.title, description: server.description }
    end

    # Load catalog skills for the editable skills selector
    @catalog_skills_for_select = SkillsConfig.all.map do |skill|
      { id: skill.id, name: skill.name, title: skill.title, description: skill.description, category: skill.category }
    end

    # Load catalog hooks for the editable hooks selector
    @catalog_hooks_for_select = HooksConfig.all.map do |hook|
      { id: hook.id, name: hook.name, title: hook.title, description: hook.description }
    end

    # Load plugins for the editable plugins selector
    @plugins_for_select = PluginsConfig.all.map do |plugin|
      { id: plugin.id, title: plugin.title, description: plugin.description }
    end

    # Load available models for the editable model selector, scoped to this
    # session's runtime so the picker only offers runtime-compatible models.
    @available_models = ModelCatalog.model_ids_for(@session.agent_runtime)

    # Load goals for the editable goal selector
    @goals_for_select = GoalsConfig.all.map do |goal|
      { id: goal.id, name: goal.name, description: goal.description }
    end

    # Load Claude skills for the follow-up form slash command typeahead
    @session_skills = ClaudeSkillsCacheService.get_for_session(@session)

    # MCP Apps spike (SEP-1865 / io.modelcontextprotocol/ui). Flag-gated PoC:
    # Zimmer connects to an app-capable MCP server as its own host, fetches an
    # interactive UI fragment + tool result, and surfaces it in the session
    # detail page (see _mcp_app_panel + mcp_app_host_controller.js). The QR
    # fragment encodes this session's own URL, tying the demo to the session.
    if McpAppPreviewService.enabled? && params[:mcp_app].to_s != "off"
      result = McpAppPreviewService.fetch(tool_args: { "text" => session_url(@session) })
      @mcp_app_preview = result.data if result.ok?
      Rails.logger.info("[mcp-apps-poc] preview fetch failed: #{result.error}") unless result.ok?
    end

    # This URL serves two structurally different bodies from the same path: the
    # full-page variant (no frame) and the drawer variant (wrapped in
    # <turbo-frame id="session_detail">). Which one is rendered depends solely on
    # the Turbo-Frame request header, so every cache between us and the browser —
    # including the browser's own HTTP cache that Turbo's hover-prefetch populates
    # — must key on that header. Without it, a frameless full-page response can be
    # reused to satisfy the drawer's frame request, rendering "Content missing".
    response.headers["Vary"] = [ response.headers["Vary"], "Turbo-Frame" ].compact.join(", ")

    # When the dashboard's session drawer lazy-loads this page into its Turbo
    # Frame, render a chrome-light, frame-wrapped variant without the
    # application layout (the drawer panel supplies the surrounding chrome).
    if request.headers["Turbo-Frame"] == "session_detail"
      @in_drawer = true
      render layout: false
    end
  end

  # Fetch older timeline items for infinite scroll
  # GET /sessions/:id/timeline_items
  # Params:
  #   - before_index: The index to fetch items before (exclusive) - index within FILTERED items
  #   - limit: Number of items to fetch (default: 100, max: 200)
  #   - filter: Filter level (minimal, condensed, show-logs, verbose)
  #   - before_timestamp: ISO8601 timestamp cursor (used for efficient pagination of large sessions)
  def timeline_items
    @session = find_session

    # Get filter level from params, default to "minimal"
    filter_level = params[:filter].presence || "minimal"
    filter_level = "minimal" unless VALID_FILTER_LEVELS.include?(filter_level)

    limit = [ params.fetch(:limit, INITIAL_TIMELINE_ITEMS_LIMIT).to_i, 200 ].min

    # Use timestamp-based cursor for efficient pagination of large sessions.
    # The before_timestamp param is set by the show action (oldest displayed item's
    # timestamp). Each page response includes the next cursor timestamp.
    if params[:before_timestamp].present?
      before_ts = Time.zone.parse(params[:before_timestamp])
      if before_ts.nil?
        head :bad_request
        return
      end

      items, has_more, next_cursor = build_timeline_items_before_timestamp(
        @session, filter_level, limit, before_ts
      )

      render partial: "sessions/timeline_items_batch", locals: {
        items: items,
        session: @session,
        has_more: has_more,
        next_before_index: 0, # Not used with timestamp cursor
        next_before_timestamp: next_cursor&.iso8601(6)
      }
    else
      # Legacy index-based fallback (for any in-flight requests during deploy)
      @logs = @session.logs.order(created_at: :asc)
      all_items = build_timeline_items(@session, @logs)
      filtered_items = filter_timeline_items(all_items, filter_level)

      before_index = params[:before_index].to_i
      if before_index > 0
        start_index = [ before_index - limit, 0 ].max
        items = filtered_items[start_index...before_index]
        has_more = start_index > 0
        next_before_index = start_index
      else
        items = []
        has_more = false
        next_before_index = 0
      end

      render partial: "sessions/timeline_items_batch", locals: {
        items: items,
        session: @session,
        has_more: has_more,
        next_before_index: next_before_index,
        next_before_timestamp: nil
      }
    end
  end

  def archive
    @session = find_session
    # TODO: Add authorization check here
    # Example: authorize @session (if using Pundit)

    if @session.archived?
      respond_to do |format|
        format.turbo_stream { render turbo_stream: archive_remove_streams(@session) }
        format.html { redirect_to @session, notice: "Session is already in trash." }
      end
      return
    end

    result = with_db_retry do
      @session.archive! if @session.may_archive?
      @session.logs.create!(
        content: "Session moved to trash by user",
        level: "info"
      )
    end

    # Only respond if the operation succeeded (not false from max retry handler)
    return if result == false

    respond_to do |format|
      format.turbo_stream { render turbo_stream: archive_remove_streams(@session) }
      format.html { redirect_to root_path, notice: "Session moved to trash.|undo_archive|#{@session.id}" }
    end
  end

  # In-place removal for the homepage Trash button. Removes the
  # `dom_id(session)` turbo_frame wrapping the session's card.
  def archive_remove_streams(session)
    [ turbo_stream.remove(dom_id(session)) ]
  end
  private :archive_remove_streams

  def unarchive
    @session = find_session
    # TODO: Add authorization check here
    # Example: authorize @session (if using Pundit)

    unless @session.archived?
      redirect_to @session, alert: "Session is not in trash."
      return
    end

    # Use UnarchiveSessionService to restore Claude Code state
    # This recreates the clone (if needed) and restores the transcript
    # so Claude Code can resume where it left off
    result = UnarchiveSessionService.call(session: @session)

    if result.success?
      notice = if result.clone_restored
        "Session restored from trash with clone restored. Ready to continue."
      else
        "Session restored from trash. Ready to continue."
      end
      redirect_to @session, notice: notice
    else
      redirect_to @session, alert: "Failed to restore session: #{result.error}"
    end
  end

  def undo_archive
    @session = find_session
    # TODO: Add authorization check here
    # Example: authorize @session (if using Pundit)

    unless @session.archived?
      redirect_to root_path, alert: "Session is not in trash."
      return
    end

    # Check if the trash is within the 5-second undo window
    if @session.archived_at.nil? || Time.current - @session.archived_at > 5.seconds
      redirect_to root_path, alert: "The undo window has expired. Use the restore feature instead."
      return
    end

    # Determine appropriate status to restore to
    completion_log = @session.logs.find { |log| log.content.include?("completed") || log.content.include?("failed") }
    new_status = completion_log ? :failed : :waiting

    result = with_db_retry do
      @session.update!(archived_at: nil)
      case new_status
      when :failed
        @session.unarchive_to_failed! if @session.may_unarchive_to_failed?
      when :waiting
        @session.unarchive_to_waiting! if @session.may_unarchive_to_waiting?
      end
      @session.logs.create!(
        content: "Session restored from trash by user",
        level: "info"
      )
    end

    # Only redirect if the operation succeeded
    return if result == false

    redirect_to @session, notice: "Session restored from trash."
  end

  def bulk_archive
    # TODO: Add authorization check to ensure user can only archive their own sessions
    # Example: session_ids = policy_scope(Session).where(id: params[:session_ids])

    session_ids = params[:session_ids] || []

    if session_ids.empty?
      redirect_to root_path, alert: "No sessions selected."
      return
    end

    # Eager load logs to avoid N+1 queries
    sessions = Session.includes(:logs).where(id: session_ids)
    archived_count = 0

    # Wrap in transaction for atomicity with retry logic
    result = with_db_retry do
      ActiveRecord::Base.transaction do
        sessions.each do |session|
          unless session.archived?
            session.archive! if session.may_archive?
            session.logs.create!(
              content: "Session moved to trash via bulk action",
              level: "info"
            )
            archived_count += 1
          end
        end
      end
    end

    # Only redirect if the operation succeeded
    return if result == false

    redirect_to root_path, notice: "#{archived_count} session(s) moved to trash."
  end

  # Maximum number of sessions to restart in a single bulk operation
  # to prevent system overload and request timeouts
  BULK_RESTART_LIMIT = 50

  def refresh
    @session = find_session

    # Manual refresh is a deliberate user interaction: reset PollBackoff so the
    # session's GitHub-poll cadence returns to the fast end.
    reset_poll_backoff(@session)

    # Check if session is running but has no active job - restore if needed
    if @session.running? && should_restore_job?(@session)
      restore_agent_session_job(@session)
    end

    # Check if session is failed and attempt to resume it
    if @session.failed?
      if resume_failed_session(@session)
        redirect_to session_path(@session), notice: "Attempting to resume failed session..."
        return
      end
    end

    # Read the latest transcript from filesystem
    # Use the private method to get transcript directory (handles security)
    transcript_dir = get_transcript_directory_for_session(@session)

    if transcript_dir.nil?
      redirect_to session_path(@session), alert: "No clone path found for this session"
      return
    end

    begin
      if Dir.exist?(transcript_dir)
        # Find main transcript file using session_id to avoid picking nested agent transcripts
        main_transcript_file = find_main_transcript_file_for_session(@session, transcript_dir)

        if main_transcript_file
          # Read and update transcript
          transcript_content = File.read(main_transcript_file)

          # Parse transcript to count messages
          message_count = count_transcript_messages(transcript_content)

          # Never let a manual refresh shrink the stored transcript. A shorter
          # filesystem transcript means the clone was recreated at a new path and
          # started a fresh file; session.transcript is the only durable record, so
          # overwriting it would destroy history. Keep the longer stored copy.
          if Session.transcript_regression?(@session.transcript, transcript_content)
            Rails.logger.warn "[SessionsController#refresh] Refused transcript regression for session #{@session.id} (stored #{Session.transcript_line_count(@session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
            redirect_to session_path(@session), alert: "Filesystem transcript is shorter than the stored one (clone likely recreated) — kept the longer stored transcript."
            return
          end

          # Update session with transcript AND update broadcast_message_count
          # This prevents duplicate messages when TranscriptPollerJob runs again
          result = with_db_retry do
            @session.update!(
              transcript: transcript_content,
              metadata: (@session.metadata || {}).merge("broadcast_message_count" => message_count)
            )

            @session.logs.create!(
              content: "Transcript refreshed manually from filesystem (#{message_count} messages)",
              level: "info"
            )
          end

          # Only continue if the operation succeeded
          return if result == false

          redirect_to session_path(@session), notice: "Transcript refreshed successfully"
          return
        end
      end

      # If we get here, transcript files not found
      redirect_to session_path(@session), alert: "No transcript files found on filesystem"
    rescue => e
      Rails.logger.error "Error refreshing transcript: #{e.message}"
      redirect_to session_path(@session), alert: "Error refreshing transcript: #{e.message}"
    end
  end

  def refresh_all
    # Only process non-archived sessions. Sessions in a frozen category are a parked
    # bucket and are intentionally left untouched by this bulk refresh.
    sessions = Session.not_in_frozen_category.where.not(status: :archived)
    bulk_refresh_sessions(sessions, empty_notice: "No non-archived sessions to refresh")
  end

  # Refresh only the non-archived sessions belonging to a single category, applying the
  # exact same restart/continue/transcript-refresh behavior as #refresh_all (both share
  # #bulk_refresh_sessions). Triggered by the per-category Refresh button in each
  # dashboard section header. The category is identified by the +category_id+ param; a
  # blank value or the "uncategorized" sentinel targets sessions with no category (the
  # Uncategorized section). Frozen categories are a parked bucket excluded from bulk
  # refresh, so the per-category button is not rendered for them and this action also
  # refuses them server-side, mirroring #refresh_all's exclusion.
  def refresh_category
    category_id = params[:category_id].to_s.presence

    if category_id.nil? || category_id == "uncategorized"
      sessions = Session.where(category_id: nil).where.not(status: :archived)
      empty_notice = "No non-archived uncategorized sessions to refresh"
    else
      category = Category.find_by(id: category_id)
      if category.nil?
        redirect_to root_path, alert: "Category not found"
        return
      end
      if category.is_frozen?
        redirect_to root_path, alert: "Frozen categories are excluded from refresh"
        return
      end
      sessions = category.sessions.where.not(status: :archived)
      empty_notice = "No non-archived sessions to refresh in \"#{category.name}\""
    end

    bulk_refresh_sessions(sessions, empty_notice: empty_notice)
  end

  # Shared implementation behind #refresh_all and #refresh_category. Given a relation of
  # candidate sessions (already scoped to exclude archived sessions and any frozen
  # bucket), it (1) restarts failed sessions, (2) continues auto-continuable needs_input
  # sessions (those NOT paused by the user), and (3) refreshes transcripts for the
  # remaining running/waiting sessions, then redirects to the dashboard with a summary.
  # +empty_notice+ is the flash shown when the relation has no sessions to act on.
  def bulk_refresh_sessions(sessions, empty_notice:)
    if sessions.empty?
      redirect_to root_path, notice: empty_notice
      return
    end

    refreshed_count = 0
    restarted_count = 0
    continued_count = 0
    error_count = 0

    # Separate restartable sessions (failed and auto-continuable needs_input) from others
    # Only continue needs_input sessions that were paused by recovery (deployment interruption),
    # not those paused by the user intentionally. User-paused sessions have paused_by: "user".
    # Sessions without paused_by are treated as continuable for backwards compatibility.
    auto_continuable_needs_input = sessions
      .where(status: :needs_input)
      .where("metadata->>'paused_by' IS NULL OR metadata->>'paused_by' != 'user'")

    # Track totals to warn if limit is exceeded
    total_failed_count = sessions.where(status: :failed).count
    total_needs_input_count = auto_continuable_needs_input.count
    total_restartable_count = total_failed_count + total_needs_input_count

    # Apply bulk limit across both failed and needs_input sessions
    # Prioritize failed sessions, then needs_input
    # Use .load to force loading, then .size to avoid extra COUNT query
    failed_sessions = sessions.where(status: :failed).limit(BULK_RESTART_LIMIT).load
    remaining_limit = [ BULK_RESTART_LIMIT - failed_sessions.size, 0 ].max
    needs_input_sessions = auto_continuable_needs_input.limit(remaining_limit)

    non_restartable_sessions = sessions.where.not(status: [ :failed, :needs_input ])

    # Restart failed sessions
    failed_sessions.find_each do |session|
      success, error_message = restart_with_continue_prompt(session)
      if success
        restarted_count += 1
      else
        error_count += 1
        Rails.logger.warn "[bulk_refresh] Failed to restart session #{session.id}: #{error_message}"
      end
    end

    # Continue needs_input sessions (e.g., after deployment killed their processes)
    needs_input_sessions.find_each do |session|
      success, error_message = restart_with_continue_prompt(session)
      if success
        continued_count += 1
      else
        error_count += 1
        Rails.logger.warn "[bulk_refresh] Failed to continue session #{session.id}: #{error_message}"
      end
    end

    # Refresh non-restartable sessions (running and waiting)
    non_restartable_sessions.each do |session|
      # Check if session is running but has no active job - restore if needed
      if session.running? && should_restore_job?(session)
        restore_agent_session_job(session)
      end

      # Read the latest transcript from filesystem
      transcript_dir = get_transcript_directory_for_session(session)
      next if transcript_dir.nil?

      begin
        if Dir.exist?(transcript_dir)
          # Find main transcript file using session_id to avoid picking nested agent transcripts
          main_transcript_file = find_main_transcript_file_for_session(session, transcript_dir)

          next unless main_transcript_file

          # Read and update transcript
          transcript_content = File.read(main_transcript_file)

          # Parse transcript to count messages
          message_count = count_transcript_messages(transcript_content)

          # Skip sessions whose filesystem transcript is shorter than the stored
          # one (clone recreated at a new path) — overwriting would destroy history.
          if Session.transcript_regression?(session.transcript, transcript_content)
            Rails.logger.warn "[bulk_refresh] Skipped transcript regression for session #{session.id} (stored #{Session.transcript_line_count(session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
            next
          end

          # Update session with transcript AND update broadcast_message_count
          result = with_db_retry do
            session.update!(
              transcript: transcript_content,
              metadata: (session.metadata || {}).merge("broadcast_message_count" => message_count)
            )

            session.logs.create!(
              content: "Transcript refreshed via bulk refresh (#{message_count} messages)",
              level: "info"
            )
          end

          # If any session fails max retries, abort early (redirect already happened)
          return if result == false

          refreshed_count += 1
        end
      rescue => e
        Rails.logger.error "Error refreshing session #{session.id}: #{e.message}"
        error_count += 1
      end
    end

    # Build response message
    messages = []
    messages << "Refreshed #{refreshed_count} session(s)" if refreshed_count.positive?
    messages << "Restarted #{restarted_count} failed session(s)" if restarted_count.positive?
    messages << "Continued #{continued_count} paused session(s)" if continued_count.positive?

    if messages.any?
      notice = messages.join(", ")
      notice += " (#{error_count} errors)" if error_count.positive?
      notice += ". #{total_restartable_count - BULK_RESTART_LIMIT} more sessions to restart/continue" if total_restartable_count > BULK_RESTART_LIMIT
      redirect_to root_path, notice: notice
    elsif error_count.positive?
      redirect_to root_path, alert: "Failed to process #{error_count} session(s)"
    else
      redirect_to root_path, notice: "No sessions to refresh or restart"
    end
  end
  private :bulk_refresh_sessions

  def follow_up
    @session = find_session

    # Validate follow-up prompt is present
    follow_up_prompt = params[:follow_up_prompt].to_s.strip
    if follow_up_prompt.blank?
      respond_to_follow_up_error("Follow-up prompt cannot be empty.")
      return
    end

    # Validate prompt length
    if follow_up_prompt.length > Session::PROMPT_MAX_LENGTH
      respond_to_follow_up_error("Follow-up prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters).")
      return
    end

    # Get goal from params (can be blank to remove goal)
    # If not provided in params, default to session's existing goal
    goal = if params.key?(:goal)
      params[:goal].to_s.strip.presence
    else
      @session.goal
    end

    # Validate goal length if present
    if goal.present? && goal.length > Session::GOAL_MAX_LENGTH
      respond_to_follow_up_error("Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters).")
      return
    end

    # IMPORTANT: If session is running, redirect to queue the message instead of sending immediately.
    # This prevents race conditions where the form action was set incorrectly (e.g., before JS loaded)
    # or where the user double-submitted. Messages should be queued when the agent is running.
    if @session.running?
      # Create enqueued message instead of interrupting
      max_position = @session.enqueued_messages.maximum(:position) || 0
      next_position = max_position + 1

      result = with_db_retry do
        @session.enqueued_messages.create!(
          content: follow_up_prompt,
          goal: goal,
          position: next_position,
          status: "pending"
        )

        @session.logs.create!(
          content: "Message queued at position #{next_position} (redirected from follow_up to queue)",
          level: "info"
        )

        # Reset PollBackoff: an enqueue from a follow-up form submit is direct
        # user engagement with the session.
        @session.touch_user_activity!
      end

      return if performed?

      if result != false
        redirect_to @session, notice: "Message queued. It will be sent when the agent completes its current task."
      end
      return
    end

    # Validate session is in the correct status (waiting or needs_input after potential pause)
    unless @session.waiting? || @session.needs_input?
      respond_to_follow_up_error("Cannot send follow-up prompts when session is #{@session.status}. Session must be waiting or needs input.")
      return
    end

    # Use transaction to ensure atomicity with retry logic
    result = with_db_retry do
      ActiveRecord::Base.transaction do
        # Update session's goal if it changed
        if goal != @session.goal
          @session.update!(goal: goal)
          goal_message = goal.present? ? "updated" : "removed"
          @session.logs.create!(
            content: "Goal #{goal_message} for this follow-up",
            level: "info"
          )
        end

        stale_keys = Session::STALE_RETRY_METADATA_KEYS
        if stale_keys.any? { |key| @session.metadata&.dig(key).present? }
          @session.update!(
            metadata: (@session.metadata || {}).except(*stale_keys)
          )
        end

        # Update session status to running
        @session.resume! if @session.may_resume?

        # Log the follow-up prompt (truncate to prevent log bloat)
        truncated_prompt = follow_up_prompt.length > 200 ? "#{follow_up_prompt[0..197]}..." : follow_up_prompt
        @session.logs.create!(
          content: "Follow-up prompt received: #{truncated_prompt}",
          level: "info"
        )

        # Store pending prompt in metadata so it can be recovered if the job
        # is interrupted (e.g., SIGTERM retry kicks in before job processes).
        # Also store sent_at timestamp for pause-wait-for-delivery logic.
        # This prevents the race condition where follow-up prompts are lost
        # and replaced with the automated recovery prompt during SIGTERM retries.
        #
        # We also store sent_message for recovery purposes: if the session
        # transitions to paused/failed before the message appears in the transcript,
        # we can preload it back into the follow-up entry box so the user doesn't
        # lose their message. The sent_message is cleared by TranscriptPollerService
        # once the message appears in the transcript.
        sent_at = Time.current
        @session.update!(
          metadata: (@session.metadata || {}).merge(
            "pending_follow_up_prompt" => follow_up_prompt,
            "pending_follow_up_sent_at" => sent_at.iso8601,
            "sent_message" => follow_up_prompt,
            "sent_message_at" => sent_at.iso8601,
            # Stamps user activity so PollBackoff resets the GitHub-poll cadence
            # for this session (this key is NOT cleared by transcript polling).
            "last_user_activity_at" => sent_at.iso8601
          )
        )

        # Parse image paths from params if provided (stored by upload_images action)
        images = parse_image_params
        # Parse file paths from params if provided (stored by upload_files action)
        attached_files = parse_file_params

        # Broadcast optimistic user message immediately for instant feedback
        # This shows the message in the timeline before Claude processes it
        BroadcastService.new.optimistic_user_message(@session, follow_up_prompt, sent_at: sent_at)

        # Log if images are being sent
        if images.present?
          @session.logs.create!(
            content: "Sending #{images.size} image(s) with follow-up prompt",
            level: "info"
          )
        end

        # Log if files are being sent
        if attached_files.present?
          @session.logs.create!(
            content: "Sending #{attached_files.size} file(s) with follow-up prompt",
            level: "info"
          )
        end

        # Enqueue job to continue the session with the follow-up prompt and images.
        # Store running_job_id immediately to close the window where the session is
        # "running" but has no tracked job — without this, if the job is delayed or
        # fails before setting running_job_id itself, the session gets stuck as
        # "running" with no job and no feedback to the user.
        job = AgentSessionJob.enqueue_with_prompt(@session.id, follow_up_prompt, images: images, files: attached_files)
        @session.update!(running_job_id: job.job_id)
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to_follow_up_error("Failed to submit follow-up prompt: #{e.message}")
      return
    end

    # Only respond if the operation succeeded
    return if result == false

    # Respond with Turbo Stream to avoid full page reload.
    # This is critical for optimistic message display - a redirect would cause
    # a full page reload which re-renders the timeline from the database/transcript,
    # making the optimistic message disappear since it hasn't been written to the
    # transcript yet.
    respond_to do |format|
      format.turbo_stream do
        # Replace the form to update it to "running" mode (changes button text,
        # form action to enqueue endpoint, etc.)
        # The optimistic message was already broadcast via ActionCable and stays in the DOM.
        session_skills = ClaudeSkillsCacheService.get_for_session(@session)
        render turbo_stream: turbo_stream.replace(
          "session_#{@session.id}_follow_up_form",
          partial: "sessions/follow_up_form",
          locals: { agent_session: @session, session_skills: session_skills }
        )
      end
      format.html do
        redirect_to @session, notice: "Follow-up prompt sent. Agent is processing..."
      end
    end
  end

  def pause
    @session = find_session

    # Pausing is a deliberate user interaction: reset PollBackoff so the
    # session's GitHub-poll cadence returns to the fast end.
    reset_poll_backoff(@session)

    # Only allow pausing sessions that are currently running
    unless @session.running?
      redirect_to @session, alert: "Cannot pause session that is not running (status: #{@session.status})"
      return
    end

    # Get process PID from session metadata
    process_pid = @session.metadata&.dig("process_pid")

    unless process_pid
      redirect_to @session, alert: "Cannot pause session: no process found"
      return
    end

    # Wait for pending follow-up prompt to be delivered before pausing
    # This prevents losing messages when user sends a follow-up then quickly pauses
    wait_for_pending_message_delivery(@session)

    # Terminate the process using ProcessLifecycleManager
    begin
      with_db_retry do
        @session.logs.create!(
          content: "Pausing Claude CLI session (terminating process #{process_pid})",
          level: "info"
        )

        # Mark this as a user-initiated pause so refresh_all doesn't auto-continue it.
        # Sessions paused by deployment recovery have paused_by: "recovery" instead.
        @session.update!(metadata: (@session.metadata || {}).merge("paused_by" => "user"))
      end

      # IMPORTANT: Terminate the process BEFORE updating session status to needs_input.
      # This fixes a race condition where updating status first causes AgentSessionJob
      # to exit its monitoring loop immediately (on detecting needs_input?) without
      # doing a final transcript poll. By killing the process first, the job detects
      # the process exit via wait_nonblock, does a final transcript poll, and then
      # exits cleanly. This ensures the most recent Claude message is captured.
      lifecycle_manager = ProcessLifecycleManager.new(
        session: @session,
        process_manager: SystemProcessManager.new
      )

      # Set up the manager with the existing process PID for termination
      # We use resume_monitoring to establish the manager state, then terminate
      stderr_log_path = File.join(@session.metadata&.dig("clone_path") || "", "claude_stderr.log")
      resume_result = lifecycle_manager.resume_monitoring(
        pid: process_pid,
        stderr_log_path: stderr_log_path
      )

      if resume_result.success?
        terminate_result = lifecycle_manager.terminate(reason: :user_pause)
        unless terminate_result.success?
          with_db_retry do
            @session.logs.create!(
              content: "Warning: Termination returned #{terminate_result.error || 'unknown error'}",
              level: "warning"
            )
          end
        end
      else
        # Process is already not running
        with_db_retry do
          @session.logs.create!(
            content: "Process #{process_pid} already terminated or not owned by this process",
            level: "warning"
          )
        end
      end

      # Now update session status to needs_input AFTER the process is dead.
      # The job will do a final transcript poll either when it detects the process
      # exit (via wait_nonblock) or when it detects the status change (needs_input?).
      # Either way, the final transcript poll is guaranteed to happen.
      with_db_retry do
        @session.pause! if @session.may_pause?
      end

      with_db_retry do
        @session.logs.create!(
          content: "Claude CLI process terminated for pause",
          level: "info"
        )

        @session.logs.create!(
          content: "Session paused successfully - ready for follow-up prompts",
          level: "info"
        )
      end

      redirect_to @session, notice: "Session paused successfully. You can now send a follow-up prompt to redirect the agent."
    rescue => e
      Rails.logger.error "Error pausing session: #{e.message}"
      with_db_retry do
        @session.logs.create!(
          content: "Failed to pause session: #{e.message}",
          level: "error"
        )
      end
      redirect_to @session, alert: "Failed to pause session: #{e.message}"
    end
  end

  def restart
    @session = find_session

    # Restarting is a deliberate user interaction: reset PollBackoff so the
    # session's GitHub-poll cadence returns to the fast end.
    reset_poll_backoff(@session)

    # Only allow restarting sessions that are failed
    unless @session.failed?
      respond_to do |format|
        format.html { redirect_to @session, alert: "Cannot restart session that is not failed (status: #{@session.status})" }
        format.turbo_stream { render_restart_turbo_stream }
      end
      return
    end

    # First check if a Claude CLI process is still running for this session
    # Explicitly convert to integer since metadata is stored as JSON
    process_pid = @session.metadata&.dig("process_pid")&.to_i

    if process_pid && process_pid > 0
      begin
        # Check if process is still alive (signal 0 doesn't actually send a signal)
        # Note: There's an inherent race condition between this check and job execution.
        # If the process dies between the check and the monitoring job starting, the job
        # will detect the dead process and transition to needs_input. This is acceptable
        # behavior and the user will see the session move to needs_input state.
        Process.kill(0, process_pid)

        # Process is still running - reconnect to monitoring
        result = with_db_retry do
          ActiveRecord::Base.transaction do
            @session.logs.create!(
              content: "Restarting failed session: reconnecting to running process #{process_pid}",
              level: "info"
            )

            cleaned_metadata = (@session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
            @session.update!(running_job_id: nil, metadata: cleaned_metadata)
            if @session.may_resume?
              @session.resume!
            elsif @session.may_start?
              @session.start!
            end

            # Enqueue job to resume monitoring without spawning a new process
            AgentSessionJob.enqueue_for_monitoring(@session.id)

            @session.logs.create!(
              content: "Monitoring job restored successfully",
              level: "info"
            )
          end
        end

        return if result == false

        respond_to do |format|
          format.html { redirect_to @session, notice: "Reconnected to running process. Monitoring resumed." }
          format.turbo_stream do
            @session.reload
            render_restart_turbo_stream
          end
        end
        return
      rescue Errno::ESRCH, Errno::EPERM
        # Process is not running or not accessible - fall through to resume with automated recovery prompt
      end
    end

    # Process is not running - attempt to resume with automated recovery prompt
    success, error_message = restart_with_continue_prompt(@session)
    if success
      respond_to do |format|
        format.html { redirect_to session_path(@session), notice: "Attempting to restart failed session..." }
        format.turbo_stream do
          @session.reload
          render_restart_turbo_stream
        end
      end
    else
      respond_to do |format|
        format.html { redirect_to session_path(@session), alert: "Cannot restart session: #{error_message}" }
        format.turbo_stream do
          @session.reload
          render_restart_turbo_stream
        end
      end
    end
  end

  def transcript
    @session = find_session
    # TODO: Add authorization check here - transcript contains sensitive conversation data
    # Example: authorize @session (if using Pundit)

    # Build formatted transcript for copying
    formatted = format_transcript_for_copy(@session)

    respond_to do |format|
      format.text { render plain: formatted }
      format.html { redirect_to @session }
    end
  end

  def fork
    @session = find_session

    # Forking from a session is a deliberate user interaction: reset PollBackoff
    # so the source session's GitHub-poll cadence returns to the fast end.
    reset_poll_backoff(@session)

    # Get message_index from params
    message_index = params[:message_index].to_i

    # Validate message_index is provided and non-negative
    if params[:message_index].blank?
      respond_to do |format|
        format.html { redirect_to @session, alert: "Message index is required for forking." }
        format.json { render json: { error: "Message index is required" }, status: :unprocessable_entity }
      end
      return
    end

    # Call the ForkSessionService
    result = ForkSessionService.call(
      source_session: @session,
      message_index: message_index
    )

    if result.success?
      respond_to do |format|
        format.html { redirect_to result.forked_session, notice: "Session forked successfully. You can now send a new prompt to explore an alternative path." }
        format.json { render json: { success: true, session_url: session_url(result.forked_session), session_id: result.forked_session.id } }
      end
    else
      respond_to do |format|
        format.html { redirect_to @session, alert: "Failed to fork session: #{result.error}" }
        format.json { render json: { error: result.error }, status: :unprocessable_entity }
      end
    end
  end

  def update_title
    @session = find_session
    title = params[:title].to_s.strip

    if title.blank?
      render json: { error: "Title cannot be empty" }, status: :unprocessable_entity
      return
    end

    if title.length > 100
      render json: { error: "Title is too long (maximum 100 characters)" }, status: :unprocessable_entity
      return
    end

    # Remove auto_generated_title flag when user manually edits the title
    updated_metadata = (@session.metadata || {}).except("auto_generated_title")

    result = with_db_retry do
      if @session.update(title: title, metadata: updated_metadata)
        @session.logs.create!(
          content: "Session title updated to: #{title}",
          level: "info"
        )
        true
      else
        false
      end
    end

    # Check if we already rendered (max retries exceeded)
    return if performed?

    if result
      render json: { success: true, title: title }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def update_notes
    @session = find_session
    notes = params[:session_notes]

    # Allow blank notes (to clear them)
    if notes.present? && notes.length > 50_000
      render json: { error: "Notes are too long (maximum 50,000 characters)" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      @session.update(
        session_notes: notes.presence,
        session_notes_updated_at: notes.present? ? Time.current : nil
      )
    end

    return if performed?

    if result
      render json: {
        success: true,
        session_notes_updated_at: @session.session_notes_updated_at&.iso8601
      }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # Assign (or clear) a session's organizational category. Called when a card is
  # dragged into a category section on the dashboard. A blank/absent category_id
  # moves the session back to "Uncategorized".
  def set_category
    @session = find_session
    category_id = params[:category_id].presence&.to_i

    if category_id
      category = Category.find_by(id: category_id)
      unless category
        respond_to do |format|
          format.html { redirect_back fallback_location: root_path, alert: "Category ##{category_id} not found" }
          format.json { render json: { error: "Category ##{category_id} not found" }, status: :not_found }
        end
        return
      end
      @session.update!(category_id: category.id)
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path }
        format.json { render json: { success: true, session_id: @session.id, category_id: category.id } }
      end
    else
      @session.update!(category_id: nil)
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path }
        format.json { render json: { success: true, session_id: @session.id, category_id: nil } }
      end
    end
  end

  # Mark a session as blocked by another session (the blocker). The blocked session
  # is hidden from the default index until the blocker is trashed (archived).
  def mark_blocked
    @session = find_session
    blocker_id = params[:blocked_by_session_id].presence&.to_i

    unless blocker_id
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "A blocker session ID is required" }
        format.json { render json: { error: "A blocker session ID is required" }, status: :unprocessable_entity }
      end
      return
    end

    blocker = Session.find_by(id: blocker_id)
    unless blocker
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Session ##{blocker_id} not found" }
        format.json { render json: { error: "Session ##{blocker_id} not found" }, status: :not_found }
      end
      return
    end

    if blocker.id == @session.id
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "A session cannot be blocked by itself" }
        format.json { render json: { error: "A session cannot be blocked by itself" }, status: :unprocessable_entity }
      end
      return
    end

    @session.update!(blocked_by_session_id: blocker.id)
    respond_to do |format|
      format.html do
        flash[:notice] = "Session ##{@session.id} is now blocked by ##{blocker.id}"
        redirect_back fallback_location: root_path
      end
      format.json { render json: { success: true, session_id: @session.id, blocked_by_session_id: blocker.id } }
    end
  end

  # Clear a session's "blocked by" relationship, making it visible in the default index again.
  def unmark_blocked
    @session = find_session
    @session.update!(blocked_by_session_id: nil)
    respond_to do |format|
      format.html do
        flash[:notice] = "Session ##{@session.id} is no longer blocked"
        redirect_back fallback_location: root_path
      end
      format.json { render json: { success: true, session_id: @session.id, blocked_by_session_id: nil } }
    end
  end

  MAX_MCP_SERVERS = 50
  MAX_MCP_SERVER_NAME_LENGTH = 100
  MAX_CATALOG_SKILLS = 100
  MAX_CATALOG_SKILL_NAME_LENGTH = 100
  MAX_CATALOG_HOOKS = 100
  MAX_CATALOG_HOOK_NAME_LENGTH = 100
  MAX_CATALOG_PLUGINS = 50
  MAX_CATALOG_PLUGIN_ID_LENGTH = 100

  def toggle_push_notifications
    @session = find_session

    result = with_db_retry do
      @session.update!(push_notifications_enabled: !@session.push_notifications_enabled)
    end

    return if performed?

    if result != false
      respond_to do |format|
        format.html { redirect_to @session }
        format.json do
          render json: {
            success: true,
            push_notifications_enabled: @session.push_notifications_enabled
          }
        end
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "session_#{@session.id}_header_actions",
            partial: "sessions/session_header_actions",
            locals: { agent_session: @session }
          )
        end
      end
    else
      respond_to do |format|
        format.html { redirect_to @session, alert: "Failed to update push notification setting" }
        format.json do
          render json: { error: "Failed to update push notification setting" },
                 status: :unprocessable_entity
        end
      end
    end
  end

  # Enable/disable the per-session heartbeat. Accepts an optional explicit
  # `enabled` boolean (used by the popout's on/off controls); with no param it
  # flips the current state. Responds JSON — the heart control updates in place
  # via Stimulus (mirrors the auto-compact-window inline editor pattern).
  def toggle_heartbeat
    @session = find_session

    # Prefer an explicit boolean; fall back to flipping the current state when the
    # param is absent or casts to nil (e.g. ""), so a bad value can never write a
    # nil into the NOT NULL column.
    casted = ActiveModel::Type::Boolean.new.cast(params[:enabled]) if params.key?(:enabled)
    enabled = casted.nil? ? !@session.heartbeat_enabled : casted

    result = with_db_retry do
      @session.update!(heartbeat_enabled: enabled)
    end

    return if performed?

    if result != false
      respond_to do |format|
        format.json { render json: heartbeat_json }
        format.html { redirect_to @session }
      end
    else
      respond_to do |format|
        format.json { render json: { error: "Failed to update heartbeat" }, status: :unprocessable_entity }
        format.html { redirect_to @session, alert: "Failed to update heartbeat" }
      end
    end
  end

  # Set how often the heartbeat beats. Validated against
  # Session::HEARTBEAT_MIN/MAX_INTERVAL_SECONDS. Responds JSON.
  def update_heartbeat_interval
    @session = find_session

    updated = with_db_retry do
      @session.update(heartbeat_interval_seconds: params[:heartbeat_interval_seconds])
    end

    return if performed?

    if updated
      render json: heartbeat_json
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def toggle_favorite
    @session = find_session

    result = with_db_retry do
      @session.update!(favorited: !@session.favorited)
    end

    return if performed?

    if result != false
      respond_to do |format|
        format.html do
          # Determine where to redirect based on the referrer
          # If coming from the sessions index, redirect back to trigger page refresh
          # so favorites reorder correctly. Otherwise, redirect to session show page.
          if referrer_is_sessions_index?
            redirect_to root_path
          else
            redirect_to @session
          end
        end
        format.json { render json: { success: true, favorited: @session.favorited } }
        format.turbo_stream do
          render turbo_stream: [
            # Update session card on index page
            turbo_stream.replace(
              "session_#{@session.id}",
              partial: "sessions/session_card_frame",
              locals: { agent_session: @session }
            ),
            # Update header actions on detail page (for smooth in-place update)
            turbo_stream.replace(
              "session_#{@session.id}_header_actions",
              partial: "sessions/session_header_actions",
              locals: { agent_session: @session }
            )
          ]
        end
      end
    else
      respond_to do |format|
        format.html do
          if referrer_is_sessions_index?
            redirect_to root_path, alert: "Failed to update favorite status"
          else
            redirect_to @session, alert: "Failed to update favorite status"
          end
        end
        format.json { render json: { error: "Failed to update favorite status" }, status: :unprocessable_entity }
      end
    end
  end

  # Side-effect-only endpoint: stamp the session with a fresh user-activity
  # marker so PollBackoff resets the GitHub-poll cadence back to the fast
  # (every-cron-tick) end. Triggered by a non-blocking fetch from the UI when
  # the user clicks an "open PR" button — the link itself still opens GitHub in
  # a new tab; this just tells Rails the user is engaging with the session so
  # PR/CI/merge-conflict status starts refreshing promptly again.
  #
  # Returns 204 No Content; the UI does not consume the response body.
  def touch_activity
    @session = find_session

    reset_poll_backoff(@session)

    head :no_content
  end

  def update_mcp_servers
    @session = find_session

    # Get the new MCP servers list from params
    mcp_servers = params[:mcp_servers] || []

    # Ensure mcp_servers is an array
    unless mcp_servers.is_a?(Array)
      render json: { error: "mcp_servers must be an array" }, status: :unprocessable_entity
      return
    end

    # Limit array size to prevent DoS
    if mcp_servers.length > MAX_MCP_SERVERS
      render json: { error: "Too many MCP servers (maximum #{MAX_MCP_SERVERS})" }, status: :unprocessable_entity
      return
    end

    # Clean and validate entries
    mcp_servers = mcp_servers.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_MCP_SERVER_NAME_LENGTH) }

    # Validate that all server names exist in the catalog
    invalid_servers = mcp_servers.reject { |name| ServersConfig.exists?(name) }
    if invalid_servers.any?
      render json: { error: "Invalid MCP servers: #{invalid_servers.join(', ')}" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      old_servers = @session.mcp_servers || []

      if @session.update(mcp_servers: mcp_servers)
        # Log the change
        added = mcp_servers - old_servers
        removed = old_servers - mcp_servers

        # A deliberate removal is not an unexplained loss — forget its status so
        # later config regenerations don't report it as one.
        @session.forget_mcp_server_status!(removed)

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?

        if changes.any?
          @session.logs.create!(
            content: "MCP servers updated (#{changes.join('; ')})",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    # Check if we already rendered (max retries exceeded)
    return if performed?

    if result
      # Regenerate .mcp.json if the session has a working directory
      regenerate_mcp_config_file(@session)

      # Check for OAuth requirements on the saved servers
      oauth_result = check_oauth_requirements_for_servers(@session, mcp_servers)

      # If OAuth is required, update session metadata so the UI shows authorization buttons
      if oauth_result[:servers_needing_oauth].any?
        with_db_retry do
          @session.reload
          @session.update!(
            metadata: (@session.metadata || {}).merge(
              "failure_reason" => "oauth_required",
              "oauth_required_servers" => oauth_result[:servers_needing_oauth]
            )
          )
          # Transition to failed state so the OAuth UI shows
          @session.fail! if @session.may_fail?
        end

        @session.logs.create!(
          content: "OAuth authorization required for: #{oauth_result[:servers_needing_oauth].map { |s| s[:server_name] }.join(', ')}",
          level: "warning"
        )
      elsif @session.metadata&.dig("failure_reason") == "oauth_required"
        with_db_retry do
          @session.reload
          cleaned_metadata = (@session.metadata || {}).except("failure_reason", "oauth_required_servers")
          @session.update!(metadata: cleaned_metadata)
        end
      end

      respond_to do |format|
        format.turbo_stream do
          # Re-render the metadata partial (desktop) and the mobile MCP partial in place,
          # so the user's follow-up draft and other client state are preserved.
          # The metadata partial includes the OAuth authorization buttons region, so the
          # OAuth-required branch is also handled here without a full page reload.
          locals = mcp_partials_locals(@session)
          render turbo_stream: [
            turbo_stream.replace(
              "session_#{@session.id}_metadata",
              partial: "sessions/session_metadata",
              locals: locals
            ),
            turbo_stream.replace(
              "session_#{@session.id}_mobile_mcp_servers",
              partial: "sessions/mobile_mcp_servers",
              locals: locals
            )
          ]
        end
        format.json do
          render json: {
            success: true,
            mcp_servers: mcp_servers,
            oauth_required: oauth_result[:servers_needing_oauth].any?,
            oauth_required_servers: oauth_result[:servers_needing_oauth]
          }
        end
      end
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_catalog_skills
  # Update catalog skills for a session via the web UI.
  def update_catalog_skills
    @session = find_session

    catalog_skills = params[:catalog_skills] || []

    unless catalog_skills.is_a?(Array)
      render json: { error: "catalog_skills must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_skills.length > MAX_CATALOG_SKILLS
      render json: { error: "Too many skills (maximum #{MAX_CATALOG_SKILLS})" }, status: :unprocessable_entity
      return
    end

    catalog_skills = catalog_skills.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_CATALOG_SKILL_NAME_LENGTH) }

    invalid_skills = catalog_skills.reject { |name| SkillsConfig.exists?(name) }
    if invalid_skills.any?
      render json: { error: "Invalid catalog skills: #{invalid_skills.join(', ')}" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      old_skills = @session.catalog_skills || []

      if @session.update(catalog_skills: catalog_skills)
        added = catalog_skills - old_skills
        removed = old_skills - catalog_skills

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?

        if changes.any?
          @session.logs.create!(
            content: "Catalog skills updated (#{changes.join('; ')})",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      render json: { success: true, catalog_skills: catalog_skills }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_catalog_hooks
  def update_catalog_hooks
    @session = find_session

    catalog_hooks = params[:catalog_hooks] || []

    unless catalog_hooks.is_a?(Array)
      render json: { error: "catalog_hooks must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_hooks.length > MAX_CATALOG_HOOKS
      render json: { error: "Too many hooks (maximum #{MAX_CATALOG_HOOKS})" }, status: :unprocessable_entity
      return
    end

    catalog_hooks = catalog_hooks.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_CATALOG_HOOK_NAME_LENGTH) }

    invalid_hooks = catalog_hooks.reject { |name| HooksConfig.exists?(name) }
    if invalid_hooks.any?
      render json: { error: "Invalid catalog hooks: #{invalid_hooks.join(', ')}" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      old_hooks = @session.catalog_hooks || []

      if @session.update(catalog_hooks: catalog_hooks)
        added = catalog_hooks - old_hooks
        removed = old_hooks - catalog_hooks

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?

        if changes.any?
          @session.logs.create!(
            content: "Catalog hooks updated (#{changes.join('; ')})",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      render json: { success: true, catalog_hooks: catalog_hooks }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_catalog_plugins
  def update_catalog_plugins
    @session = find_session

    catalog_plugins = params[:catalog_plugins] || []

    unless catalog_plugins.is_a?(Array)
      render json: { error: "catalog_plugins must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_plugins.length > MAX_CATALOG_PLUGINS
      render json: { error: "Too many plugins (maximum #{MAX_CATALOG_PLUGINS})" }, status: :unprocessable_entity
      return
    end

    catalog_plugins = catalog_plugins.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_CATALOG_PLUGIN_ID_LENGTH) }

    invalid_plugins = catalog_plugins.reject { |id| PluginsConfig.exists?(id) }
    if invalid_plugins.any?
      render json: { error: "Invalid catalog plugins: #{invalid_plugins.join(', ')}" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      old_plugins = @session.catalog_plugins || []

      if @session.update(catalog_plugins: catalog_plugins)
        added = catalog_plugins - old_plugins
        removed = old_plugins - catalog_plugins

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?

        if changes.any?
          @session.logs.create!(
            content: "Catalog plugins updated (#{changes.join('; ')})",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      regenerate_mcp_config_file(@session)

      oauth_result = check_oauth_requirements(@session)

      if oauth_result[:servers_needing_oauth].any?
        with_db_retry do
          @session.reload
          @session.update!(
            metadata: (@session.metadata || {}).merge(
              "failure_reason" => "oauth_required",
              "oauth_required_servers" => oauth_result[:servers_needing_oauth]
            )
          )
          @session.fail! if @session.may_fail?
        end

        @session.logs.create!(
          content: "OAuth authorization required for: #{oauth_result[:servers_needing_oauth].map { |s| s[:server_name] }.join(', ')}",
          level: "warning"
        )
      end

      render json: {
        success: true,
        catalog_plugins: catalog_plugins,
        oauth_required: oauth_result[:servers_needing_oauth].any?,
        oauth_required_servers: oauth_result[:servers_needing_oauth]
      }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_model
  # Update the model for a session via the web UI.
  def update_model
    @session = find_session

    model = params[:model]

    unless model.is_a?(String) && model.present?
      render json: { error: "model must be a non-empty string" }, status: :unprocessable_entity
      return
    end

    model = model.strip.first(100)

    result = with_db_retry do
      old_model = @session.config&.dig("model")
      new_config = (@session.config || {}).merge("model" => model)

      if @session.update(config: new_config)
        if old_model != model
          @session.logs.create!(
            content: "Model updated (#{old_model} → #{model})",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      render json: { success: true, model: model }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_auto_compact_window
  # Update the Claude Code auto-compact window (context window, in tokens) for a
  # session via the web UI. Mirrors update_model: the value is a top-level column
  # (not stored in config) consumed as CLAUDE_CODE_AUTO_COMPACT_WINDOW at process
  # spawn time, so a change takes effect on the next turn / restart — not on the
  # currently running process. The view communicates this to the user.
  def update_auto_compact_window
    @session = find_session

    raw = params[:auto_compact_window]

    # Require an explicit integer within the same bounds enforced at creation
    # (Session#auto_compact_window numericality validation). Reject blanks and
    # non-integer strings before touching the record so the JSON error is clear.
    unless raw.to_s.match?(/\A\d+\z/)
      render json: { error: "auto_compact_window must be a positive integer" }, status: :unprocessable_entity
      return
    end

    new_window = raw.to_i

    if new_window <= 0 || new_window > Session::MAX_AUTO_COMPACT_WINDOW
      render json: { error: "auto_compact_window must be between 1 and #{Session::MAX_AUTO_COMPACT_WINDOW}" }, status: :unprocessable_entity
      return
    end

    result = with_db_retry do
      old_window = @session.auto_compact_window

      if @session.update(auto_compact_window: new_window)
        if old_window != new_window
          @session.logs.create!(
            content: "Context window updated (#{old_window} → #{new_window}); applies on next turn or restart",
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      render json: { success: true, auto_compact_window: @session.auto_compact_window }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # PATCH /sessions/:id/update_goal
  # Update the goal for a session via the web UI.
  def update_goal
    @session = find_session

    goal = params[:goal].to_s.strip.presence
    goal = goal&.first(Session::GOAL_MAX_LENGTH)

    result = with_db_retry do
      old_goal = @session.goal

      if @session.update(goal: goal)
        if old_goal != goal
          change_desc = if goal.blank?
            "Goal cleared"
          elsif old_goal.blank?
            "Goal set"
          else
            "Goal updated"
          end

          @session.logs.create!(
            content: change_desc,
            level: "info"
          )
        end
        true
      else
        false
      end
    end

    return if performed?

    if result
      render json: { success: true, goal: @session.goal }
    else
      render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # Upload images for a session prompt (used via AJAX from the frontend)
  #
  # Accepts images via multipart form upload or base64 JSON data.
  # Stores them temporarily using ImageStorageService.
  #
  # Returns JSON with the stored image paths and metadata for use in follow_up.
  #
  # This action works in two modes:
  # 1. Member route (existing session): Uses the session's ID
  # 2. Collection route (new session): Uses a temp_session_id parameter for pre-upload
  MAX_IMAGES_PER_REQUEST = 20
  MAX_FILES_PER_REQUEST = 200

  def upload_images
    # Determine session ID - either from existing session or temp_session_id param
    if params[:id].present?
      @session = find_session
      session_id = @session.id
    elsif params[:temp_session_id].present?
      # Validate temp_session_id format to prevent abuse
      temp_id = params[:temp_session_id].to_s
      unless temp_id.match?(TEMP_SESSION_ID_PATTERN)
        render json: { error: "Invalid temp_session_id format" }, status: :unprocessable_entity
        return
      end
      session_id = temp_id
    else
      render json: { error: "Session ID or temp_session_id required" }, status: :unprocessable_entity
      return
    end

    # Server-side validation: limit number of images per request
    total_images = (params[:files]&.size || 0) + (params[:images]&.size || 0)
    if total_images > MAX_IMAGES_PER_REQUEST
      render json: { error: "Maximum #{MAX_IMAGES_PER_REQUEST} images allowed per request" }, status: :unprocessable_entity
      return
    end

    images = []

    # Handle file uploads (from file input or drag-drop)
    if params[:files].present?
      params[:files].each do |file|
        result = store_uploaded_image_for(file, session_id)
        images << result if result
      end
    end

    # Handle base64 data (from paste)
    if params[:images].present?
      params[:images].each do |image_data|
        result = store_base64_image_for(image_data, session_id)
        images << result if result
      end
    end

    if images.empty?
      render json: { error: "No valid images provided" }, status: :unprocessable_entity
      return
    end

    render json: { images: images }
  rescue ImageStorageService::ImageStorageError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "Failed to upload images: #{e.message}"
    render json: { error: "Failed to upload images" }, status: :internal_server_error
  end

  # Upload general files for a session prompt (sibling to upload_images).
  #
  # Accepts arbitrary files (text, source code, logs, JSON, CSV, PDFs, etc.) via
  # multipart form upload. Stores them temporarily using FileStorageService.
  #
  # Returns JSON with the stored file paths and metadata for use in follow_up.
  #
  # This action works in two modes:
  # 1. Member route (existing session): Uses the session's ID
  # 2. Collection route (new session): Uses a temp_session_id parameter for pre-upload
  def upload_files
    if params[:id].present?
      @session = find_session
      session_id = @session.id
    elsif params[:temp_session_id].present?
      temp_id = params[:temp_session_id].to_s
      unless temp_id.match?(TEMP_SESSION_ID_PATTERN)
        render json: { error: "Invalid temp_session_id format" }, status: :unprocessable_entity
        return
      end
      session_id = temp_id
    else
      render json: { error: "Session ID or temp_session_id required" }, status: :unprocessable_entity
      return
    end

    incoming = Array(params[:files])
    if incoming.size > MAX_FILES_PER_REQUEST
      render json: { error: "Maximum #{MAX_FILES_PER_REQUEST} files allowed per request" }, status: :unprocessable_entity
      return
    end

    files = []
    incoming.each do |file|
      result = store_uploaded_file_for(file, session_id)
      files << result if result
    end

    if files.empty?
      render json: { error: "No valid files provided" }, status: :unprocessable_entity
      return
    end

    render json: { files: files }
  rescue FileStorageService::FileStorageError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "Failed to upload files: #{e.message}"
    render json: { error: "Failed to upload files" }, status: :internal_server_error
  end

  private

  # Resolve the dashboard view mode for #index, in precedence order:
  #   1. An explicit, valid ?view= param — honored and persisted to a cookie so
  #      the choice survives subsequent navigation back to the dashboard.
  #   2. A previously-persisted valid cookie value (the user's last explicit pick).
  #   3. The default: "last_touched" on mobile, "categories" on desktop. The
  #      default only applies when the user has never explicitly chosen a view.
  def resolve_view_mode
    requested = params[:view].to_s
    if VALID_VIEW_MODES.include?(requested)
      cookies[VIEW_MODE_COOKIE] = { value: requested, expires: 1.year }
      return requested
    end

    persisted = cookies[VIEW_MODE_COOKIE].to_s
    return persisted if VALID_VIEW_MODES.include?(persisted)

    mobile_request? ? VIEW_MODE_LAST_TOUCHED : VIEW_MODE_CATEGORIES
  end

  # Coarse server-side mobile detection used only to pick the default view mode.
  def mobile_request?
    request.user_agent.to_s.match?(MOBILE_USER_AGENT)
  end

  # Parse the scalar ?page= param for the flat (single-list) views. A keyed hash
  # (?page[<id>]=2, used by the per-category paginator) or a malformed array is
  # not a valid scalar page, so it falls back to page 1 (nil).
  def scalar_page_param
    page = params[:page]
    page if page.is_a?(String) || page.is_a?(Integer)
  end

  # True when the current request is a deliberate human page/drawer load, as
  # opposed to passive machinery. We require an HTML request and exclude Turbo's
  # speculative hover-prefetch (it sends X-Sec-Purpose: prefetch; native browser
  # prefetch sends Sec-Purpose: prefetch), which would otherwise count "hovering
  # a link" as a view.
  def human_initiated_view?
    return false unless request.format.html?

    request.headers["X-Sec-Purpose"].to_s.exclude?("prefetch") &&
      request.headers["Sec-Purpose"].to_s.exclude?("prefetch")
  end

  # Check OAuth requirements for MCP servers
  #
  # Checks if any user-selected MCP servers require OAuth authentication
  # and don't have valid credentials stored. Used when MCP servers are
  # added mid-session to detect OAuth requirements upfront.
  #
  # @param session [Session] The session to check
  # @return [Hash] { servers_needing_oauth: Array<Hash> }
  def check_oauth_requirements(session)
    result = { servers_needing_oauth: [] }
    return result if session.user_selected_mcp_servers.blank?

    working_directory = session.metadata&.dig("working_directory")
    return result unless working_directory.present?

    # Use the same logic as AgentSessionJob#check_and_inject_oauth_credentials
    injector = McpOauthCredentialInjector.new(session, working_directory: working_directory)
    status = injector.check_credentials_status

    return result if status.empty?

    oauth_service = McpOauthService.new

    status.each do |server_name, server_status|
      # Skip servers that already have valid credentials
      next if server_status[:has_credential] && server_status[:credential_valid]

      server_url = server_status[:server_url]
      next unless server_url.present?

      if server_status[:requires_reauth]
        result[:servers_needing_oauth] << {
          server_name: server_name,
          server_url: server_url,
          credential_key: server_status[:credential_key],
          preregistered_oauth: server_status[:preregistered_oauth_config]
        }
        next
      end

      # If pre-registered OAuth config exists, OAuth is required
      if server_status[:has_preregistered_oauth]
        result[:servers_needing_oauth] << {
          server_name: server_name,
          server_url: server_url,
          credential_key: server_status[:credential_key],
          preregistered_oauth: server_status[:preregistered_oauth_config]
        }
        next
      end

      # Otherwise, probe the server to check if OAuth is required
      begin
        requirement = oauth_service.check_oauth_requirement(server_url)
        if requirement.required
          result[:servers_needing_oauth] << {
            server_name: server_name,
            server_url: server_url,
            credential_key: server_status[:credential_key],
            oauth_metadata: requirement.metadata
          }
        end
      rescue => e
        Rails.logger.warn "Failed to check OAuth for '#{server_name}': #{e.message}"
        # Don't block on probe failures
      end
    end

    result
  end

  def check_oauth_requirements_for_servers(session, mcp_servers)
    original_mcp_servers = session.mcp_servers
    session.mcp_servers = mcp_servers
    check_oauth_requirements(session)
  ensure
    session.mcp_servers = original_mcp_servers
  end

  # Mark all unread notifications for a session as read
  #
  # Called when a user visits a session page directly (HTML request) to mark
  # any pending notifications as read. This implements "click to view marks as read"
  # behavior without affecting users who just have a latent tab open.
  #
  # Also broadcasts the updated badge count to all connected clients so the
  # notification count updates in real-time across all their open tabs.
  #
  # @param session [Session] The session being viewed
  def mark_session_notifications_read(session)
    # Find all unread, non-stale notifications for this session
    unread_notifications = session.notifications.pending

    return if unread_notifications.empty?

    # Mark them all as read with retry logic for database resilience
    with_db_retry do
      unread_notifications.update_all(read: true)
    end

    # Broadcast updated badge count to all connected clients
    BroadcastService.new.notification_badge(Notification.pending_count)
  end

  # Respond to follow-up form errors with appropriate format
  # For Turbo Stream: Show errors inline and reset form
  # For HTML: Redirect with alert
  def respond_to_follow_up_error(error_message)
    respond_to do |format|
      format.turbo_stream do
        session_skills = ClaudeSkillsCacheService.get_for_session(@session)
        render turbo_stream: [
          turbo_stream.replace(
            "session_#{@session.id}_follow_up_form",
            partial: "sessions/follow_up_form",
            locals: { agent_session: @session, session_skills: session_skills }
          ),
          turbo_stream.update(
            "enqueued_messages_form_errors",
            partial: "enqueued_messages/form_errors",
            locals: { errors: [ error_message ] }
          )
        ]
      end
      format.html do
        redirect_to @session, alert: error_message
      end
    end
  end

  def count_transcript_messages(transcript_content)
    return 0 unless transcript_content.present?

    transcript_content.lines.count do |line|
      line.strip.present? && JSON.parse(line.strip)
    rescue JSON::ParserError
      false
    end
  end

  # Locals for the partials re-rendered after an MCP server change.
  # Mirrors the select-data structure expected by _session_metadata.html.erb and
  # _mobile_mcp_servers.html.erb so they render with edit affordances intact.
  def mcp_partials_locals(session)
    {
      agent_session: session,
      servers_for_select: ServersConfig.all.map { |s| { name: s.name, title: s.title, description: s.description } },
      catalog_skills_for_select: SkillsConfig.all.map { |s| { id: s.id, name: s.name, title: s.title, description: s.description, category: s.category } },
      catalog_hooks_for_select: HooksConfig.all.map { |h| { id: h.id, name: h.name, title: h.title, description: h.description } },
      plugins_for_select: PluginsConfig.all.map { |p| { id: p.id, title: p.title, description: p.description } },
      available_models: ModelCatalog.model_ids_for(session.agent_runtime),
      goals_for_select: GoalsConfig.all.map { |g| { id: g.id, name: g.name, description: g.description } }
    }
  end

  # Regenerate .mcp.json and skills in the session's working directory using AIR CLI.
  # Called after MCP servers are updated to ensure Claude Code uses the new configuration.
  def regenerate_mcp_config_file(session)
    working_directory = session.metadata&.dig("working_directory")
    return unless working_directory.present? && Dir.exist?(working_directory)

    air_service = AirPrepareService.new(
      session: session,
      working_directory: working_directory
    )
    air_service.prepare!

    Rails.logger.info "AIR prepare completed for session #{session.id} at #{working_directory}"
  rescue => e
    # Log the error but don't fail the request - the database was already updated
    Rails.logger.error "Failed to run AIR prepare for session #{session.id}: #{e.message}"
  end

  def get_transcript_directory_for_session(session)
    # Use working_directory (which includes subdirectory) instead of clone_path
    # to match Claude Code's project directory naming
    working_directory = session.metadata&.dig("working_directory")
    clone_path = session.metadata&.dig("clone_path")

    # Prefer working_directory, fall back to clone_path for backwards compatibility
    path_to_use = working_directory || clone_path
    return nil unless path_to_use

    # Validate path is a string and not empty
    return nil unless path_to_use.is_a?(String) && path_to_use.present?

    # Calculate transcript directory using Claude Code's naming convention
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(path_to_use)

    # Build final path
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    Rails.logger.error "Failed to get transcript directory: #{e.message}"
    nil
  end

  # Find the main transcript file for a session, avoiding nested agent transcripts
  # Delegates to TranscriptFileLocator for the shared logic
  def find_main_transcript_file_for_session(session, transcript_dir)
    TranscriptFileLocator.find_main_transcript(session, transcript_dir)
  end

  def session_params
    params.require(:session).permit(:prompt, :git_root, :subdirectory, :branch, :goal, :auto_compact_window, mcp_servers: [], catalog_skills: [], catalog_hooks: [], catalog_plugins: []).tap do |permitted|
      # Drop a blank auto_compact_window so the column default (1M) applies.
      # Codex (and any non-Claude runtime) disables the field, so it submits
      # empty; an empty string would otherwise fail the numericality validation.
      permitted.delete(:auto_compact_window) if permitted[:auto_compact_window].blank?
      permitted[:mcp_servers] = (permitted[:mcp_servers] || []).reject(&:blank?) if permitted.key?(:mcp_servers)
      permitted[:catalog_skills] = (permitted[:catalog_skills] || []).reject(&:blank?) if permitted.key?(:catalog_skills)
      permitted[:catalog_hooks] = (permitted[:catalog_hooks] || []).reject(&:blank?) if permitted.key?(:catalog_hooks)
      permitted[:catalog_plugins] = (permitted[:catalog_plugins] || []).reject(&:blank?) if permitted.key?(:catalog_plugins)
    end
  end

  def load_form_data
    @servers_for_select = ServersConfig.all.map do |server|
      {
        name: server.name,
        title: server.title,
        description: server.description
      }
    end
    @agent_roots = AgentRootsConfig.user_invocable
    @goals = GoalsConfig.all.map do |goal|
      {
        id: goal.id,
        name: goal.name,
        description: goal.description
      }
    end

    # Runtimes available for the runtime selector ({ id:, label: }) — every
    # registered runtime (Claude Code, Codex, …), independent of root defaults.
    @available_runtimes = AgentRootsConfig.available_runtimes
    @runtimes_for_select = @available_runtimes.map do |runtime|
      { id: runtime, label: RuntimeRegistry.label_for(runtime) }
    end

    # Per-runtime model options + defaults, sourced from the authoritative
    # ModelCatalog. The model_select Stimulus controller swaps the model dropdown
    # options when the runtime changes, so adding a runtime is pure data.
    @runtime_models = @available_runtimes.index_with { |runtime| ModelCatalog.model_ids_for(runtime) }
    @runtime_default_models = @available_runtimes.index_with { |runtime| ModelCatalog.default_for(runtime) }

    # Create a mapping of agent root names to their default models
    @agent_root_models = @agent_roots.each_with_object({}) do |agent_root, hash|
      hash[agent_root.name] = agent_root.default_model
    end

    # Create a mapping of agent root names to their default goals
    # We use agent root name as key instead of URL because multiple agent roots
    # can share the same URL (e.g., monorepo with different subdirectories)
    @agent_root_goals = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_goal.present?
        goal = GoalsConfig.find(agent_root.default_goal)
        hash[agent_root.name] = goal&.description if goal
      end
    end

    # Create a mapping of agent root names to their default MCP servers
    # This allows pre-selecting MCP servers when an agent root is selected
    @agent_root_mcp_servers = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_mcp_servers.present?
        # Only include servers that exist in the catalog
        valid_servers = agent_root.default_mcp_servers.select { |name| ServersConfig.exists?(name) }
        hash[agent_root.name] = valid_servers if valid_servers.any?
      end
    end

    # Set defaults from the default agent root
    default_agent_root = AgentRootsConfig.default
    app_setting = AppSetting.current

    # The runtime initially selected on the form: the default root's resolved
    # runtime (which already folds in the global base default), then the global
    # base default for the agent_root-less case, then the registry default.
    @default_runtime = default_agent_root&.default_runtime || app_setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME

    # Model options shown initially are scoped to the default runtime, and the
    # selected default is the root's declared model when it belongs to that
    # runtime's catalog, otherwise the global base default for the runtime.
    @available_models = ModelCatalog.model_ids_for(@default_runtime)
    @default_model =
      if ModelCatalog.valid_model?(@default_runtime, default_agent_root&.default_model)
        default_agent_root.default_model
      else
        app_setting.resolved_default_model_for(@default_runtime)
      end

    # Set default goal for the default agent root
    # The view will check the default agent root, so we need to match that logic
    @default_goal = if default_agent_root&.default_goal.present?
      # Pass the ID, not the description - the JavaScript controller expects an ID
      default_agent_root.default_goal
    end

    # Set default MCP servers for the default agent root
    @default_mcp_servers = if default_agent_root&.default_mcp_servers.present?
      default_agent_root.default_mcp_servers.select { |name| ServersConfig.exists?(name) }
    else
      []
    end

    # Catalog skills for multi-select (from centralized skills catalog)
    # Includes user_invocable so the slash-command typeahead can filter dynamically
    @catalog_skills_for_select = SkillsConfig.all.map do |skill|
      {
        id: skill.id,
        name: skill.name,
        title: skill.title,
        description: skill.description,
        category: skill.category,
        user_invocable: skill.user_invocable
      }
    end

    # Create a mapping of agent root names to their default catalog skills
    @agent_root_catalog_skills = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_skills.present?
        valid_skills = agent_root.default_skills.select { |name| SkillsConfig.exists?(name) }
        hash[agent_root.name] = valid_skills if valid_skills.any?
      end
    end

    # Set default catalog skills for the default agent root
    @default_catalog_skills = if default_agent_root&.default_skills.present?
      default_agent_root.default_skills.select { |name| SkillsConfig.exists?(name) }
    else
      []
    end

    # Catalog hooks for multi-select
    @catalog_hooks_for_select = HooksConfig.all.map do |hook|
      {
        id: hook.id,
        name: hook.name,
        title: hook.title,
        description: hook.description
      }
    end

    # Create a mapping of agent root names to their default catalog hooks
    @agent_root_catalog_hooks = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_hooks.present?
        valid_hooks = agent_root.default_hooks.select { |name| HooksConfig.exists?(name) }
        hash[agent_root.name] = valid_hooks if valid_hooks.any?
      end
    end

    # Set default catalog hooks for the default agent root
    @default_catalog_hooks = if default_agent_root&.default_hooks.present?
      default_agent_root.default_hooks.select { |name| HooksConfig.exists?(name) }
    else
      []
    end

    # Plugins for multi-select (from centralized plugins catalog)
    @plugins_for_select = PluginsConfig.all.map do |plugin|
      {
        id: plugin.id,
        title: plugin.title,
        description: plugin.description
      }
    end

    # Create a mapping of agent root names to their default plugins
    @agent_root_catalog_plugins = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_plugins.present?
        valid_plugins = agent_root.default_plugins.select { |id| PluginsConfig.exists?(id) }
        hash[agent_root.name] = valid_plugins if valid_plugins.any?
      end
    end

    # Set default plugins for the default agent root
    @default_catalog_plugins = if default_agent_root&.default_plugins.present?
      default_agent_root.default_plugins.select { |id| PluginsConfig.exists?(id) }
    else
      []
    end
  end

  # Find session by slug if it looks like a slug, otherwise by ID
  def find_session
    param = params[:id]
    # If param contains only digits, treat as ID
    if param.match?(/\A\d+\z/)
      Session.find(param)
    else
      # Otherwise, try to find by slug first, fall back to ID
      Session.find_by(slug: param) || Session.find(param)
    end
  end

  # JSON payload the heartbeat Stimulus controller reads back after toggling the
  # heartbeat or changing its interval.
  def heartbeat_json
    {
      success: true,
      heartbeat_enabled: @session.heartbeat_enabled,
      heartbeat_interval_seconds: @session.heartbeat_interval_seconds
    }
  end

  # Best-effort reset of the session's GitHub-poll cadence back to the fast
  # (every-cron-tick) end by stamping a fresh user-activity marker. This is a
  # side effect that accompanies a deliberate user interaction (opening a PR,
  # refreshing, pausing, restarting, forking) — it must never break the primary
  # action it rides along with, so a failed stamp (e.g. an invalid record) is
  # swallowed and logged at info; the poll cadence simply stays where it was.
  def reset_poll_backoff(session)
    with_db_retry { session.touch_user_activity! }
  rescue => e
    Rails.logger.info("[reset_poll_backoff] failed to reset poll backoff for session #{session.id}: #{e.class}: #{e.message}")
  end

  def render_restart_turbo_stream
    render turbo_stream: [
      turbo_stream.replace(
        "session_#{@session.id}",
        partial: "sessions/session_card_frame",
        locals: { agent_session: @session }
      ),
      turbo_stream.replace(
        "session_#{@session.id}_header_actions",
        partial: "sessions/session_header_actions",
        locals: { agent_session: @session }
      )
    ]
  end

  # Check if the HTTP referer is the sessions index (home) page
  # Used to determine redirect behavior after toggle_favorite action
  # Must match exactly / or /sessions (with optional query params)
  # but NOT /sessions/123 (individual session show pages)
  # Also validates the referrer host matches to prevent cross-origin false matches
  # Note: We accept both "/" and "/sessions" as valid index paths for backwards compatibility
  # since users may have "/sessions" in their browser history as the referer
  def referrer_is_sessions_index?
    return false unless request.referer.present?

    begin
      referer_uri = URI.parse(request.referer)
      # Ensure same host and path matches either root path (/) or legacy /sessions path
      # The /sessions path redirects to / but browsers may still send it as referer
      referer_uri.host == request.host && [ root_path, "/sessions" ].include?(referer_uri.path)
    rescue URI::InvalidURIError
      false
    end
  end

  # Pause a running session to allow a follow-up prompt to be sent
  # This is used internally by the follow_up action when the session is running.
  # Unlike the public pause action, this method:
  # - Does not redirect (it's called as part of follow_up flow)
  # - Returns a boolean indicating success
  # - Logs the pause as being for a follow-up redirect
  #
  # @return [Boolean] true if pause succeeded, false otherwise
  def pause_for_follow_up
    # Get process PID from session metadata
    process_pid = @session.metadata&.dig("process_pid")

    unless process_pid
      Rails.logger.warn "[SessionsController] Cannot pause session #{@session.id} for follow-up: no process found"
      return false
    end

    begin
      # Log the pause operation
      result = with_db_retry do
        @session.logs.create!(
          content: "Pausing running session to redirect with follow-up prompt (terminating process #{process_pid})",
          level: "info"
        )

        # Update session status to needs_input BEFORE killing the process
        # This prevents race condition where AgentSessionJob detects exit before status update
        @session.pause! if @session.may_pause?
      end

      return false if result == false

      # Use ProcessLifecycleManager.terminate for consistent process termination
      lifecycle_manager = ProcessLifecycleManager.new(
        session: @session,
        process_manager: SystemProcessManager.new
      )

      # Set up the manager with the existing process PID for termination
      stderr_log_path = File.join(@session.metadata&.dig("clone_path") || "", "claude_stderr.log")
      resume_result = lifecycle_manager.resume_monitoring(
        pid: process_pid,
        stderr_log_path: stderr_log_path
      )

      if resume_result.success?
        lifecycle_manager.terminate(reason: :follow_up)
      else
        # Process is already not running - that's fine for our purposes
        with_db_retry do
          @session.logs.create!(
            content: "Process #{process_pid} already terminated",
            level: "info"
          )
        end
      end

      with_db_retry do
        @session.logs.create!(
          content: "Session paused for follow-up redirect",
          level: "info"
        )
      end

      true
    rescue => e
      Rails.logger.error "[SessionsController] Error pausing session #{@session.id} for follow-up: #{e.message}"
      with_db_retry do
        @session.logs.create!(
          content: "Failed to pause session for follow-up: #{e.message}",
          level: "error"
        )
      end
      false
    end
  end

  # Check if a session should have its job restored
  # Returns true if session is running but has no active job
  def should_restore_job?(session)
    return false unless session.running_job_id.present?

    # Check if there's an active job in GoodJob
    job = GoodJob::Job.find_by(active_job_id: session.running_job_id)
    return true unless job # Job doesn't exist anymore

    # Check if job is finished
    return true if job.finished_at.present?

    # Check if job has an error (failed in GoodJob)
    return true if job.error.present?

    # Check if job is orphaned (not locked and not scheduled for the future)
    is_scheduled = job.scheduled_at.present? && job.scheduled_at > Time.current
    is_locked = job.locked_by_id.present?
    return true if !is_scheduled && !is_locked

    false
  end

  # Restore the AgentSessionJob for a session with a running process.
  #
  # NOTE: We intentionally do NOT check Process.kill(0, pid) here.
  # In multi-container deployments (e.g., Kamal), the web container runs in a
  # different PID namespace than the worker container that spawned the Claude CLI
  # process. Process.kill(0, pid) will return ESRCH even though the process is
  # alive in the worker container, causing false "process dead" detection.
  #
  # Instead, we always enqueue a monitoring job (resume_monitoring: true).
  # The AgentSessionJob runs in the same container as the process and can
  # reliably check its status. If the process is dead, it transitions to
  # needs_input; if alive, it reconnects monitoring.
  def restore_agent_session_job(session)
    process_pid = session.metadata&.dig("process_pid")

    unless process_pid
      with_db_retry do
        session.logs.create!(
          content: "Cannot restore job: no process_pid found in session metadata",
          level: "warning"
        )
      end
      return
    end

    with_db_retry do
      session.logs.create!(
        content: "Restoring monitoring job for process #{process_pid} (triggered by refresh)",
        level: "info"
      )

      # Clear the old job ID and enqueue a new monitoring job
      session.update!(running_job_id: nil)

      # Enqueue a new AgentSessionJob to resume monitoring without spawning a new process.
      # The monitoring job will verify process status in the correct PID namespace.
      AgentSessionJob.enqueue_for_monitoring(session.id)

      session.logs.create!(
        content: "Monitoring job enqueued - will verify process status and reconnect if alive",
        level: "info"
      )
    end

    Rails.logger.info "[SessionsController] Enqueued monitoring job for session #{session.id} with process #{process_pid}"
  end

  # Restart a failed session by resuming execution via --resume
  #
  # When the session failed before the initial prompt was ever processed (e.g., MCP
  # server connection failure, spawn failure), the original prompt is re-sent so the
  # agent can start its task from scratch. Otherwise, an automated recovery prompt
  # is sent to nudge the agent to continue where it left off.
  #
  # @param session [Session] The failed session to restart
  # @return [Array<Boolean, String|nil>] [success, error_message] tuple
  def restart_with_continue_prompt(session)
    # When setup never completed (no session_id, no working directory), the session
    # cannot be restarted with a follow-up prompt — there's no clone to send it to.
    # Re-enqueue as a new session to re-run the full setup pipeline (git clone,
    # MCP configuration, skill injection, process spawn).
    if session.failed_before_initial_prompt? && !session.setup_complete?
      return restart_from_scratch(session)
    end

    # For sessions with complete setup artifacts, validate they still exist.
    # The job handles clone recreation if the directory is missing, so we only
    # require session_id here (working_directory absence is handled by the job).
    unless session.session_id.present?
      error_message = "no session_id found"
      with_db_retry do
        session.logs.create!(
          content: "Cannot restart session: #{error_message}",
          level: "warning"
        )
      end
      return [ false, error_message ]
    end

    # Determine if this is a failed session restart or a paused session continuation
    action_description = session.failed? ? "Restarting failed session" : "Continuing paused session"

    # Determine the prompt to send on restart. If the session failed before the
    # initial prompt was ever processed (e.g., MCP connection failure, spawn failure),
    # re-send the original prompt so the agent can start its task. Otherwise, send
    # a system recovery message to nudge the agent to continue.
    # NOTE: This check must happen BEFORE clearing stale metadata (which removes failure_reason).
    use_initial_prompt = session.failed_before_initial_prompt? && session.prompt.present?
    restart_prompt = if use_initial_prompt
      session.prompt
    else
      AutomatedPrompts::SYSTEM_RECOVERY
    end

    # Attempt to restart/continue the session
    result = with_db_retry do
      ActiveRecord::Base.transaction do
        prompt_description = use_initial_prompt ? "re-sending initial prompt" : "sending automated recovery prompt"
        session.logs.create!(
          content: "#{action_description}: #{prompt_description}",
          level: "info"
        )

        # Clear running_job_id and stale retry metadata before enqueuing.
        # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
        cleaned_metadata = (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)

        # For pre-prompt failures (MCP connection failed, spawn failed, etc.),
        # also clear runtime_started so the restart job uses --session-id
        # (with --mcp-config) instead of --resume. Using --resume for a session
        # that never processed its initial prompt causes "No conversation found"
        # errors because the conversation on Anthropic's servers is empty/broken.
        # We don't clear runtime_started for normal restarts because those
        # sessions have real conversation history that --resume can continue.
        if use_initial_prompt
          cleaned_metadata = cleaned_metadata.except("runtime_started")
        end

        session.update!(
          running_job_id: nil,
          metadata: cleaned_metadata
        )
        session.resume! if session.may_resume?

        # Enqueue a job with the chosen prompt to resume execution
        AgentSessionJob.enqueue_with_prompt(session.id, restart_prompt)

        session.logs.create!(
          content: "Session resumed - status changed to running",
          level: "info"
        )
      end
    end

    return [ false, "database operation failed" ] if result == false

    Rails.logger.info "[SessionsController] #{action_description} initiated for session #{session.id}"
    [ true, nil ]
  rescue => e
    Rails.logger.error "[SessionsController] Error resuming session #{session.id}: #{e.message}"
    with_db_retry do
      session.logs.create!(
        content: "Error resuming session: #{e.message}",
        level: "error"
      )
    end
    [ false, e.message ]
  end

  # Restart a session from scratch by re-running the full setup pipeline.
  # Used when a session failed before setup completed (e.g., git clone failed)
  # and there are no setup artifacts to resume from.
  #
  # Clears all setup-related metadata and re-enqueues the session as a new session,
  # which triggers the full setup pipeline: git clone, MCP configuration, skill
  # injection, session_id generation, and process spawn.
  #
  # @param session [Session] The failed session to restart from scratch
  # @return [Array<Boolean, String|nil>] [success, error_message] tuple
  def restart_from_scratch(session)
    unless session.git_root.present?
      error_message = "cannot restart from scratch: no git_root configured"
      with_db_retry do
        session.logs.create!(content: "Cannot restart session: #{error_message}", level: "warning")
      end
      return [ false, error_message ]
    end

    result = with_db_retry do
      ActiveRecord::Base.transaction do
        session.logs.create!(
          content: "Restarting session from scratch: re-running full setup pipeline (git clone, MCP config, process spawn)",
          level: "info"
        )

        # Clear all stale retry metadata AND setup artifacts so the job starts fresh.
        # Setup artifacts (clone_path, working_directory, etc.) are cleared because
        # the previous setup attempt failed partway through and may have left
        # partial/inconsistent state.
        cleaned_metadata = (session.metadata || {}).except(
          *Session::STALE_RETRY_METADATA_KEYS,
          *Session::SETUP_ARTIFACT_KEYS
        )

        session.update!(
          running_job_id: nil,
          session_id: nil,
          metadata: cleaned_metadata
        )
        session.resume! if session.may_resume?

        # Enqueue as a new session (not a follow-up) to trigger the full setup
        # pipeline: git clone, MCP configuration, skill injection, process spawn.
        AgentSessionJob.enqueue_new_session(session.id)

        session.logs.create!(
          content: "Session resumed - status changed to running, full setup will be re-attempted",
          level: "info"
        )
      end
    end

    return [ false, "database operation failed" ] if result == false

    Rails.logger.info "[SessionsController] Restart from scratch initiated for session #{session.id}"
    [ true, nil ]
  rescue => e
    Rails.logger.error "[SessionsController] Error restarting session #{session.id} from scratch: #{e.message}"
    with_db_retry do
      session.logs.create!(
        content: "Error restarting session from scratch: #{e.message}",
        level: "error"
      )
    end
    [ false, e.message ]
  end

  # Resume a failed session by attempting to send an automated recovery prompt
  # @deprecated Use restart_with_continue_prompt instead. This method is kept
  # for backward compatibility with the refresh action.
  #
  # The automated recovery prompt instructs Claude Code CLI to resume the previous
  # task in the same context. This is suitable for transient failures (network issues,
  # temporary errors) but may not be appropriate for failures requiring user
  # intervention (e.g., authentication, permission errors).
  #
  # @param session [Session] The failed session to resume
  # @return [Boolean] true if resume was initiated, false otherwise
  def resume_failed_session(session)
    # Validate session has required metadata
    errors = []
    errors << "no session_id found" unless session.session_id.present?

    working_directory = session.metadata&.dig("working_directory")
    errors << "working directory not found or invalid" unless working_directory.present? && Dir.exist?(working_directory)

    if errors.any?
      with_db_retry do
        session.logs.create!(
          content: "Cannot resume failed session: #{errors.join(', ')}",
          level: "warning"
        )
      end
      return false
    end

    # Check if there's a process still running (edge case)
    if session.metadata&.dig("process_pid")
      process_pid = session.metadata["process_pid"].to_i
      begin
        # Check if process is still alive (signal 0 doesn't actually send a signal)
        Process.kill(0, process_pid)
        # Process is still running - don't resume
        with_db_retry do
          session.logs.create!(
            content: "Cannot resume: process #{process_pid} is still running",
            level: "warning"
          )
        end
        return false
      rescue Errno::ESRCH, Errno::EPERM
        # Process is not running or not accessible, safe to continue
      end
    end

    # Check for recent resume attempts to prevent spam
    recent_resume_attempt = session.logs.where(
      "content LIKE ? AND created_at > ?",
      "%Attempting to resume failed session%",
      1.minute.ago
    ).exists?

    if recent_resume_attempt
      with_db_retry do
        session.logs.create!(
          content: "Resume attempted too recently - please wait before retrying",
          level: "warning"
        )
      end
      return false
    end

    # Determine the prompt to send on resume. If the session failed before the
    # initial prompt was ever processed, re-send the original prompt.
    # NOTE: This check must happen BEFORE clearing stale metadata (which removes failure_reason).
    use_initial_prompt = session.failed_before_initial_prompt? && session.prompt.present?
    restart_prompt = use_initial_prompt ? session.prompt : AutomatedPrompts::SYSTEM_RECOVERY

    # Attempt to resume the session
    # Use transaction for atomicity like follow_up action
    result = with_db_retry do
      ActiveRecord::Base.transaction do
        prompt_description = use_initial_prompt ? "re-sending initial prompt" : "automated recovery prompt"
        session.logs.create!(
          content: "Attempting to resume failed session with #{prompt_description}",
          level: "info"
        )

        # Clear stale retry metadata for fresh execution.
        # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
        cleaned_metadata = (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)

        # For pre-prompt failures, also clear runtime_started so the job
        # uses --session-id (with --mcp-config) instead of --resume.
        cleaned_metadata = cleaned_metadata.except("runtime_started") if use_initial_prompt

        session.update!(metadata: cleaned_metadata)

        # Update session status to running BEFORE enqueuing the job
        # This ensures the resume! callback clears custom_metadata MCP flags
        # before the job starts and potentially reads should_fail_session
        session.resume! if session.may_resume?

        # Enqueue a job with the chosen prompt to resume execution
        AgentSessionJob.enqueue_with_prompt(session.id, restart_prompt)

        session.logs.create!(
          content: "Resume command initiated - session status changed to running",
          level: "info"
        )
      end
    end

    return false if result == false

    Rails.logger.info "[SessionsController] Resume initiated for failed session #{session.id}"
    true
  rescue => e
    Rails.logger.error "[SessionsController] Error resuming failed session #{session.id}: #{e.message}"
    with_db_retry do
      session.logs.create!(
        content: "Error resuming failed session: #{e.message}",
        level: "error"
      )
    end
    false
  end

  # Build a combined timeline of messages and logs, sorted by time
  # @param session [Session] The session to build timeline for
  # @param logs [ActiveRecord::Relation] The logs to include
  # @return [Array<Hash>] Array of timeline items sorted by sort_time
  def build_timeline_items(session, logs)
    timeline_items = []

    # Add conversation messages from raw transcript. One transcript entry may
    # normalize into several OpenTranscripts events (see OpenTranscript).
    transcript_entries = session.parsed_transcript
    if transcript_entries.present?
      transcript_entries.each_with_index do |entry, index|
        timeline_items.concat(build_transcript_timeline_item(entry, index, session))
      end
    end

    # Add activity logs
    logs.each do |log|
      timeline_items << build_log_timeline_item(log)
    end

    # Stable sort by timestamp (preserves intra-entry fan-out order).
    OpenTranscript.sort_events(timeline_items)
  end

  # Build timeline items from only the tail of the data sources.
  # Loads the last `buffer` transcript entries and last `buffer` logs,
  # merges and sorts them. This avoids loading the entire history for
  # sessions with hundreds of thousands of items.
  #
  # @param session [Session] The session
  # @param filter_level [String] The active filter level (for smart buffer sizing)
  # @param buffer [Integer] How many items to fetch from each source
  # @return [Array<Hash>] Timeline items from the tail, sorted by time
  def build_timeline_items_tail(session, filter_level, buffer)
    timeline_items = []

    # Load last N transcript entries (without parsing the full transcript)
    transcript_entries, _total = session.parsed_transcript_tail(buffer)
    if transcript_entries.present?
      transcript_entries.each do |entry|
        timeline_items.concat(build_transcript_timeline_item(entry, entry["_transcript_index"] || 0, session))
      end
    end

    # Load last N logs via efficient SQL query (DESC + LIMIT + reverse)
    # Only load logs if the filter level would show them
    if filter_level == "show-logs" || filter_level == "verbose"
      recent_logs = session.logs.order(created_at: :desc).limit(buffer).to_a.reverse
      recent_logs.each do |log|
        timeline_items << build_log_timeline_item(log)
      end
    end

    OpenTranscript.sort_events(timeline_items)
  end

  # Build timeline items before a given timestamp cursor.
  # Used for efficient infinite scroll pagination without loading the entire history.
  #
  # The transcript is always parsed fully (typically hundreds to low thousands of entries,
  # taking <0.5s even for large sessions). The optimization is on log loading: instead of
  # loading 280K+ logs, we use a SQL WHERE + LIMIT to fetch only logs before the cursor.
  #
  # @param session [Session] The session
  # @param filter_level [String] The active filter level
  # @param limit [Integer] Number of filtered items to return
  # @param before_ts [Time] Only include items before this timestamp
  # @return [Array(Array<Hash>, Boolean, Time)] [items, has_more, next_cursor_timestamp]
  def build_timeline_items_before_timestamp(session, filter_level, limit, before_ts)
    fetch_buffer = limit * 3

    timeline_items = []

    # Parse full transcript — this is fast (hundreds to low thousands of entries).
    # Filter to only entries before the cursor timestamp.
    transcript_entries = session.parsed_transcript
    if transcript_entries.present?
      transcript_entries.each_with_index do |entry, index|
        build_transcript_timeline_item(entry, index, session).each do |event|
          timeline_items << event if event[:sort_time] < before_ts
        end
      end
    end

    # Load logs before the cursor timestamp via efficient SQL query
    if filter_level == "show-logs" || filter_level == "verbose"
      logs_before = session.logs
        .where("created_at < ?", before_ts)
        .order(created_at: :desc)
        .limit(fetch_buffer)
        .to_a.reverse

      logs_before.each do |log|
        timeline_items << build_log_timeline_item(log)
      end
    end

    timeline_items = OpenTranscript.sort_events(timeline_items)
    filtered = filter_timeline_items(timeline_items, filter_level)

    # Take the last `limit` filtered items (closest to the cursor)
    if filtered.count > limit
      items = filtered.last(limit)
      has_more = true
      next_cursor = items.first[:sort_time]
    else
      items = filtered
      # Check if there are still older logs we didn't fetch
      has_more = if filter_level == "show-logs" || filter_level == "verbose"
        session.logs.where("created_at < ?", items.first&.dig(:sort_time) || before_ts).exists?
      else
        false # For minimal/condensed, we loaded all transcript entries
      end
      next_cursor = items.first&.dig(:sort_time)
    end

    [ items, has_more, next_cursor ]
  end

  # Compute the total count of filtered timeline items efficiently,
  # without loading all data into memory.
  #
  # For filters that don't include logs (minimal, condensed), this is just
  # a count of matching transcript entries, which requires scanning transcript
  # lines but NOT loading logs from the DB.
  #
  # For filters that include logs, we add a SQL COUNT for the appropriate log levels.
  #
  # @param session [Session] The session
  # @param filter_level [String] One of VALID_FILTER_LEVELS
  # @return [Integer] Estimated total count of filtered timeline items
  def compute_filtered_count(session, filter_level)
    # Count transcript entries by category. For minimal/condensed filters,
    # we need to know which entries are regular messages vs tool-use messages.
    # We do a lightweight scan of transcript lines, parsing only enough to
    # determine the category (checking for tool_use/tool_result in content).
    transcript_count = count_transcript_entries_for_filter(session, filter_level)

    # Count logs by level using SQL (fast with index)
    log_count = case filter_level
    when "minimal", "condensed"
      0 # These filters don't show logs
    when "show-logs"
      session.logs.where.not(level: "verbose").count
    else # verbose
      session.logs.count
    end

    transcript_count + log_count
  end

  # Count transcript events that would be visible for a given filter level.
  #
  # Because one transcript entry can fan out into several OpenTranscripts events
  # (e.g. an assistant line -> AssistantMessage + ToolCall) with different filter
  # categories, the count must reflect events, not raw lines. We normalize the
  # full transcript and count visible events using the same predicate the renderer
  # uses, so the displayed total matches what is actually shown. Transcript
  # entries number in the hundreds to low thousands, so this full parse is cheap
  # (logs — the 280K+ concern — are counted separately via SQL in
  # compute_filtered_count).
  #
  # @param session [Session] The session
  # @param filter_level [String] One of VALID_FILTER_LEVELS
  # @return [Integer] Count of matching transcript events
  def count_transcript_entries_for_filter(session, filter_level)
    entries = session.parsed_transcript
    return 0 if entries.blank?

    normalizer = TranscriptRuntime.normalizer_for(session)
    count = 0
    entries.each_with_index do |entry, index|
      normalizer.normalize(entry, session: session, transcript_index: index).each do |event|
        count += 1 if item_visible_for_filter?(event, filter_level)
      end
    end
    count
  end

  # Normalize a transcript entry into zero or more OpenTranscripts events via the
  # runtime normalizer. Returns an Array (see TranscriptNormalizer#normalize).
  # Shared between build_timeline_items and the optimized tail/cursor methods.
  def build_transcript_timeline_item(entry, index, session)
    TranscriptRuntime.normalizer_for(session).normalize(entry, session: session, transcript_index: index)
  end

  # Build a timeline item hash from a Log record.
  def build_log_timeline_item(log)
    {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: log.created_at,
      sort_time: log.created_at
    }
  end

  # Filter timeline items based on filter level
  # This mirrors the client-side filtering logic to ensure server and client agree
  # on which items are visible for a given filter level.
  #
  # Filter levels:
  # - minimal: Only regular messages (no tool-use/result messages, no logs)
  # - condensed: All messages including tool-use/result (no logs)
  # - show-logs: All messages and regular logs (no verbose logs)
  # - verbose: Everything
  #
  # @param items [Array<Hash>] Timeline items from build_timeline_items
  # @param filter_level [String] One of VALID_FILTER_LEVELS
  # @return [Array<Hash>] Filtered timeline items
  def filter_timeline_items(items, filter_level)
    items.select do |item|
      item_visible_for_filter?(item, filter_level)
    end
  end

  # Check if a timeline item should be visible for the given filter level
  # This logic must match the JavaScript filtering in log_level_filter_controller.js
  # and infinite_scroll_controller.js
  #
  # @param item [Hash] A timeline item hash
  # @param filter_level [String] One of VALID_FILTER_LEVELS
  # @return [Boolean] true if item should be visible
  def item_visible_for_filter?(item, filter_level)
    # A content-less message event (e.g. a Claude assistant line carrying only
    # tool_use/thinking blocks) never surfaces a row, regardless of filter level.
    # Excluding it here keeps the displayed total and the initial-limit slotting
    # in sync with what the renderer actually draws (which suppresses the same
    # events via OpenTranscript.blank_message?).
    return false if OpenTranscript.blank_message?(item)

    # Single source of truth for category mapping (also used by _item.html.erb's
    # data-filter-category and the client-side log_level_filter controller).
    category = OpenTranscript.filter_category(item)

    case filter_level
    when "minimal"
      # Only regular messages (not tool-use/result, not queue events)
      category == "message"
    when "condensed"
      # All messages (including tool-use/result and queue events), no logs
      %w[message tool-message queue-event].include?(category)
    when "show-logs"
      # All messages and regular logs, no verbose logs
      %w[message tool-message queue-event regular-log].include?(category)
    else
      # verbose: everything is visible
      true
    end
  end

  # Format the session transcript for copying to clipboard
  # Returns a nicely formatted text suitable for pasting into a new conversation
  #
  # The format is designed to:
  # - Be human-readable
  # - Preserve the conversation structure
  # - Include all relevant content (text, tool calls, tool results)
  # - Be suitable for continuing the conversation in a new session
  #
  # @param session [Session] The session to format
  # @return [String] Formatted transcript text
  def format_transcript_for_copy(session)
    entries = session.parsed_transcript
    return "" if entries.blank?

    formatted_parts = []

    entries.each do |entry|
      message_data = entry["message"] || entry
      role = message_data["role"] || entry["type"]

      # Skip non-conversation entries (system events, file history, etc.)
      next if role.nil? && entry["type"].present? && !%w[user assistant].include?(entry["type"])

      # Determine the speaker label
      label = case role
      when "user"
        "User"
      when "assistant"
        "Assistant"
      else
        # Handle Claude Code transcript events
        case entry["type"]
        when "user" then "User"
        when "assistant" then "Assistant"
        else next # Skip other event types
        end
      end

      # Format the content
      content = format_message_content_for_copy(message_data)
      next if content.blank?

      formatted_parts << "[#{label}]\n#{content}"
    end

    formatted_parts.join("\n\n---\n\n")
  end

  # Format a single message's content for copy
  # Handles both simple text content and structured content blocks
  #
  # @param message [Hash] The message data
  # @return [String] Formatted content
  def format_message_content_for_copy(message)
    content = message["content"]

    # Handle simple string content
    return content if content.is_a?(String)

    # Handle flat format where text is at top level
    return message["text"] if content.nil? && message["text"].present?

    # Handle array content (structured format)
    return "" unless content.is_a?(Array) && content.any?

    parts = content.map do |block|
      format_content_block_for_copy(block)
    end

    parts.compact.reject(&:blank?).join("\n\n")
  end

  # Format a single content block for copy
  #
  # @param block [Hash] The content block
  # @return [String, nil] Formatted content or nil
  def format_content_block_for_copy(block)
    return nil unless block.is_a?(Hash)

    case block["type"]
    when "text"
      block["text"]
    when "tool_use"
      format_tool_use_for_copy(block)
    when "tool_result"
      format_tool_result_for_copy(block)
    when "thinking"
      # Include thinking blocks as they can be useful context
      thinking = block["thinking"]
      thinking.present? ? "[Thinking]\n#{thinking}" : nil
    else
      nil
    end
  end

  # Format a tool_use block for copy
  #
  # @param block [Hash] The tool_use block
  # @return [String] Formatted tool use
  def format_tool_use_for_copy(block)
    tool_name = block["name"] || "Unknown Tool"
    input = block["input"] || {}

    parts = [ "[Tool Use: #{tool_name}]" ]

    if input.any?
      # Format input parameters, handling special cases
      input.each do |key, value|
        formatted_value = case value
        when String
          # For multi-line strings (like code), preserve them
          value.include?("\n") ? "\n#{value}" : value
        when Array, Hash
          JSON.pretty_generate(value)
        else
          value.to_s
        end
        parts << "#{key}: #{formatted_value}"
      end
    end

    parts.join("\n")
  end

  # Format a tool_result block for copy
  #
  # @param block [Hash] The tool_result block
  # @return [String] Formatted tool result
  def format_tool_result_for_copy(block)
    content = block["content"]
    is_error = block["is_error"]

    prefix = is_error ? "[Tool Result (Error)]" : "[Tool Result]"

    result_text = case content
    when String
      content
    when Array
      # Handle structured content in tool results
      content.filter_map do |item|
        item["text"] if item.is_a?(Hash) && item["type"] == "text"
      end.join("\n")
    else
      content.to_s
    end

    "#{prefix}\n#{result_text}"
  end

  # Parse image parameters from the follow_up form
  #
  # Images are passed as a JSON array of objects with path and media_type keys.
  # These are populated by the JavaScript controller after calling upload_images.
  #
  # @return [Array<Hash>, nil] Array of { path:, media_type: } or nil if no images
  def parse_image_params
    return nil unless params[:images].present?

    begin
      image_data = if params[:images].is_a?(String)
        JSON.parse(params[:images])
      else
        params[:images].to_a
      end

      return nil if image_data.empty?

      # Convert to array of hashes with symbolized keys
      # Validate that each image still exists in storage
      storage = ImageStorageService.new(session_id: @session.id)

      image_data.filter_map do |img|
        path = img["path"] || img[:path]
        media_type = img["media_type"] || img[:media_type]

        next unless path.present? && media_type.present?
        next unless storage.exists?(path)

        { path: path, media_type: media_type }
      end.presence
    rescue JSON::ParserError => e
      Rails.logger.warn "Failed to parse image params: #{e.message}"
      nil
    end
  end

  # Store an uploaded file as an image
  #
  # @param file [ActionDispatch::Http::UploadedFile] The uploaded file
  # @return [Hash, nil] { path:, media_type:, size:, filename: } or nil if invalid
  def store_uploaded_image(file)
    store_uploaded_image_for(file, @session.id)
  end

  # Store an uploaded file as an image for a specific session ID
  #
  # @param file [ActionDispatch::Http::UploadedFile] The uploaded file
  # @param session_id [Integer, String] The session ID (integer or temp_<uuid> string)
  # @return [Hash, nil] { path:, media_type:, size:, filename: } or nil if invalid
  def store_uploaded_image_for(file, session_id)
    return nil unless file.respond_to?(:read)

    storage = ImageStorageService.new(session_id: session_id)
    result = storage.store(uploaded_file: file)

    {
      path: result[:path],
      media_type: result[:media_type],
      size: result[:size],
      filename: result[:filename]
    }
  rescue ImageStorageService::InvalidImageError => e
    Rails.logger.warn "Invalid image upload: #{e.message}"
    nil
  end

  # Store a base64-encoded image
  #
  # @param image_data [Hash, ActionController::Parameters] { data:, filename: }
  # @return [Hash, nil] { path:, media_type:, size:, filename: } or nil if invalid
  def store_base64_image(image_data)
    store_base64_image_for(image_data, @session.id)
  end

  # Store a base64-encoded image for a specific session ID
  #
  # @param image_data [Hash, ActionController::Parameters] { data:, filename: }
  # @param session_id [Integer, String] The session ID (integer or temp_<uuid> string)
  # @return [Hash, nil] { path:, media_type:, size:, filename: } or nil if invalid
  def store_base64_image_for(image_data, session_id)
    data = image_data[:data] || image_data["data"]
    filename = image_data[:filename] || image_data["filename"]

    return nil unless data.present?

    # Strip data URL prefix if present (e.g., "data:image/png;base64,...")
    base64_data = data.sub(/\Adata:[^;]+;base64,/, "")

    storage = ImageStorageService.new(session_id: session_id)
    result = storage.store(data: base64_data, filename: filename)

    {
      path: result[:path],
      media_type: result[:media_type],
      size: result[:size],
      filename: result[:filename]
    }
  rescue ImageStorageService::InvalidImageError => e
    Rails.logger.warn "Invalid base64 image: #{e.message}"
    nil
  end

  # Parse file parameters from the follow_up form.
  #
  # Files are passed as a JSON array of objects with path and original_filename keys
  # (populated by file_attachment_controller after calling upload_files).
  #
  # @return [Array<Hash>, nil] Array of { path:, original_filename:, size: } or nil
  def parse_file_params
    return nil unless params[:files_payload].present?

    begin
      file_data = if params[:files_payload].is_a?(String)
        JSON.parse(params[:files_payload])
      else
        params[:files_payload].to_a
      end

      return nil if file_data.empty?

      storage = FileStorageService.new(session_id: @session.id)

      file_data.filter_map do |f|
        path = f["path"] || f[:path]
        original_filename = f["original_filename"] || f[:original_filename]
        size = f["size"] || f[:size]

        next unless path.present? && original_filename.present?
        next unless storage.exists?(path)

        { path: path, original_filename: original_filename, size: size }
      end.presence
    rescue JSON::ParserError => e
      Rails.logger.warn "Failed to parse file params: #{e.message}"
      nil
    end
  end

  # Store an uploaded file (general-purpose attachment) for a specific session ID.
  #
  # @param file [ActionDispatch::Http::UploadedFile] The uploaded file
  # @param session_id [Integer, String] The session ID (integer or temp_<uuid> string)
  # @return [Hash, nil] { path:, original_filename:, size: } or nil if invalid
  def store_uploaded_file_for(file, session_id)
    return nil unless file.respond_to?(:read)

    storage = FileStorageService.new(session_id: session_id)
    storage.store(uploaded_file: file)
  rescue FileStorageService::InvalidFileError => e
    Rails.logger.warn "Invalid file upload: #{e.message}"
    nil
  end

  # Stage uploaded images/files into the temp session dir. Raises a concrete
  # storage error if any uploaded entry is rejected by validation, so callers
  # can surface the rejection to the user (rather than silently dropping the
  # attachment and creating a session with no files).
  def stage_uploads_or_raise!(images, files, temp_session_id)
    images.each do |f|
      next unless f.respond_to?(:read)
      result = store_uploaded_image_for(f, temp_session_id)
      if result.nil?
        raise ImageStorageService::InvalidImageError,
              "Image #{f.try(:original_filename) || "attachment"} was rejected (unsupported format or too large)"
      end
    end
    files.each do |f|
      next unless f.respond_to?(:read)
      result = store_uploaded_file_for(f, temp_session_id)
      if result.nil?
        raise FileStorageService::InvalidFileError,
              "File #{f.try(:original_filename) || "attachment"} was rejected (too large)"
      end
    end
  end

  # Copy staged temp uploads into the persisted session's storage and write a
  # log line summarizing what was attached. Returns [images, files] arrays
  # (each suitable for AgentSessionJob.enqueue_new_session).
  def copy_staged_uploads_to_session(temp_session_id, session, log_prefix:)
    images_to_attach = ImageStorageService.copy_from_temp(
      temp_session_id: temp_session_id,
      new_session_id: session.id
    )
    files_to_attach = FileStorageService.copy_from_temp(
      temp_session_id: temp_session_id,
      new_session_id: session.id
    )
    attached = []
    attached << "#{images_to_attach.size} image(s)" if images_to_attach.present?
    attached << "#{files_to_attach.size} file(s)" if files_to_attach.present?
    if attached.any?
      session.logs.create!(
        content: "Attached #{attached.join(", ")} to #{log_prefix}",
        level: "info"
      )
    end
    [ images_to_attach, files_to_attach ]
  end

  # Cleanup orphaned temporary session files.
  # Called when session creation fails to prevent disk space leaks.
  def cleanup_temp_session_files(temp_session_id)
    return unless temp_session_id.present? && temp_session_id.match?(TEMP_SESSION_ID_PATTERN)

    FileStorageService.new(session_id: temp_session_id).cleanup!
  rescue => e
    Rails.logger.warn "Failed to cleanup temp session files for #{temp_session_id}: #{e.message}"
  end

  # Cleanup orphaned temporary session images
  # Called when session creation fails to prevent disk space leaks
  #
  # @param temp_session_id [String, nil] The temporary session ID
  def cleanup_temp_session_images(temp_session_id)
    return unless temp_session_id.present? && temp_session_id.match?(TEMP_SESSION_ID_PATTERN)

    ImageStorageService.new(session_id: temp_session_id).cleanup!
  rescue => e
    Rails.logger.warn "Failed to cleanup temp session images for #{temp_session_id}: #{e.message}"
  end
end
