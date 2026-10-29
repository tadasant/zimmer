class SessionsController < ApplicationController
  require "path_sanitizer"
  require "automated_prompts"
  include ActionView::RecordIdentifier
  include WebUiHumanMessageCapture
  include SessionSearchable
  include PendingMessageDelivery
  include SpeculativeRequest
  include TurboFlash

  # Pattern for validating temporary session IDs used for pre-session image uploads
  TEMP_SESSION_ID_PATTERN = /\Atemp_[a-f0-9\-]+\z/

  # Server-side cap on page context to prevent unbounded prompt inflation
  PAGE_CONTEXT_MAX_LENGTH = QuickRouterPrompt::PAGE_CONTEXT_MAX_LENGTH

  # Dashboard: number of session rows shown per page of the flat views.
  SESSIONS_PER_PAGE = 50

  # How many transcript matches one content search collects before it stops. Two
  # pages' worth: enough that the dashboard's own pagination has somewhere to go,
  # bounded because every additional match costs another transcript detoasted.
  CONTENT_SEARCH_LIMIT = SESSIONS_PER_PAGE * 2

  # Dashboard view modes.
  #
  # "user" is the default and the dashboard's centre of gravity: one unified list
  # of every session the filters match, each row carrying enough — status, root,
  # the generated status blurb, the PR and its CI colour — that a decision can be
  # taken ON the row. Trash, Snooze and Merge are all inline, so the board is
  # worked top to bottom without opening a session.
  #
  # It REPLACES the old "categories" grid, which asked the operator to open a
  # card to learn anything about it.
  VIEW_MODE_USER = "user".freeze
  # The two flat modes flatten the presentation into a single list sorted solely
  # by one factor — no grouping, no custom ordering, no pinned float.
  VIEW_MODE_LAST_TOUCHED = "last_touched".freeze
  VIEW_MODE_CREATED_DESC = "created_desc".freeze
  # The spot queue, in the order it will be worked. Not a sort of the same grid:
  # it is a two-section list (priority above, spot below, ranked) whose rows are
  # editable — this is where a queue is MANAGED rather than read.
  VIEW_MODE_RANKED = "ranked".freeze
  VALID_VIEW_MODES = [ VIEW_MODE_USER, VIEW_MODE_LAST_TOUCHED, VIEW_MODE_CREATED_DESC, VIEW_MODE_RANKED ].freeze

  # Cookie values a previous release wrote that no longer name a view. Remapped
  # rather than dropped, so an operator who had deliberately chosen the grid lands
  # on the view that replaced it instead of silently on the mobile default.
  LEGACY_VIEW_MODES = { "categories" => VIEW_MODE_USER }.freeze

  # Cookie that persists an explicitly-chosen view mode across navigation. Only
  # written when the user picks a view via ?view=; absent until then so the
  # mobile/desktop default applies.
  VIEW_MODE_COOKIE = :sessions_view

  # The statuses the dashboard's Filters section offers, in lifecycle order. The
  # multi-select is the ONLY control over which statuses appear — including
  # `archived`, which is the trash. There is deliberately no second trash toggle
  # arguing with it.
  STATUS_FILTER_OPTIONS = %w[waiting running needs_input failed archived].freeze

  # What the dashboard shows before the user has chosen anything. The dashboard is
  # an action queue and `needs_input` is the only status that is actually waiting on
  # a human, so every view opens on those cards alone.
  DEFAULT_STATUS_FILTER = %w[needs_input].freeze

  # Every status except the trash, as the "All Unarchived" quick filter selects
  # them. Derived from the options list so a new status joins it automatically.
  UNARCHIVED_STATUSES = (STATUS_FILTER_OPTIONS - %w[archived]).freeze

  # …except the Ranked view, whose whole subject is work that has NOT run yet.
  # Opening it on `needs_input` alone would show an empty queue and hide the
  # `waiting` sessions it exists to order. Still only a default: an explicitly
  # submitted filter wins here exactly as it does everywhere else.
  DEFAULT_RANKED_STATUS_FILTER = %w[waiting running needs_input failed].freeze

  # How many rows each section of the Ranked view renders. There is no paginator
  # there on purpose — a drag between two rows means nothing if one of them is on
  # another page — so this is a cap, and the view says when it has truncated.
  RANKED_SECTION_LIMIT = 200

  # How many rows the User view renders. Same reasoning as RANKED_SECTION_LIMIT —
  # a drag between two rows means nothing if one of them is on another page, so
  # there is no paginator and the view says when it has truncated — but the number
  # is an order of magnitude larger, because this view's whole job is to show
  # EVERYTHING the filters match. The default filter (`needs_input` alone) is the
  # population it exists for, and that is tens of rows, not hundreds.
  #
  # It is a safety rail rather than a target: each row costs one <li> with no
  # nested frames and no per-row query (the status summary comes from an
  # eager-loaded join), so a full 500 renders in well under a second.
  # Past that the drag-and-drop and the browser's own layout, not the server, are
  # what degrade.
  USER_VIEW_LIMIT = 500

  # The Filters section's board-visibility control — the reveal affordance for the
  # second, presentation-only axis. "On board" is the default and hides the
  # sessions the operator has tucked away; the other two are how a hidden session
  # is always findable again, so nothing here is ever unrecoverable.
  #
  # This narrows nothing else. A snoozed session is running, queued and ranked
  # exactly as it was — the filter decides what is drawn and stops there. The
  # values are SessionVisibility's, shared with the REST listings and the MCP
  # search so all three spell the filter the same way.
  VISIBILITY_ON_BOARD = SessionVisibility::FILTER_ON_BOARD
  VISIBILITY_OFF_BOARD = SessionVisibility::FILTER_OFF_BOARD
  VISIBILITY_ALL = SessionVisibility::FILTER_ALL
  VISIBILITY_FILTER_OPTIONS = SessionVisibility::FILTER_OPTIONS
  # The driver's triage axis. "" is the dashboard's default: unfiltered, every
  # row regardless of mark, exactly as the REST and MCP listings default.
  CARPLAY_FIT_FILTER_OPTIONS = SessionCarplayFit::FILTER_OPTIONS

  # Cookie that persists an explicit Filters choice (statuses + scheduling class),
  # so the selection survives a reload and a bare visit to "/" rather than snapping
  # back to the default. Written only when the Filters form is submitted; cleared by
  # "Reset filters". Same shape of preference as VIEW_MODE_COOKIE above.
  FILTERS_COOKIE = :sessions_filters

  # Hidden marker the Filters form submits. Its presence is what separates "the user
  # submitted the form with no status ticked" — an explicit *show everything* — from
  # "this request carries no filter params at all", where the persisted choice or the
  # default applies. Without it those two cases are the same request.
  FILTERS_SUBMITTED_PARAM = "filters"

  # User agents we treat as "mobile" for the purpose of choosing a default view.
  # This only affects the default when the user has not explicitly chosen a view;
  # the choice is always overridable and persisted, so a coarse heuristic is fine.
  MOBILE_USER_AGENT = /Mobile|Android|iPhone|iPod|IEMobile|BlackBerry|Opera Mini/i

  # No per-user authorization here, by design.
  #
  # Zimmer is a single circle of trust: everyone who can reach the host is the
  # same "user". There is no User model, no login, and no owner column on
  # Session — so there is no principal for a policy object to compare against
  # and nothing an ACL could separate. The authentication boundary is the
  # network perimeter (the tailnet, with port 80 closed at the firewall), not a
  # permission check in this controller.
  #
  # This is the product's shape, not an unfinished task. Adding Pundit or
  # CanCanCan here would invent a distinction Zimmer does not make, and would
  # read as protection that isn't there. If you want a second wall, put it at
  # the perimeter.
  #
  # See docs/src/content/docs/intro/philosophy.md and
  # docs/src/content/docs/auth/overview.md — published at
  # https://docs.zimmer.tadasant.com/intro/philosophy/ and
  # https://docs.zimmer.tadasant.com/auth/overview/.

  before_action :load_form_data, only: %i[new create]

  # GET /
  #
  # The dashboard's shell: header, menu, Filters, the Quick Router and the view
  # switcher. It reads params and cookies and nothing else, so it answers in
  # milliseconds however many sessions the board holds. The board itself — every
  # query and every row — is #board, which the shell's <turbo-frame
  # id="sessions_board"> loads the moment the page arrives.
  #
  # Split because the board is the expensive half by a wide margin: a few hundred
  # User-view rows are most of a second of rendering, and a page that waited on
  # them would show nothing at all until the last row was done.
  def index
    # "Reset filters" drops the persisted choice and lands the user back on a bare
    # dashboard, so it has to happen before anything reads the cookie.
    return if reset_filters!

    resolve_dashboard_inputs

    # Roots offered in the Advanced Search agent-root autocomplete. Sourced from the
    # full catalog (not just user-invocable roots) so sessions from any root can be
    # filtered, sorted by name for a stable list.
    @agent_roots_for_filter = AgentRootsConfig.all.sort_by(&:name)
  end

  # GET /board
  #
  # The dashboard's board: the session rows for whichever view the shell is
  # showing, wrapped in <turbo-frame id="sessions_board"> and rendered without
  # the layout. Takes exactly the params "/" does — the shell passes its own
  # query string through — and resolves them through the same methods, so the
  # two halves of the page cannot disagree about the filters.
  #
  # A separate PATH rather than a Turbo-Frame-header variant of "/", for the
  # reason #drawer gives: Turbo's prefetch cache is keyed on URL alone, and would
  # hand a frame load of "/" the shell it prefetched on hover.
  def board
    resolve_dashboard_inputs
    load_dashboard_board
    render layout: false
  end

  def new
    @session = Session.new
  end

  def create
    @session = Session.new(session_params)
    # The new-session form is a human at a keyboard in the Zimmer web app.
    @session.genesis = SessionGenesis::WEB_UI
    @session.source_context = web_turn_source.to_h

    # The form always submits an mcp_servers key (the multi-select emits a blank
    # hidden input when nothing is selected), so an empty list here is a user who
    # deliberately picked no servers. Recorded before save so McpServerBackfill
    # doesn't read the empty column as an accident and restore the root's
    # defaults when the job starts.
    @session.record_explicit_mcp_servers(@session.mcp_servers) if session_params.key?(:mcp_servers)

    # Check if this is a clone-only session (no prompt)
    is_clone_only = @session.prompt.blank?

    # Set status based on whether this is clone-only or not
    # Clone-only sessions go straight to needs_input, ready for follow-up prompts
    # Note: We set status directly here since the session hasn't been saved yet
    # and the state machine is initialized after save. For clone-only sessions,
    # the default :waiting state will remain (needs_input comes from the state machine default).
    # Actually, AASM sets the initial state to :waiting by default, so we need to handle this correctly.
    @session.status = is_clone_only ? :needs_input : :waiting

    resolve_form_spawn_defaults!

    # Parse images and files from temp session if provided
    temp_session_id = params[:temp_session_id]
    images = nil
    attached_files = nil

    success = with_db_retry do
      if @session.save
        # A clone-only session has no prompt, so there is nothing a human said
        # yet; the first thing they type arrives through #follow_up.
        capture_web_ui_human_message(@session, @session.prompt, "web_ui.new_session") unless is_clone_only

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
      # The picker flags an unavailable server but does not refuse the pick, and
      # the form can be submitted from a page that was rendered before a
      # connector broke. Say so here rather than letting the session fail at
      # prepare time with no explanation. A warning, not a rejection — see
      # McpServerReadiness for why readiness never gates a spawn. nil when every
      # server can start, and redirect_to ignores a nil flash value.
      redirect_to @session, notice: notice_message, alert: McpServerReadiness.warn_for_session(@session)
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
    scheduling_class = quick_router_scheduling_class
    runtime = quick_router_effective_runtime
    model = quick_router_model(runtime)
    # A pick either picker itself offered can still be stale by submit time — an
    # operator removed an added model, or a runtime left the registry, between
    # render and click — so the swap to the default is said out loud rather than
    # done silently.
    runtime_ignored = quick_router_options.runtime_rejected?(params[:agent_runtime])
    model_ignored = quick_router_options.model_rejected?(runtime, params[:model])
    begin
      stage_uploads_or_raise!(incoming_images, incoming_files, temp_session_id)

      session = Session.create_from_agent_root!(
        agent_root_name: AgentRootsConfig.router_root_name,
        prompt: prompt,
        agent_runtime: runtime,
        metadata: { source: "quick_prompt" },
        genesis: SessionGenesis::WEB_UI,
        source: web_turn_source,
        scheduling_class: scheduling_class,
        precedence: quick_router_precedence(scheduling_class),
        config: model ? { "model" => model } : nil,
        skip_enqueue: true
      )

      # Recorded before the job is enqueued so the very first prompt Zimmer
      # builds for this session already carries it.
      capture_web_ui_human_message(session, prompt, "web_ui.quick_prompt")

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

    # A spot session may not start at all yet — SpotSessionHold parks it behind the
    # quota gate — so the one place this surface speaks to the user must not promise
    # routing that has not been scheduled.
    notice = if scheduling_class == SessionGenesis::SPOT
      "Router session created as spot. It starts when there is quota room, at the top of the spot queue."
    else
      "Router session created. The agent will route your request..."
    end
    if runtime_ignored
      notice += " The harness you picked is not available, so the default applied."
    end
    if model_ignored
      notice += " The model you picked is not available for this harness, so the default applied."
    end
    redirect_to session, notice: notice
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

    augmented_prompt = QuickRouterPrompt.augment(prompt: prompt, page_context: page_context, current_url: current_url)

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

    # The Advanced accordion's two pickers. This surface REJECTS a value neither
    # picker could have produced instead of falling back to the default the way
    # `quick_prompt` does, and the difference is the surface, not the policy: a
    # redirect would take the typed prompt with it, whereas this panel stays open
    # with the draft in the textarea and the message under it. So there is nothing
    # to weigh against telling the user their choice did not land.
    #
    # Both messages name reloading, because on this surface a stale list is the
    # likely cause rather than an exotic one: the panel is `data-turbo-permanent`,
    # so the options it renders on a full page load survive every Turbo navigation
    # afterwards. An operator who adds or removes a model mid-session leaves the
    # panel offering yesterday's list until the page is reloaded — see
    # docs/src/content/docs/limitations.md.
    runtime = quick_router_effective_runtime
    if quick_router_options.runtime_rejected?(params[:agent_runtime])
      render json: { error: "That harness is not available. Reload the page to refresh the list." },
             status: :unprocessable_entity
      return
    end
    if quick_router_options.model_rejected?(runtime, params[:model])
      render json: { error: "That model is not available for the #{RuntimeRegistry.label_for(runtime)} harness. Reload the page to refresh the list." },
             status: :unprocessable_entity
      return
    end

    temp_session_id = "temp_#{SecureRandom.uuid}"
    session = nil
    scheduling_class = quick_router_scheduling_class
    model = quick_router_model(runtime)
    begin
      stage_uploads_or_raise!(incoming_images, incoming_files, temp_session_id)

      session = Session.create_from_agent_root!(
        agent_root_name: AgentRootsConfig.router_root_name,
        prompt: augmented_prompt,
        parent_session_id: parent_session_id,
        # The panel's Harness picker, already resolved: the picked harness, or the
        # router root's own when the picker was left blank. Passing the resolved
        # value rather than the raw opt-in is what guarantees the row lands on the
        # runtime the model above was validated against — the catalog has a 60s TTL,
        # so re-deriving it inside ResolveSpawnDefaults could pick up a different
        # answer, and #resolve_model! leaves an already-set config["model"] alone.
        agent_runtime: runtime,
        metadata: { source: "chat_bubble", original_prompt: prompt, current_url: current_url },
        source: web_turn_source,
        # Declared, not inherited: the chat bubble carries a parent session so the
        # conversation threads, but a human typed this. Letting it inherit would
        # classify Tadas's own message spot whenever he opened the bubble from a
        # spot session's page.
        genesis: SessionGenesis::WEB_UI,
        # The submitter's own choice, which is the one thing that DOES override
        # the above — the panel's Spot checkbox says "let this one wait".
        scheduling_class: scheduling_class,
        precedence: quick_router_precedence(scheduling_class),
        # The panel's Model picker, already validated against the harness above.
        # nil leaves config unset, so ResolveSpawnDefaults resolves the model.
        config: model ? { "model" => model } : nil,
        skip_enqueue: true
      )

      # The human's own words, not `augmented_prompt` — the page-context block
      # wrapped around them is written by Zimmer, not by Tadas.
      capture_web_ui_human_message(session, prompt, "web_ui.chat_bubble")

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

  # How many items the transcript panel's own response carries: the newest few,
  # which is what a reader opening the transcript is almost always looking for.
  # Everything older arrives afterwards, a page at a time, through
  # #timeline_items — the first of those pages is prefetched the moment this
  # tail lands (infinite_scroll_controller.js#prefetchEarlier), so scrolling up
  # does not wait on it.
  TRANSCRIPT_TAIL_LIMIT = 10

  # Page size for the earlier pages #timeline_items serves.
  TIMELINE_PAGE_LIMIT = 100

  # The largest page a client may ask either endpoint for.
  MAX_TIMELINE_PAGE_LIMIT = 200

  # Valid filter levels for timeline items
  # These correspond to the client-side log level filter values
  VALID_FILTER_LEVELS = %w[minimal condensed show-logs verbose].freeze

  # GET /sessions/:id
  # The full session page. Always frameless: this URL has exactly one body.
  #
  # What this action does NOT load is as deliberate as what it does. The two
  # heaviest panels of the detail body — the transcript and the provenance tree
  # — are <turbo-frame> stubs pointing at #transcript_panel and
  # #provenance_panel, fetched right after first paint, so the first paint
  # carries the identity of the session (title, status, metadata, composer) and
  # nothing that has to be walked or parsed to produce. See load_session_detail.
  def show
    load_session_detail
  end

  # GET /sessions/:id/drawer
  # The dashboard drawer's variant of #show — the same detail body, wrapped in
  # <turbo-frame id="session_detail"> and rendered without the application layout
  # (the drawer panel supplies the surrounding chrome).
  #
  # This is a separate PATH, not a Turbo-Frame-header variant of /sessions/:id,
  # and that is the whole point. Serving two structurally different bodies from
  # one URL made every URL-keyed cache between the view and the browser a way to
  # get the wrong one, and the worst of them is not an HTTP cache at all: Turbo 8's
  # LinkPrefetchObserver keeps a prefetched request keyed ONLY by URL and splices
  # it into any later GET fetch for that URL — including this frame's own `src`
  # load — discarding the frame's Turbo-Frame header along with it. The frame then
  # gets a body with no <turbo-frame id="session_detail"> in it and Turbo renders
  # "Content missing". `Vary` cannot help, because that substitution happens in
  # browser memory and never reaches the network.
  #
  # With disjoint paths the question never arises: /sessions/:id is always
  # frameless, /sessions/:id/drawer is always framed, and no cache — Turbo's,
  # the browser's, or a CDN's — can offer one in place of the other.
  def drawer
    @in_drawer = true
    load_session_detail
    render :show, layout: false
  end

  # GET /sessions/:id/transcript_panel
  # The body of the detail page's Transcript disclosure, on its own path so the
  # panel can be a deferred frame.
  #
  # Tail first: this response is the newest TRANSCRIPT_TAIL_LIMIT items and
  # nothing else, read backwards from the end of the stored transcript a chunk at
  # a time, so its cost does not grow with the session. In particular it carries
  # no total — an exact count means normalizing every transcript entry — so the
  # client asks for it on its own (#timeline_items with `total_only`) after it
  # has prefetched the page before this one.
  #
  # `limit` widens the tail. The reconnect backfill asks for a wider one, because
  # what it reconciles against is whatever was broadcast while the page was
  # away, and that can be more than ten rows.
  #
  # One path serves both the full page and the drawer. Unlike #show/#drawer there
  # is only ever one body here — the same frame id, the same markup — so the
  # prefetch-cache hazard that forced those two apart does not arise.
  def transcript_panel
    @session = find_session
    load_timeline_tail
    render layout: false
  end

  # GET /sessions/:id/provenance_panel
  # The spawn hierarchy and human-message panels, on their own path for the same
  # reason. SessionHierarchy walks up to MAX_NODES sessions breadth-first, one
  # query per level in each direction — the bulk of the queries the detail body
  # would otherwise issue before it could paint.
  def provenance_panel
    @session = find_session
    render layout: false
  end

  # Fetch older timeline items for infinite scroll
  # GET /sessions/:id/timeline_items
  # Params:
  #   - before_timestamp: ISO8601 cursor — only items strictly older than this.
  #   - before_line: transcript line the backward read starts below (exclusive).
  #     A hint that saves re-reading the lines already on the page; without it the
  #     read starts at the end of the transcript and the timestamp alone decides.
  #   - through_index: keep reading until this transcript index is included — a
  #     `#message-N` deep link into history older than what is loaded.
  #   - total_only: answer with the filtered total and no items — the figure the
  #     tail could not afford, fetched on its own after the prefetched page so
  #     that page never waits on it.
  #   - limit: Number of items to fetch (default: 100, max: 200)
  #   - filter: Filter level (minimal, condensed, show-logs, verbose)
  #   - before_index: The index to fetch items before (exclusive) - index within
  #     FILTERED items. The pre-cursor protocol; it parses everything.
  def timeline_items
    @session = find_session

    # Get filter level from params, default to "minimal"
    filter_level = params[:filter].presence || "minimal"
    filter_level = "minimal" unless VALID_FILTER_LEVELS.include?(filter_level)

    limit = timeline_limit_param(TIMELINE_PAGE_LIMIT)

    if params[:total_only].present?
      render partial: "sessions/timeline_items_batch", locals: {
        items: [],
        session: @session,
        has_more: true,
        next_before_index: 0,
        next_before_timestamp: nil,
        next_before_line: nil,
        total_count: compute_filtered_count(@session, filter_level)
      }
    elsif params[:before_timestamp].present?
      before_ts = Time.zone.parse(params[:before_timestamp])
      if before_ts.nil?
        head :bad_request
        return
      end

      page = build_timeline_items_backward(
        @session, filter_level, limit,
        before_ts: before_ts,
        before_line: line_index_param(:before_line),
        through_index: line_index_param(:through_index)
      )

      render partial: "sessions/timeline_items_batch", locals: {
        items: page[:items],
        session: @session,
        has_more: page[:has_more],
        next_before_index: 0, # Not used with timestamp cursor
        next_before_timestamp: page[:next_before_timestamp]&.iso8601(6),
        next_before_line: page[:next_before_line],
        total_count: nil
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
        next_before_timestamp: nil,
        next_before_line: nil,
        total_count: nil
      }
    end
  end

  def archive
    @session = find_session
    # No per-user authorization: single circle of trust, no owner to check
    # against. See the authorization note at the top of this class.

    if @session.archived?
      respond_to do |format|
        format.turbo_stream { render turbo_stream: archive_remove_streams(@session, notice: "Session is already in trash.") }
        format.html { redirect_to @session, notice: "Session is already in trash." }
      end
      return
    end

    # Archiving discards whatever is still queued for the session, so the first
    # click over a non-empty queue does not archive — it says what would be lost
    # and offers an explicit "Archive anyway", which re-posts here with `force`.
    # Every Trash affordance (the session header, the session card, the mobile
    # joystick) posts to this one action, so the two-step lands on all of them.
    #
    # This is the human twin of the MCP and REST refusals; see
    # Sessions::ArchiveGuard for why the discard is worth a speed bump.
    # The check and the transition share one row lock; see
    # Sessions::ArchiveGuard.guarded_archive!.
    #
    # The block returns a sentinel rather than the transition's own value: AASM's
    # bang event answers `false` when the underlying save fails, which `with_db_retry`
    # also uses to mean "gave up retrying". Without the sentinel those two are one
    # value, and the failed-save case would fall through to an implicit render.
    refused = nil
    result = with_db_retry do
      Sessions::ArchiveGuard.guarded_archive!(
        @session,
        force: ActiveModel::Type::Boolean.new.cast(params[:force]),
        actor: "a user in the web UI"
      )
      :archived
    rescue Sessions::ArchiveGuard::Refused => e
      refused = e.messages
      :refused
    end

    # Only respond if the operation succeeded (not false from max retry handler)
    return if result == false

    if refused
      respond_with_flash(
        alert: "#{Sessions::ArchiveGuard.summary(refused)}|force_archive|#{@session.id}",
        location: @session
      )
      return
    end

    undo_notice = "Session moved to trash.|undo_archive|#{@session.id}"

    # Trashing a session from its own detail page leaves the user on a page that
    # no longer represents anything they can act on, so that one affordance
    # navigates home. Every other Trash — a dashboard card, a ranked row, the
    # drawer — is a control inside a list the user is still reading, and stays
    # put with the card removed in place.
    #
    # The referer is what separates them, because the markup cannot: the header
    # partial is shared with the drawer and re-rendered by broadcasts that have
    # no request to read a context out of, so a server-rendered "I am the full
    # page" flag would be overwritten by the next status change. The drawer keeps
    # the dashboard's URL — it loads /sessions/:id/drawer into a frame without
    # advancing history — so only the full page's referer matches. Comparing
    # against *this* session's path rather than any /sessions/:id is deliberate:
    # trashing one session's card from another session's page stays put.
    #
    # The redirect is also what carries the Undo toast across the navigation. The
    # notice rides the flash instead of a stream, so the dashboard renders the
    # toast — Undo button and all — on arrival. 303 is the status that means
    # "GET this next" for any method, which is what Turbo documents for a form
    # submission's redirect.
    if archived_from_its_own_page?(@session)
      redirect_to root_path, notice: undo_notice, status: :see_other
      return
    end

    respond_to do |format|
      format.turbo_stream { render turbo_stream: archive_remove_streams(@session, notice: undo_notice) }
      format.html { redirect_to root_path, notice: undo_notice }
    end
  end

  # True when this POST came from the session's own full detail page. A dashboard
  # card, a ranked row and the drawer all sit on the dashboard's URL, so they
  # answer false and keep the in-place stream.
  #
  # The page has two URLs. `session_path` spells it with the slug, but #show
  # resolves the numeric id too and does not redirect to the canonical form — and
  # the id form is what Slack and push notifications link to, so it is the one a
  # human most often arrives on. Both spellings count.
  #
  # Same-host only, like #referrer_is_sessions_index?: a cross-origin referer with
  # a matching path is not this app's page.
  #
  # Only the success path consults this. A refusal and an already-archived click
  # both answer with a stream into #flash, which leaves the user on the page they
  # clicked from — an error must not navigate away as though it had worked.
  def archived_from_its_own_page?(session)
    return false if request.referer.blank?

    referer = URI.parse(request.referer)
    return false unless referer.host.nil? || referer.host == request.host

    [ session_path(session), session_path(session.id) ].include?(referer.path)
  rescue URI::InvalidURIError
    false
  end
  private :archived_from_its_own_page?

  # In-place removal for the homepage Trash button. Removes the
  # `dom_id(session)` turbo_frame wrapping the session's card, and streams the
  # notice into the layout's #flash target — without that second stream the
  # card vanished silently and the Undo button in the toast never appeared.
  #
  # It carries the session page's chrome for the same reason #unarchive and
  # #pause do: archiving from the drawer showing a session leaves the user
  # looking at it, so the Trash button has to become Restore in the reply itself
  # rather than only over a cable that can be silently dead. The full detail page
  # never receives this stream — #archive redirects it home. Both chrome targets
  # are absent when the click came from a dashboard card.
  #
  # The two elements a dashboard can be showing this session as: the card (keyed
  # on dom_id, in the flat sort views) and the User view's row. Both are removed
  # rather than one, because the removal is sent to whichever page made the
  # request and the server does not know which of the two it is looking at; a
  # `remove` for an id that is not in the DOM is a silent no-op.
  #
  # Server-driven rather than optimistic on the client, and that is the point:
  # #archive refuses the first click when the session still has queued messages,
  # and answers with the "Archive anyway" speed bump instead of these streams. A
  # row the browser had already taken away on click would leave the operator
  # believing a session was trashed that was not.
  def archive_remove_streams(session, notice:)
    [
      turbo_stream.remove(dom_id(session)),
      turbo_stream.remove(helpers.user_view_row_dom_id(session)),
      flash_stream(notice: notice)
    ] + session_chrome_streams(session)
  end
  private :archive_remove_streams

  # `flash_stream` and `respond_with_flash` — used by the actions below and by
  # UncleLinksController — live in TurboFlash, included above.

  def unarchive
    @session = find_session
    # No per-user authorization: single circle of trust, no owner to check
    # against. See the authorization note at the top of this class.

    unless @session.archived?
      respond_with_flash(alert: "Session is not in trash.", location: @session)
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
      # No card stream: the session's card is still in the dashboard's DOM (the
      # trash view lists archived and live sessions together), and unarchiving
      # fires broadcast_update_to_sessions_index, which replaces it in place.
      # The session page's own chrome rides along in this response rather than
      # waiting on the broadcast — see #session_chrome_streams.
      respond_with_flash(notice: notice, location: @session, streams: session_chrome_streams(@session))
    else
      respond_with_flash(alert: "Failed to restore session: #{result.error}", location: @session)
    end
  end

  def undo_archive
    @session = find_session
    # No per-user authorization: single circle of trust, no owner to check
    # against. See the authorization note at the top of this class.

    unless @session.archived?
      respond_with_flash(alert: "Session is not in trash.", location: root_path)
      return
    end

    # The window the toast's Undo button is offered for. The same constant sets
    # how long that toast stays on screen (ApplicationHelper#flash_duration_ms),
    # so a button that is still visible is still live.
    if @session.archived_at.nil? || Time.current - @session.archived_at > SessionStateMachine::UNDO_ARCHIVE_WINDOW
      respond_with_flash(alert: "The undo window has expired. Use the restore feature instead.", location: root_path)
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

    # Only respond if the operation succeeded
    return if result == false

    # #archive removed this card from the dashboard, so the restore's
    # broadcast_update_to_sessions_index has nothing left to replace. Put the
    # card back into its own section's grid — that is what "Undo" means to the
    # user standing on the dashboard, and it is why undo stays there instead of
    # navigating to the session (the HTML fallback still redirects).
    respond_with_flash(
      notice: "Session restored from trash.",
      location: @session,
      streams: [ restored_card_stream(@session), restored_row_stream(@session) ]
    )
  end

  # Re-inserts a session's card at the top of the grid it belongs to. Turbo
  # de-duplicates by element id on prepend, so this is safe if the card somehow
  # never left; on the session's own page neither target exists and the stream
  # is a silent no-op.
  def restored_card_stream(session)
    turbo_stream.prepend(
      restored_card_target(session),
      partial: "sessions/session_card_frame",
      locals: { agent_session: session }
    )
  end
  private :restored_card_stream

  # The same restore, for the User view's row list. Prepended rather than slotted
  # into place: the row carries its precedence and its class, and the view's own
  # controller re-sorts the list whenever a row arrives, so it lands where the
  # order says it belongs rather than where this stream put it.
  #
  # A no-op on any page that is not the User view — "user_view_list" is not in
  # the DOM there.
  def restored_row_stream(session)
    turbo_stream.prepend(
      "user_view_list",
      partial: "sessions/user_view_row",
      locals: { agent_session: session }
    )
  end
  private :restored_row_stream

  # The two bits of session-page chrome that encode a session's status: the badge
  # and the header's action buttons (Restore vs Pause/Trash). Session#broadcast_
  # status_change pushes both over the cable on every status change, so an action
  # that changes status could rely on that alone — but a broadcast is
  # fire-and-forget, and this whole PR exists because a cable can be silently
  # dead. The direct HTTP reply to the user's own click cannot be lost, so a
  # status-changing action carries its own chrome. Both targets are absent when
  # the click came from a dashboard card, where the streams are a no-op.
  def session_chrome_streams(session)
    [
      turbo_stream.replace(
        "session_#{session.id}_status_badge",
        partial: "sessions/status_badge",
        locals: { agent_session: session }
      ),
      turbo_stream.replace(
        "session_#{session.id}_header_actions",
        partial: "sessions/session_header_actions",
        locals: { agent_session: session }
      )
    ]
  end
  private :session_chrome_streams

  # Where an Undo puts the card back. There is one grid now: the per-category
  # grids went with the categories view, and every surface that still renders
  # cards (the two flat sort views) renders them all into "sessions_grid".
  #
  # The User view renders rows rather than cards and has no "sessions_grid" at
  # all, so this prepend is a no-op there; #restored_row_stream is what puts the
  # row back on that page.
  def restored_card_target(_session)
    "sessions_grid"
  end
  private :restored_card_target

  def bulk_archive
    # No per-user authorization: there is no "their own sessions" to scope to.
    # See the authorization note at the top of this class.

    session_ids = params[:session_ids] || []

    if session_ids.empty?
      respond_with_flash(alert: "No sessions selected.", location: root_path)
      return
    end

    sessions = Session.where(id: session_ids)
    archived_count = 0
    skipped_with_queue = 0

    # Wrap in transaction for atomicity with retry logic
    result = with_db_retry do
      # Reset per attempt: with_db_retry re-runs this whole block, and the
      # transaction rolls the archives back with it, so counters carried over
      # from a failed attempt would report work that did not happen.
      archived_count = 0
      skipped_with_queue = 0

      ActiveRecord::Base.transaction do
        sessions.each do |session|
          next if session.archived?

          # Never forced: a bulk selection is not a claim to have read each
          # session's queue, and there is no per-session confirmation to hang a
          # force on. The count is reported so the skip is not silent, and
          # archiving one of them individually offers the "Archive anyway".
          if Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a user in the web UI (bulk action)")
            archived_count += 1
          end
        rescue Sessions::ArchiveGuard::Refused
          skipped_with_queue += 1
        end
      end
    end

    # Only respond if the operation succeeded
    return if result == false

    # Each archived session broadcasts its own card removal
    # (broadcast_remove_from_sessions_index), so the stream only owes the count.
    notice = "#{archived_count} session(s) moved to trash."
    if skipped_with_queue.positive?
      notice += " #{skipped_with_queue} skipped — they have queued messages that archiving would discard; " \
                "archive those individually to confirm."
    end
    respond_with_flash(notice: notice, location: root_path)
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
        redirect_to refresh_redirect_target(@session), notice: "Attempting to resume failed session..."
        return
      end
    end

    # A waiting session that is stalled — rather than deliberately asleep — gets the
    # automated continue nudge (AutomatedPrompts::SYSTEM_RECOVERY, sent through the
    # same #restart_with_continue_prompt every recovery path uses) instead of a plain
    # transcript re-sync. There is no live process behind a waiting session, so
    # re-reading its transcript is a no-op for the user; nudging it is the action they
    # actually want from "refresh". Session#continue_nudge_on_refresh? excludes the two
    # waiting sessions that must NOT be nudged: one that never started (no session_id,
    # still owned by the spawn pipeline) and one sleeping on an unfired wake-up trigger.
    if @session.continue_nudge_on_refresh?
      success, error_message = restart_with_continue_prompt(@session)
      return if performed?

      if success
        redirect_to refresh_redirect_target(@session), notice: "Continuing waiting session..."
      else
        redirect_to refresh_redirect_target(@session), alert: "Could not continue waiting session: #{error_message}"
      end
      return
    end

    # Re-read the transcript from disk. The operation is Sessions::RefreshTranscript,
    # shared with the REST API and MCP; this only renders its outcome.
    begin
      result = Sessions::RefreshTranscript.call(@session, actor: :web)
      target = refresh_redirect_target(@session)

      case result.outcome
      when :refreshed
        redirect_to target, notice: "Transcript refreshed successfully"
      when :no_transcript_directory
        redirect_to target, alert: "No clone path found for this session"
      when :no_transcript_file
        redirect_to target, alert: "No transcript files found on filesystem"
      when :regression
        redirect_to target, alert: "Filesystem transcript is shorter than the stored one (clone likely recreated) — kept the longer stored transcript."
      else
        redirect_to target, alert: result.error
      end
    rescue => e
      Rails.logger.error "Error refreshing transcript: #{e.message}"
      redirect_to refresh_redirect_target(@session), alert: "Error refreshing transcript: #{e.message}"
    end
  end

  def refresh_all
    # Only process non-archived sessions. A status-summary fork sitting in
    # needs_input between its pause and the harvest is not work anyone is waiting on
    # — resuming it would spend a whole agent turn against a throwaway clone,
    # outside the fork lifecycle.
    sessions = Session.excluding_status_summary_forks.where.not(status: :archived)
    bulk_refresh_sessions(sessions, empty_notice: "No non-archived sessions to refresh")
  end

  # Shared implementation behind #refresh_all.
  # Given a relation of candidate sessions (already scoped to exclude archived
  # sessions), it (1) restarts failed sessions, (2) continues
  # auto-continuable needs_input sessions (those NOT paused by the user), (3) continues
  # stalled waiting sessions with the same nudge single-session #refresh sends, and
  # (4) refreshes transcripts for everything left, then redirects to the dashboard with a
  # summary. +empty_notice+ is the flash shown when the relation has no sessions to act on.
  def bulk_refresh_sessions(sessions, empty_notice:)
    if sessions.empty?
      respond_with_flash(notice: empty_notice, location: root_path)
      return
    end

    refreshed_count = 0
    restarted_count = 0
    continued_count = 0
    continued_waiting_count = 0
    error_count = 0

    # Separate restartable sessions (failed and auto-continuable needs_input) from others
    # Only continue needs_input sessions that were paused by recovery (deployment interruption),
    # not those paused by the user intentionally. User-paused sessions have paused_by: "user".
    # Sessions without paused_by are treated as continuable for backwards compatibility.
    auto_continuable_needs_input = sessions
      .where(status: :needs_input)
      .where("metadata->>'paused_by' IS NULL OR metadata->>'paused_by' != 'user'")

    # Waiting sessions that are stalled rather than deliberately asleep get the same
    # continue nudge as a single-session #refresh — see the rationale there. A session
    # with no session_id has never started (the spawn pipeline still owns it), and
    # Session.ids_awaiting_scheduled_wake names the ones sleeping on a wake-up that has
    # not come due. Both fall through to the plain transcript refresh below, exactly as
    # the single-session predicate decides. The batch form costs two queries for the
    # whole set rather than one per waiting session.
    waiting_candidates = sessions.where(status: :waiting).where.not(session_id: [ nil, "" ]).to_a
    sleeping_ids = Session.ids_awaiting_scheduled_wake(waiting_candidates.map(&:id))
    # A session the spot ceiling paused is deliberately dormant, not stalled:
    # nudging it back awake would put it straight back on the quota window that
    # stopped it, with the sweep pausing it again minutes later. It comes back
    # when utilization does — or immediately, if you make it priority.
    nudgeable_waiting = waiting_candidates.reject do |session|
      sleeping_ids.include?(session.id) || SpotSessionPause.paused?(session)
    end

    # Track totals to warn if limit is exceeded
    total_failed_count = sessions.where(status: :failed).count
    total_needs_input_count = auto_continuable_needs_input.count
    total_restartable_count = total_failed_count + total_needs_input_count + nudgeable_waiting.size

    # Apply bulk limit across failed, needs_input and waiting sessions
    # Prioritize failed sessions, then needs_input, then waiting
    # Use .load to force loading, then .size to avoid extra COUNT query
    failed_sessions = sessions.where(status: :failed).limit(BULK_RESTART_LIMIT).load
    remaining_limit = [ BULK_RESTART_LIMIT - failed_sessions.size, 0 ].max
    needs_input_sessions = auto_continuable_needs_input.limit(remaining_limit).load
    waiting_limit = [ remaining_limit - needs_input_sessions.size, 0 ].max
    waiting_sessions = nudgeable_waiting.first(waiting_limit)

    # Ids of everything the three restart/continue loops below will touch. They are
    # captured BEFORE those loops run because each one flips its session to :running —
    # and non_restartable_sessions is a lazy relation iterated afterwards, so without
    # this exclusion a just-restarted session would no longer match
    # `where.not(status: [:failed, :needs_input])`, fall into the transcript pass, and
    # be counted twice while overwriting a transcript its new job is about to rewrite.
    restarted_ids = (failed_sessions + needs_input_sessions + waiting_sessions).map(&:id)

    # Everything not restarted/continued above still gets a transcript refresh — the
    # running sessions, plus any waiting session the nudge deliberately skipped or the
    # bulk limit pushed past.
    non_restartable_sessions = sessions
      .where.not(status: [ :failed, :needs_input ])
      .where.not(id: restarted_ids)

    # Restart failed sessions
    failed_sessions.each do |session|
      success, error_message = restart_with_continue_prompt(session)
      # The refusal's log row still goes through ControllerDatabaseRetry, which
      # redirects when it exhausts its retries; keep going and we would
      # double-render at the summary redirect below.
      return if performed?

      if success
        restarted_count += 1
      else
        error_count += 1
        Rails.logger.warn "[bulk_refresh] Failed to restart session #{session.id}: #{error_message}"
      end
    end

    # Continue needs_input sessions (e.g., after deployment killed their processes)
    needs_input_sessions.each do |session|
      success, error_message = restart_with_continue_prompt(session)
      return if performed?

      if success
        continued_count += 1
      else
        error_count += 1
        Rails.logger.warn "[bulk_refresh] Failed to continue session #{session.id}: #{error_message}"
      end
    end

    # Continue stalled waiting sessions with the automated nudge
    waiting_sessions.each do |session|
      success, error_message = restart_with_continue_prompt(session)
      return if performed?

      if success
        continued_waiting_count += 1
      else
        error_count += 1
        Rails.logger.warn "[bulk_refresh] Failed to continue waiting session #{session.id}: #{error_message}"
      end
    end

    # Refresh non-restartable sessions (running and waiting)
    non_restartable_sessions.each do |session|
      # Check if session is running but has no active job - restore if needed
      if session.running? && should_restore_job?(session)
        restore_agent_session_job(session)
      end

      # Re-read the transcript from disk (Sessions::RefreshTranscript). Nothing to
      # read, or a shorter filesystem copy, is skipped rather than counted.
      begin
        result = Sessions::RefreshTranscript.call(session, actor: :web, bulk: true)

        if result.database_unavailable?
          # A database that stays unavailable ends the sweep, as it always has.
          respond_with_flash(alert: result.error, location: root_path)
          return
        end

        refreshed_count += 1 if result.refreshed?
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
    messages << "Continued #{continued_waiting_count} waiting session(s)" if continued_waiting_count.positive?

    if messages.any?
      notice = messages.join(", ")
      notice += " (#{error_count} errors)" if error_count.positive?
      notice += ". #{total_restartable_count - BULK_RESTART_LIMIT} more sessions to restart/continue" if total_restartable_count > BULK_RESTART_LIMIT
      respond_with_flash(notice: notice, location: root_path)
    elsif error_count.positive?
      respond_with_flash(alert: "Failed to process #{error_count} session(s)", location: root_path)
    else
      respond_with_flash(notice: "No sessions to refresh or restart", location: root_path)
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
    # If not provided in params, default to session's existing goal. The web form
    # always submits the field, so a blank value here really is "the human emptied
    # the box" — which is why this is the one surface that passes
    # `clear_when_blank: true` to Sessions::FollowUpGoal below.
    goal = if params.key?(:goal)
      Sessions::FollowUpGoal.normalize(params[:goal])
    else
      @session.goal
    end

    # Validate goal length if present
    if Sessions::FollowUpGoal.too_long?(goal)
      respond_to_follow_up_error("Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters).")
      return
    end

    # Only a goal this follow-up changes is judged, like the model validation: a
    # session already carrying a retired id keeps taking follow-ups.
    if goal != @session.goal && GoalsConfig.unknown_id?(goal)
      respond_to_follow_up_error(GoalsConfig.unknown_id_message(goal))
      return
    end

    # IMPORTANT: If a turn is already underway, redirect to queue the message instead of
    # sending immediately. This prevents race conditions where the form action was set
    # incorrectly (e.g., before JS loaded) or where the user double-submitted. Messages
    # should be queued when the agent is running — or when its turn is sitting in the
    # `agents` queue, which since #1040 reads `waiting` rather than `running`.
    if Sessions::LiveTurn.underway?(@session)
      # Create enqueued message instead of interrupting
      max_position = @session.enqueued_messages.maximum(:position) || 0
      next_position = max_position + 1

      result = with_db_retry do
        @session.enqueued_messages.create!(
          content: follow_up_prompt,
          goal: goal,
          position: next_position,
          status: "pending",
          source_context: web_turn_source.to_h
        )

        # Recorded at the moment the human typed it, not at delivery: the
        # record is of what was said and when, and a queued message
        # may sit for a whole turn before it reaches the agent.
        capture_web_ui_human_message(@session, follow_up_prompt, "web_ui.follow_up_queued")

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
        redirect_to session_redirect_target(@session),
          notice: "Message queued. It will be sent when the agent completes its current task."
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
        # Update session's goal if it changed. `clear_when_blank: true` because
        # this surface can tell an emptied goal field from an absent one — see
        # Sessions::FollowUpGoal for the rule the other three surfaces share.
        Sessions::FollowUpGoal.apply!(
          session: @session,
          goal: goal,
          source: :web_follow_up,
          clear_when_blank: true
        )

        # Parse image paths from params if provided (stored by upload_images action)
        images = parse_image_params
        # Parse file paths from params if provided (stored by upload_files action)
        attached_files = parse_file_params

        # Broadcast optimistic user message immediately for instant feedback
        # This shows the message in the timeline before Claude processes it
        sent_at = Time.current
        BroadcastService.new.optimistic_user_message(@session, follow_up_prompt, sent_at: sent_at)

        # Before deliver_follow_up! enqueues the job, so the prompt that job
        # builds already includes this turn.
        capture_web_ui_human_message(@session, follow_up_prompt, "web_ui.follow_up", occurred_at: sent_at)

        # Clear stale retry state, resume, stamp the prompt, enqueue, record the job id.
        #
        # sent_at drives the pause-wait-for-delivery logic. sent_message is stored for
        # recovery: if the session transitions to paused/failed before the message
        # appears in the transcript, we preload it back into the follow-up entry box so
        # the user doesn't lose their message. TranscriptPollerService clears it once the
        # message lands in the transcript.
        @session.deliver_follow_up!(
          follow_up_prompt,
          clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
          metadata_updates: {
            "pending_follow_up_sent_at" => sent_at.iso8601,
            "sent_message" => follow_up_prompt,
            "sent_message_at" => sent_at.iso8601,
            # Stamps user activity so PollBackoff resets the GitHub-poll cadence
            # for this session (this key is NOT cleared by transcript polling).
            "last_user_activity_at" => sent_at.iso8601
          },
          images: images,
          files: attached_files,
          source: web_turn_source
        )

        # Logged after the delivery so the timeline reads
        # "resumed" → "prompt received" → attachments, as it always has.
        truncated_prompt = follow_up_prompt.length > 200 ? "#{follow_up_prompt[0..197]}..." : follow_up_prompt
        @session.logs.create!(
          content: "Follow-up prompt received: #{truncated_prompt}",
          level: "info"
        )

        if images.present?
          @session.logs.create!(
            content: "Sending #{images.size} image(s) with follow-up prompt",
            level: "info"
          )
        end

        if attached_files.present?
          @session.logs.create!(
            content: "Sending #{attached_files.size} file(s) with follow-up prompt",
            level: "info"
          )
        end
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
      respond_with_flash(alert: "Cannot pause session that is not running (status: #{@session.status})", location: @session)
      return
    end

    # Get process PID from session metadata
    process_pid = @session.metadata&.dig("process_pid")

    unless process_pid
      respond_with_flash(alert: "Cannot pause session: no process found", location: @session)
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
        @session.merge_metadata!("paused_by" => "user")
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
      stderr_log_path = @session.stderr_log_path
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

      # The pause flips the session to needs_input; broadcast_status_change also
      # re-renders the follow-up form and running loader over the cable, but the
      # badge and header actions ride back in this response so they land even if
      # the socket is down (see #session_chrome_streams).
      respond_with_flash(
        notice: "Session paused successfully. You can now send a follow-up prompt to redirect the agent.",
        location: @session,
        streams: session_chrome_streams(@session)
      )
    rescue => e
      Rails.logger.error "Error pausing session: #{e.message}"
      with_db_retry do
        @session.logs.create!(
          content: "Failed to pause session: #{e.message}",
          level: "error"
        )
      end
      respond_with_flash(alert: "Failed to pause session: #{e.message}", location: @session)
    end
  end

  def restart
    @session = find_session

    # Restarting is a deliberate user interaction: reset PollBackoff so the
    # session's GitHub-poll cadence returns to the fast end.
    reset_poll_backoff(@session)

    # Read before the restart resumes the session to `waiting`: the answer a person
    # gets should name the state they clicked from, not the one they left behind.
    restarted_a_failed_session = @session.failed?

    # `failed` and `needs_input` — the two states a session is stranded in, and
    # the ones the button is rendered under. The predicate is the model's, and is
    # derived from the `may_resume?` that MCP and the REST API gate on, so this
    # door cannot drift wider than those two (zimmer#830).
    unless @session.restartable_by_hand?
      respond_to do |format|
        format.html { redirect_to @session, alert: "Cannot restart a session that is #{@session.status} — Restart applies to failed sessions and ones paused awaiting input" }
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
              content: "Restarting #{restarted_a_failed_session ? 'failed' : 'paused'} session: " \
                       "reconnecting to running process #{process_pid}",
              level: "info"
            )

            @session.remove_metadata!(Session::STALE_RETRY_METADATA_KEYS)
            @session.update!(running_job_id: nil)
            if @session.may_resume?
              @session.resume!
            elsif @session.may_start?
              @session.start!
            end

            # Enqueue job to resume monitoring without spawning a new process.
            # Pin it to the pid we just proved alive: if something spawns a new turn
            # before the job runs, it stands down instead of adopting that turn.
            AgentSessionJob.enqueue_for_monitoring(@session.id, monitor_pid: process_pid)

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
        format.html { redirect_to session_path(@session), notice: restart_initiated_notice(restarted_a_failed_session) }
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
    # Transcripts do carry sensitive conversation data, and they are readable by
    # anyone who can reach the host. Guarding that is the perimeter's job, not a
    # per-user check here — see the authorization note at the top of this class.

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

  # POST /sessions/:id/regenerate_status_summary
  #
  # The Status panel's only write path. Forced, because the operator clicking
  # "regenerate" on a summary Zimmer considers current is a deliberate override
  # — the staleness check exists to stop AUTOMATIC regeneration, not to argue
  # with the person looking at the page.
  def regenerate_status_summary
    @session = find_session

    # Asked before the job is enqueued, so a request that cannot produce a
    # summary is answered with the reason. Enqueuing regardless is what left the
    # panel on "Generating" forever: the job refused, and its refusal had nowhere
    # to go. `force: true` because that is what this action enqueues — neither
    # being archived nor having lost its clone stops a forced generation, which
    # scaffolds the fork a working directory when there is no tree left.
    unavailable = SessionStatusSummaryGenerator.unavailable_reason(session: @session, force: true)

    if unavailable
      respond_to do |format|
        format.turbo_stream { render turbo_stream: status_panel_replacement }
        format.html { redirect_to @session, alert: unavailable.message }
        format.json { render json: { success: false, error: unavailable.message }, status: :unprocessable_entity }
      end
      return
    end

    SessionStatusSummaryJob.set(priority: SessionStatusSummaryJob::FORCED_PRIORITY).perform_later(@session.id, force: true)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: status_panel_replacement(generating: true) }
      format.html { redirect_to @session, notice: "Regenerating the status summary…" }
      format.json { render json: { success: true } }
    end
  end

  # The Status panel, re-rendered in place. Both exits from the action use it:
  # the refused one so the panel comes back with the button dead and the reason
  # under it, the accepted one so it flips to "Generating" before the job has
  # marked the record.
  def status_panel_replacement(generating: false)
    turbo_stream.replace(
      "session_#{@session.id}_status_panel",
      partial: "sessions/status_panel",
      locals: { agent_session: @session, generating: generating }
    )
  end
  private :status_panel_replacement

  # Presentation ONLY — the write and its rules (strip, blank refused, the cap,
  # dropping the auto-title flag) are Sessions::UpdateTitle, shared with a
  # `title` in PATCH /api/v1/sessions/:id and the `update_title` MCP action.
  def update_title
    @session = find_session

    with_db_retry { Sessions::UpdateTitle.call(session: @session, title: params[:title]) }
    return if performed? # with_db_retry rendered its own give-up response

    render json: { success: true, title: @session.title }
  rescue Sessions::UpdateTitle::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # Presentation ONLY — the write and its rules (blank clears, the cap) are
  # Sessions::UpdateNotes, shared with PATCH /api/v1/sessions/:id/notes and the
  # `update_notes` MCP action.
  def update_notes
    @session = find_session

    with_db_retry { Sessions::UpdateNotes.call(session: @session, notes: params[:session_notes]) }
    return if performed? # with_db_retry rendered its own give-up response

    render json: {
      success: true,
      session_notes_updated_at: @session.session_notes_updated_at&.iso8601
    }
  rescue Sessions::UpdateNotes::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # Presentation ONLY — the flip is Sessions::TogglePushNotifications, shared
  # with the `toggle_push_notifications` MCP action.
  def toggle_push_notifications
    @session = find_session

    result = with_db_retry do
      Sessions::TogglePushNotifications.call(session: @session)
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
  #
  # Presentation ONLY — the write is Sessions::UpdateHeartbeat, shared with the
  # REST endpoint and the `set_heartbeat` MCP action. An unnamed `enabled` is
  # what means "flip"; one the caller sent but the server cannot read is refused
  # rather than flipped.
  def toggle_heartbeat
    @session = find_session

    # The flip resolves HERE, before the retry, and the resolved boolean is what
    # the block closes over. `with_db_retry` re-runs its block, and `update!`
    # assigns before it saves — so a flip computed inside would read the
    # already-flipped in-memory value on the second attempt and write the
    # opposite of what was asked. Same hazard as the counters in #bulk_archive.
    enabled = params[:enabled].nil? ? !@session.heartbeat_enabled : params[:enabled]

    with_db_retry { Sessions::UpdateHeartbeat.call(session: @session, enabled: enabled) }
    return if performed? # with_db_retry rendered its own give-up response

    respond_to do |format|
      format.json { render json: heartbeat_json }
      format.html { redirect_to @session }
    end
  rescue Sessions::UpdateHeartbeat::Error, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to @session, alert: e.message }
    end
  end

  # Set how often the heartbeat beats. Presentation ONLY — the range check
  # against Session::HEARTBEAT_MIN/MAX_INTERVAL_SECONDS lives in
  # Sessions::UpdateHeartbeat. Responds JSON.
  def update_heartbeat_interval
    @session = find_session

    with_db_retry do
      Sessions::UpdateHeartbeat.call(session: @session, interval_seconds: params[:heartbeat_interval_seconds])
    end
    return if performed?

    render json: heartbeat_json
  rescue Sessions::UpdateHeartbeat::MissingSetting
    # This route takes one setting, so the service's two-setting phrasing would
    # name a parameter the route does not accept.
    render json: { error: "heartbeat_interval_seconds is required." }, status: :unprocessable_entity
  rescue Sessions::UpdateHeartbeat::Error, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Board visibility: hide a session, snooze it until a chosen time, or put it
  # back. Presentation ONLY — see Sessions::SetVisibility. Snoozing a card is not
  # sleeping a session: no sleep, no wake trigger, no spot queue, no status
  # change. Sleeping a session is `wake_me_up_later` / `pause_into_spot_queue`
  # over MCP, and the web UI has no control that does it.
  #
  # Answers JSON (the visibility Stimulus controller drives it with fetch) and
  # HTML (the no-JS fallback).
  def update_visibility
    @session = find_session

    Sessions::SetVisibility.call(
      session: @session,
      visibility: params[:visibility],
      snoozed_until: params[:snoozed_until],
      timezone: params[:timezone].presence || "UTC"
    )

    respond_to do |format|
      format.json { render json: visibility_payload(@session) }
      format.html do
        redirect_back fallback_location: session_path(@session),
                      notice: visibility_notice(@session)
      end
    end
  rescue Sessions::SetVisibility::Error, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: session_path(@session), alert: e.message }
    end
  end

  # CarPlay fit: whether what the session needs next from a human can be done
  # by voice from a car. A person's mark, written from the web UI, so it is
  # recorded as `human` — the source that outranks every other writer at the
  # same transcript position. Presentation and triage only, like visibility:
  # see Sessions::SetCarplayFit.
  def update_carplay_fit
    @session = find_session

    result = Sessions::SetCarplayFit.call(
      session: @session,
      fit: params[:carplay_fit],
      reason: params[:carplay_fit_reason],
      source: SessionCarplayFit::SOURCE_HUMAN
    )

    respond_to do |format|
      format.json { render json: carplay_fit_payload(@session.reload, result) }
      format.html do
        redirect_back fallback_location: session_path(@session), notice: carplay_fit_notice(@session.reload)
      end
    end
  rescue Sessions::SetCarplayFit::Error, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: session_path(@session), alert: e.message }
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

  # PATCH /sessions/:id/update_mcp_servers
  #
  # The four catalog-selection editors on the session page. Each one checks the
  # parameter's shape, hands the operation to Sessions::UpdateCatalogSelection —
  # which the REST and MCP surfaces call too — and renders the answer. The
  # selection is persisted and takes effect on the session's next prepare; see
  # the service for why nothing here regenerates the runtime config.
  def update_mcp_servers
    @session = find_session
    return unless (result = apply_catalog_selection(:mcp_servers, params[:mcp_servers]))

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
          mcp_servers: result.values,
          oauth_required: result.oauth_required?,
          oauth_required_servers: result.servers_needing_oauth
        }
      end
    end
  end

  # PATCH /sessions/:id/update_catalog_skills
  def update_catalog_skills
    @session = find_session
    return unless (result = apply_catalog_selection(:catalog_skills, params[:catalog_skills]))

    render json: { success: true, catalog_skills: result.values }
  end

  # PATCH /sessions/:id/update_catalog_hooks
  def update_catalog_hooks
    @session = find_session
    return unless (result = apply_catalog_selection(:catalog_hooks, params[:catalog_hooks]))

    render json: { success: true, catalog_hooks: result.values }
  end

  # PATCH /sessions/:id/update_catalog_plugins
  def update_catalog_plugins
    @session = find_session
    return unless (result = apply_catalog_selection(:catalog_plugins, params[:catalog_plugins]))

    render json: {
      success: true,
      catalog_plugins: result.values,
      oauth_required: result.oauth_required?,
      oauth_required_servers: result.servers_needing_oauth
    }
  end

  # PATCH /sessions/:id/update_model
  # Presentation ONLY — the write and its rules (the model must be one the
  # session's runtime offers, and one that can keep its effort) are
  # Sessions::UpdateModel, shared with PATCH /api/v1/sessions/:id/model and the
  # `change_model` MCP action.
  def update_model
    @session = find_session

    with_db_retry { Sessions::UpdateModel.call(session: @session, model: params[:model], actor: :web) }
    return if performed? # with_db_retry rendered its own give-up response

    render json: { success: true, model: @session.config&.dig("model") }
  rescue Sessions::UpdateModel::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # PATCH /sessions/:id/update_effort
  # Presentation ONLY — the write and its rules (which levels the model takes,
  # "default" clears) are Sessions::UpdateEffort, shared with
  # PATCH /api/v1/sessions/:id/effort and the `change_effort` MCP action.
  def update_effort
    @session = find_session

    with_db_retry { Sessions::UpdateEffort.call(session: @session, effort: params[:effort], actor: :web) }
    return if performed? # with_db_retry rendered its own give-up response

    render json: { success: true, effort: @session.effort_summary, description: @session.effort_description }
  rescue Sessions::UpdateEffort::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # PATCH /sessions/:id/update_auto_compact_window
  # Presentation ONLY — the write and its rules (an integer within
  # 1..Session::MAX_AUTO_COMPACT_WINDOW, applied from the next turn or restart)
  # are Sessions::UpdateAutoCompactWindow, shared with the
  # `change_auto_compact_window` MCP action.
  def update_auto_compact_window
    @session = find_session

    with_db_retry do
      Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: params[:auto_compact_window], actor: :web)
    end
    return if performed? # with_db_retry rendered its own give-up response

    render json: { success: true, auto_compact_window: @session.auto_compact_window }
  rescue Sessions::UpdateAutoCompactWindow::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # PATCH /sessions/:id/memory_boost
  # Presentation ONLY — the rules (bounds, one boost at a time, the expiry) are
  # Sessions::UpdateMemoryBoost, shared with the `set_memory_boost` MCP action.
  def update_memory_boost
    @session = find_session

    with_db_retry do
      Sessions::UpdateMemoryBoost.grant(session: @session, memory_mb: params[:memory_mb], hours: params[:hours], actor: :web)
    end
    return if performed?

    redirect_back fallback_location: session_path(@session),
                  notice: "Memory boost granted: #{@session.memory_boost_mb} MB until #{@session.memory_boost_expires_at.utc.iso8601}. The worker applies it within a minute."
  rescue Sessions::UpdateMemoryBoost::Error => e
    redirect_back fallback_location: session_path(@session), alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: session_path(@session), alert: e.record.errors.full_messages.join(", ")
  end

  # DELETE /sessions/:id/memory_boost
  # Presentation ONLY — Sessions::UpdateMemoryBoost.clear, shared with the
  # `clear_memory_boost` MCP action.
  def clear_memory_boost
    @session = find_session

    with_db_retry { Sessions::UpdateMemoryBoost.clear(session: @session, actor: :web) }
    return if performed?

    redirect_back fallback_location: session_path(@session), notice: "Memory boost cleared."
  end

  # PATCH /sessions/:id/update_scheduling_class
  #
  # Move ONE session between spot and priority. This is the lever for a session
  # held behind the quota gate: promoting it starts it on the next re-check
  # without touching the trigger that spawned it, or the policy every other
  # session of its genesis shares. A blank value clears the choice and returns
  # the session to whatever its origin derives.
  #
  # Argument parsing and presentation ONLY — the write, its log rows and the
  # start on promotion are Sessions::UpdateSchedulingClass, shared with MCP's
  # `change_scheduling_class` and `PATCH /api/v1/sessions/:id`.
  def update_scheduling_class
    @session = find_session

    klass = params[:scheduling_class].to_s.strip
    placement = {}
    # Demoting to spot lands the session at the HEAD of the spot queue, a few
    # points above whatever is currently on top. That is the useful default and
    # the one the ranked view's button asks for: a session you have just decided
    # is not urgent enough to be priority is still, almost always, the spot work
    # you care most about — and leaving it on whatever rank it happened to carry
    # (usually 0, the bottom) would bury it behind the entire queue.
    if params[:place].to_s == SessionPrecedence::PLACE_TOP_OF_SPOT && klass == SessionGenesis::SPOT
      placement[:place] = SessionPrecedence::PLACE_TOP_OF_SPOT
    elsif params.key?(:precedence)
      placement[:precedence] = params[:precedence]
    end

    result = begin
      with_db_retry do
        Sessions::UpdateSchedulingClass.call(session: @session, scheduling_class: klass, actor: :web, start: false, **placement)
      end
    rescue Sessions::UpdateSchedulingClass::UnknownSchedulingClass => e
      return scheduling_class_failure(e.message)
    rescue ActiveRecord::RecordInvalid
      return scheduling_class_failure("Could not update: #{@session.errors.full_messages.join(', ')}")
    end
    # with_db_retry has already answered when it ran out of attempts.
    return if performed?

    # Outside the retry block: a retry after a start would find the class
    # already stored and read as no promotion at all.
    start = Sessions::UpdateSchedulingClass.start_if_promoted(result)
    respond_to do |format|
      format.json { render json: precedence_payload(@session).merge(start_notice(start)) }
      format.html do
        notice = [ "This session is now #{@session.priority_class}.", start&.message ].compact.join(" ")
        redirect_back fallback_location: session_path(@session), notice: notice
      end
    end
  end

  # The half of a Sessions::StartNow result the Ranked view shows. A refusal is
  # worth saying out loud (the row stays put and the user should know why); a
  # session with nothing queued is not, since nothing changed.
  def start_notice(result)
    return {} if result.nil? || result.nothing_queued?

    { start_outcome: result.outcome, start_message: result.message }
  end
  private :start_notice

  # POST /sessions/reprioritize
  #
  # The Reprioritize button at the top of the User view. Hands the board to the
  # deployment's durable reprioritizing session — reused rather than spawned
  # fresh, the way a trigger reuses a session — and reports which session took it
  # so the operator can watch it work.
  #
  # See Sessions::DashboardReprioritizer for why it is a trigger rather than a
  # bare `start_session`.
  def reprioritize
    result = Sessions::DashboardReprioritizer.call

    # Only a fire hands the board to a session. The other outcomes — burst
    # suppressed, a burst notice, a pending session, a target that is no longer
    # reusable — can still carry a session, and naming it in the panel would tell
    # the operator a session is re-ranking their board when none was given the job.
    # They are also not successes, so they are said as an alert.
    fired = result.fired?
    flash_kind = fired ? { notice: result.message } : { alert: result.message }

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "user_view_reprioritize",
            partial: "sessions/user_view_reprioritize",
            locals: { reprioritizer_session: (result.session if fired) }
          ),
          flash_stream(**flash_kind)
        ]
      end
      format.html { redirect_to root_path(view: VIEW_MODE_USER), **flash_kind }
    end
  rescue => e
    Rails.logger.error "[SessionsController#reprioritize] #{e.class}: #{e.message}"
    respond_with_flash(alert: "Could not start the reprioritizer: #{e.message}", location: root_path(view: VIEW_MODE_USER))
  end

  # POST /sessions/:id/authorize_merge
  #
  # The User view's Merge button. A human has decided this PR should land, and
  # the click is the sign-off — see Sessions::AuthorizeMerge for why this is the
  # one sanctioned route to an agent merging its own work, and for everything the
  # authorization records.
  #
  # Answers with the row's button re-rendered in its new state rather than with a
  # redirect, so the operator keeps their place on a board they are working top to
  # bottom. Double-clicking is harmless: the second call finds the PR already
  # authorized and reports that instead of sending a second message.
  def authorize_merge
    @session = find_session

    result = Sessions::AuthorizeMerge.call(session: @session)

    # The human's own words are the click. Recorded through the same capture every
    # other web-UI input goes through, so the session's provenance says a PERSON
    # authorized this rather than leaving the merge attributable only to the agent
    # that performed it.
    if result.sent?
      capture_web_ui_human_message(
        @session,
        "Merge #{result.pr_url}",
        "web_ui.authorize_merge"
      )
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "user_view_merge_#{@session.id}",
            partial: "sessions/user_view_merge_button",
            locals: { agent_session: @session }
          ),
          flash_stream(
            notice: (result.ok? ? result.message : nil),
            alert: (result.ok? ? nil : result.message)
          )
        ]
      end
      format.json do
        render json: { outcome: result.outcome, message: result.message, pr_url: result.pr_url },
          status: (result.ok? ? :ok : :unprocessable_entity)
      end
      format.html do
        respond_with_flash(
          notice: (result.ok? ? result.message : nil),
          alert: (result.ok? ? nil : result.message),
          location: @session
        )
      end
    end
  end

  # POST /sessions/:id/start_now
  # "Start it now" from the Ranked view's ⋮ menu: take this waiting session's
  # next turn immediately rather than when the scheduler gets round to it.
  def start_now
    @session = find_session

    result = Sessions::StartNow.call(@session, actor: "a user in the web UI")

    # Starting is a deliberate user interaction, the same as Refresh and Restart:
    # put the session's GitHub-poll cadence back at the fast end. Only when the
    # session is actually going to take a turn — a refused start changed nothing
    # about how often this session is worth polling.
    reset_poll_backoff(@session) if result.started?

    # Nothing is queued and the session has run before, so there is no turn to
    # pull forward — it is stranded rather than waiting. Nudging it is what the
    # Refresh button already does for exactly this session, so it is what Start
    # does too rather than reporting a dead end.
    if result.nothing_queued?
      success, error_message = restart_with_continue_prompt(@session)
      return if performed?

      return respond_with_flash(
        notice: (success ? "Continuing session #{@session.id}." : nil),
        alert: (success ? nil : "Could not start session #{@session.id}: #{error_message}"),
        location: @session
      )
    end

    respond_with_flash(
      notice: (result.started? ? result.message : nil),
      alert: (result.started? ? nil : result.message),
      location: @session
    )
  end

  # POST /sessions/:id/force_start
  #
  # "Force" on the queued-for-a-worker banner: take a worker thread off the turn
  # that most recently got one and give it to this session. Distinct from
  # #start_now, which moves a turn that is scheduled for later — a turn that is
  # already due and merely behind the pool has nothing to bring forward.
  def force_start
    @session = find_session

    result = Sessions::ForceTurnStart.call(
      @session,
      actor: "a user in the web UI",
      expected_victim_id: params[:expected_victim_id].presence
    )

    # The same deliberate-interaction signal Start and Restart send, and for the
    # same reason: a human has just said they are watching this session. Only on
    # a force that actually happened — a refusal changed nothing about how often
    # this session is worth polling.
    reset_poll_backoff(@session) if result.forced?

    respond_with_flash(
      notice: (result.forced? ? result.message : nil),
      alert: (result.forced? ? nil : result.message),
      location: @session
    )
  end

  # PATCH /sessions/:id/update_precedence
  # Set one session's rank in the spot queue. JSON for the ranked view, which
  # re-sorts the row in place; HTML for the session detail page's form.
  #
  # Presentation ONLY — the write and its log row are Sessions::UpdatePrecedence,
  # shared with the `change_precedence` MCP action and REST's PATCH.
  def update_precedence
    @session = find_session

    begin
      with_db_retry { Sessions::UpdatePrecedence.call(session: @session, precedence: params[:precedence], actor: :web) }
    rescue ActiveRecord::RecordInvalid
      message = "Could not update precedence: #{@session.errors.full_messages.join(', ')}"
      return respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: session_path(@session), alert: message }
      end
    end
    # with_db_retry has already answered when it ran out of attempts.
    return if performed?

    respond_to do |format|
      format.json { render json: precedence_payload(@session) }
      format.html do
        redirect_back fallback_location: session_path(@session),
          notice: "Precedence is now #{@session.precedence}."
      end
    end
  end

  # PATCH /sessions/:id/reorder_precedence
  # A drag-and-drop landing between two rows. The client names the neighbours it
  # dropped between and the server derives the value, so the midpoint rule and the
  # nudge that makes room for it live in one place rather than in JavaScript.
  def reorder_precedence
    @session = find_session

    above = neighbour_session(params[:above_id])
    below = neighbour_session(params[:below_id])

    result = Sessions::ReorderPrecedence.call(session: @session, above: above, below: below)

    # Only when THIS session's own value moved. `changes` also carries any
    # neighbour nudged aside, so keying off it would log a move on a session that
    # was dropped back onto the value it already had — and a log line per grab
    # would bury the session's real history.
    if result.changes.key?(@session.id)
      @session.logs.create!(
        content: "Precedence set to #{result.precedence} by drag-and-drop in the Ranked view",
        level: "info"
      )
    end

    render json: precedence_payload(@session).merge(
      # Every row whose value moved, including a neighbour nudged aside to make
      # room. The client corrects the numbers it rendered optimistically.
      changes: result.changes.map { |id, precedence| { id: id, precedence: precedence } }
    )
  # ReorderPrecedence writes the dragged row AND its neighbours, so a lock
  # timeout or a deadlock between two concurrent drags is a real outcome. The
  # client can act on any of them — it rolls the row back and reloads — so they
  # answer with the reason rather than a bare 500.
  rescue Sessions::ReorderPrecedence::Error, ActiveRecord::RecordInvalid,
         ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PATCH /sessions/:id/update_goal
  # Update the goal for a session via the web UI.
  #
  # The write, its refusals and its log row are Sessions::UpdateGoal, shared
  # with the `change_goal` MCP action and `PATCH /api/v1/sessions/:id`.
  def update_goal
    @session = find_session

    begin
      with_db_retry do
        Sessions::UpdateGoal.call(session: @session, goal: params[:goal], actor: :web)
      end
    rescue Sessions::UpdateGoal::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid
      return render json: { error: @session.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
    # with_db_retry has already answered when it ran out of attempts.
    return if performed?

    render json: { success: true, goal: @session.goal }
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

  # The search inputs, the view mode and the Filters — everything both halves of
  # the dashboard read from the request before deciding what to show.
  def resolve_dashboard_inputs
    # Search inputs. A search is "active" when there is a free-text query, an
    # agent-root filter, or a genesis narrowing — the three inputs that ask "find me
    # sessions matching this" and so replace the board with a flat result list. The
    # transcript-contents toggle only widens an existing text query, so it does not
    # by itself count.
    #
    # The scheduling class is deliberately NOT one of them. It is a filter, and a
    # filter narrows whichever view you are already in; treating it as a search would
    # mean that picking "Spot" once — a choice that now persists — silently replaced
    # the board with a flat list on every later visit, with nothing in the URL to
    # explain it.
    @search_query = params[:q].to_s.strip
    # "1" from this page's own checkbox, "true" from anyone who copied the REST
    # API's documented spelling — SessionSearchable.search_contents? accepts both.
    @search_contents = SessionSearchable.search_contents?(params[:search_contents])
    @agent_root_filter = params[:agent_root].to_s.strip
    @genesis_filter = params[:genesis].to_s.strip
    @genesis_filter = "" unless SessionGenesis.valid?(@genesis_filter)
    @search_active = @search_query.present? || @agent_root_filter.present? ||
                     @genesis_filter.present?

    # Which view the dashboard renders in. Resolved before the filters because the
    # Ranked view carries a different DEFAULT status filter — it is a queue of work
    # that has not run yet, so opening it on `needs_input` alone would show nothing.
    @view_mode = resolve_view_mode

    # The Filters section: which statuses to show, and the spot/priority narrowing.
    resolve_filters
  end

  # Every query the board makes, for the view #resolve_dashboard_inputs chose.
  def load_dashboard_board
    # Build the base visibility scope, applying the status filter. Used for every
    # fresh scope constructed below so the filters stay consistent.
    base_scope = lambda do |scope|
      # An empty status filter is "every status" — the user ticked nothing — so it
      # narrows nothing here rather than matching nothing.
      scope = scope.where(status: @status_filter) if @status_filter.any?
      # Status-summary forks are Zimmer's own bookkeeping, not the operator's
      # work — they are never a row on the dashboard, trash view included.
      scope.excluding_status_summary_forks
    end

    # Board visibility, applied to every branch below through the same lambda so no
    # view can silently forget it. An expired snooze is already "visible" to the
    # scope, which is how a snoozed session returns on its own with nothing having
    # written to its row. See SessionVisibility.
    board_scope = lambda do |scope|
      case @visibility_filter
      when VISIBILITY_OFF_BOARD then scope.board_hidden
      when VISIBILITY_ALL then scope
      else scope.board_visible
      end
    end

    sessions = base_scope.call(Session.all)

    if @agent_root_filter.present?
      sessions = filter_sessions_by_agent_root(sessions, @agent_root_filter)
    end

    if @priority_class_filter.present?
      sessions = sessions.priority_classified(@priority_class_filter)
    end

    if @genesis_filter.present?
      sessions = sessions.with_genesis(@genesis_filter)
    end

    # Deliberately last of the narrowing steps. A content scan spends a wall-clock
    # budget reading transcripts, so anything it reads that a later filter would have
    # discarded is budget the caller does not get back — and the notice it produces
    # says "all N sessions matching these filters", which is only true if every filter
    # is already applied. The REST and MCP surfaces order it the same way.
    if @search_query.present?
      if @search_contents
        # Bounded and newest-first — see SessionContentSearch. @content_scan is what
        # the results header reads to say whether the whole corpus was covered.
        sessions, @content_scan =
          search_sessions_by_content(sessions, @search_query, limit: CONTENT_SEARCH_LIMIT)
      else
        sessions = filter_sessions_by_search(sessions, @search_query)
      end
    end

    # Board visibility is the last narrowing, so the reveal count below is counted
    # through every other filter the operator has set. "3 tucked away" then means
    # three cards THIS board would otherwise be showing, rather than three
    # somewhere in the table — the number exists to talk them into revealing, and
    # it is only persuasive if revealing actually produces those three.
    @off_board_count = sessions.board_hidden.count
    sessions = board_scope.call(sessions)

    # The driver's axis, applied only when the Filters form asked for one bucket.
    # It never reorders: a laptop-only row keeps its place for the laptop.
    sessions = sessions.carplay_fit_filter(@carplay_fit_filter) if @carplay_fit_filter.present?

    # The Ranked view: the spot queue in the order it will actually be worked,
    # with the priority sessions that outrank all of it stacked above. Two
    # sections rather than one list, because the two halves answer different
    # questions — a priority session has no rank to compare, it simply starts —
    # and because the demote button only belongs on one of them.
    if @view_mode == VIEW_MODE_RANKED
      @ranked_priority_sessions = sessions.priority_classified(SessionGenesis::PRIORITY)
        .ranked.limit(RANKED_SECTION_LIMIT).to_a
      @ranked_spot_sessions = sessions.priority_classified(SessionGenesis::SPOT)
        .ranked.limit(RANKED_SECTION_LIMIT).to_a
      @ranked_section_limit = RANKED_SECTION_LIMIT
      @any_sessions = @ranked_priority_sessions.any? || @ranked_spot_sessions.any?
      return
    end

    # Flat sort views completely flatten the presentation: a single list sorted
    # solely by the chosen factor, honoring the same filters/visibility but
    # ignoring any grouping. They apply whether or not a search is active (search just
    # narrows the eligible set first).
    if @view_mode == VIEW_MODE_LAST_TOUCHED || @view_mode == VIEW_MODE_CREATED_DESC
      flat_sorted =
        if @view_mode == VIEW_MODE_LAST_TOUCHED
          sessions.order(Session::LAST_TOUCHED_ORDER)
        else
          sessions.order(created_at: :desc)
        end
      @flat_sessions = flat_sorted.page(scalar_page_param).per(SESSIONS_PER_PAGE)
      @flat_view_title = @view_mode == VIEW_MODE_LAST_TOUCHED ? "Sorted by last touched" : "Sorted by created (newest first)"
      @any_sessions = @flat_sessions.any?
      return
    end

    # The User view. One unified list of every session the filters match, ordered
    # so a priority session outranks every spot one and precedence is respected
    # all the way down.
    #
    # The ordering rule itself is Sessions::UserView's, shared with the
    # `get_user_view` MCP tool so the reprioritizing session reads exactly the
    # board the human is looking at.
    #
    # The select drops `transcript`. It is a legacy JSON column on `sessions`
    # (transcripts live in session_transcript_chunks now) and this view renders an
    # order of magnitude more rows than the card grid did, so a row that still
    # carries one would be paid for on every one of them. Nothing this view
    # renders reads it — `transcript_line_count` and `transcript_byte_size` are
    # their own columns, and ChunkedTranscript's `has_attribute?` guards degrade
    # correctly when the column is not selected.
    if @view_mode == VIEW_MODE_USER
      user_scope = sessions
        .select(Session.column_names - [ "transcript" ])
        .includes(:status_summary)

      # One more than the cap, so the "showing the first N" notice appears only when
      # a row was actually cut off rather than whenever exactly N sessions match.
      fetched = Sessions::UserView.rows(scope: user_scope, limit: USER_VIEW_LIMIT + 1)
      @user_view_truncated = fetched.size > USER_VIEW_LIMIT
      @user_view_sessions = fetched.first(USER_VIEW_LIMIT)
      @user_view_limit = USER_VIEW_LIMIT
      @any_sessions = @user_view_sessions.any?
      return
    end

    # No view mode left. Every branch above returns, and VALID_VIEW_MODES has no
    # fifth member — so reaching here means a mode was added without a branch, and
    # an empty dashboard would hide that rather than report it.
    raise "Unhandled dashboard view mode: #{@view_mode.inspect}"
  end

  # Resolve the dashboard view mode for #index, in precedence order:
  #   1. An explicit, valid ?view= param (or a LEGACY_VIEW_MODES name, remapped) —
  #      honored and persisted to a cookie so the choice survives subsequent
  #      navigation back to the dashboard.
  #   2. A previously-persisted valid cookie value (the user's last explicit pick),
  #      or a LEGACY_VIEW_MODES name remapped to the view that replaced it.
  #   3. The default: "last_touched" on mobile, "user" on desktop. The default
  #      only applies when the user has never explicitly chosen a view.
  def resolve_view_mode
    requested = params[:view].to_s
    # A bookmarked ?view=categories lands on the view that replaced it, the same as
    # a stale cookie does — and is persisted under its new name.
    requested = LEGACY_VIEW_MODES.fetch(requested, requested)
    if VALID_VIEW_MODES.include?(requested)
      cookies[VIEW_MODE_COOKIE] = { value: requested, expires: 1.year }
      return requested
    end

    persisted = cookies[VIEW_MODE_COOKIE].to_s
    return persisted if VALID_VIEW_MODES.include?(persisted)
    return LEGACY_VIEW_MODES[persisted] if LEGACY_VIEW_MODES.key?(persisted)

    mobile_request? ? VIEW_MODE_LAST_TOUCHED : VIEW_MODE_USER
  end

  # "Reset filters" is a GET that drops the persisted Filters choice and redirects to
  # a bare dashboard. Writing a display preference on a GET is the same thing
  # resolve_view_mode already does — this is a preference, not data.
  #
  # @return [Boolean] true when the request was a reset and a redirect was issued
  def reset_filters!
    return false unless params[:reset_filters] == "1"

    cookies.delete(FILTERS_COOKIE)
    redirect_to root_path
    true
  end

  # Resolve the Filters section — the status multi-select and the spot/priority
  # narrowing — from three sources, in order:
  #
  #   1. A submitted Filters form. Wins, and is persisted to FILTERS_COOKIE.
  #   2. The persisted choice from a previous submit. This is what makes a selection
  #      survive a reload and a bare visit to "/".
  #   3. The defaults.
  #
  # An empty status list is a real answer ("every status"), not an absent one, which
  # is why case 1 is detected by the form's hidden marker rather than by the presence
  # of status[] params.
  #
  # A search does not widen this. The ticked boxes always describe the result set,
  # including while searching — the alternative is a rule the user cannot see and
  # cannot reach from the form, since submitting the form always states the statuses.
  # Searching the trash means ticking Archived, or ticking nothing.
  def resolve_filters
    if params[FILTERS_SUBMITTED_PARAM] == "1"
      @status_filter = sanitized_status_filter(params[:status])
      @priority_class_filter = sanitized_priority_class(params[:priority_class])
      @visibility_filter = sanitized_visibility_filter(params[:visibility])
      @carplay_fit_filter = sanitized_carplay_fit_filter(params[:carplay_fit])
      cookies[FILTERS_COOKIE] = {
        value: {
          "status" => @status_filter,
          "priority_class" => @priority_class_filter,
          "visibility" => @visibility_filter,
          "carplay_fit" => @carplay_fit_filter
        }.to_json,
        expires: 1.year
      }
      return
    end

    if (persisted = persisted_filters)
      @status_filter = sanitized_status_filter(persisted["status"])
      @priority_class_filter = sanitized_priority_class(persisted["priority_class"])
      # A cookie written before this filter existed has no "visibility" key, which
      # sanitizes to the default rather than to nothing — an operator who never
      # asked to see hidden sessions keeps the board they had.
      @visibility_filter = sanitized_visibility_filter(persisted["visibility"])
      @carplay_fit_filter = sanitized_carplay_fit_filter(persisted["carplay_fit"])
      return
    end

    @status_filter = default_status_filter.dup
    @priority_class_filter = sanitized_priority_class(params[:priority_class])
    @visibility_filter = sanitized_visibility_filter(params[:visibility])
    @carplay_fit_filter = sanitized_carplay_fit_filter(params[:carplay_fit])
  end

  # One session's rank, as the ranked view's JavaScript needs it back.
  def precedence_payload(session)
    {
      id: session.id,
      precedence: session.precedence,
      priority_class: session.priority_class,
      scheduling_class: session.scheduling_class
    }
  end

  # A neighbour named by the drag. Missing ids resolve to nil (dropped at an end
  # of the list), and so does an id that is no longer a row of the spot queue —
  # archived, or promoted out of it — rather than failing the drop. The remaining
  # neighbour still places the session, and a stale page cannot nudge the
  # precedence of a row nobody is looking at.
  def neighbour_session(id)
    return nil if id.blank?

    Session.where.not(status: :archived).spot.find_by(id: id)
  end

  def scheduling_class_failure(message)
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: session_path(@session), alert: message }
    end
  end

  # The status filter applied when the user has never chosen one. See
  # DEFAULT_RANKED_STATUS_FILTER for why the Ranked view differs.
  def default_status_filter
    @view_mode == VIEW_MODE_RANKED ? DEFAULT_RANKED_STATUS_FILTER : DEFAULT_STATUS_FILTER
  end

  # The persisted Filters choice, or nil when there is none. A cookie a user (or a
  # stale release) left in a shape we no longer understand is treated as absent
  # rather than allowed to 500 the dashboard.
  def persisted_filters
    raw = cookies[FILTERS_COOKIE].to_s
    return nil if raw.blank?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # Statuses narrowed to the known set, so a hand-edited URL or an out-of-date cookie
  # drops the unknown entries instead of matching nothing (or raising).
  def sanitized_status_filter(value)
    list = value.is_a?(Array) ? value : Array(value.presence)
    list.map(&:to_s) & STATUS_FILTER_OPTIONS
  end

  # Spot/priority filter. Blank means "both". Validated against the known classes so
  # a hand-edited URL widens to both rather than narrowing to nothing.
  def sanitized_priority_class(value)
    klass = value.to_s.strip
    SessionGenesis::CLASSES.include?(klass) ? klass : ""
  end

  # Board visibility filter. Anything unrecognized — a hand-edited URL, or a cookie
  # written before this control existed — falls back to the default board rather
  # than to a state the Filters form cannot express.
  def sanitized_visibility_filter(value)
    choice = value.to_s.strip
    VISIBILITY_FILTER_OPTIONS.include?(choice) ? choice : VISIBILITY_ON_BOARD
  end

  # CarPlay-fit filter. Anything unrecognized — including a cookie written before
  # this control existed — is the unfiltered board, which is the default.
  def sanitized_carplay_fit_filter(value)
    choice = value.to_s.strip
    CARPLAY_FIT_FILTER_OPTIONS.include?(choice) ? choice : ""
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

  # Where to send a redirect that the drawer's Turbo Frame may follow.
  #
  # A frame follows a 302 with its own Turbo-Frame header still attached and then
  # looks for a matching frame in whatever comes back. /sessions/:id is frameless
  # by construction, so a redirect there from inside the drawer lands on a body
  # with no frame and renders "Content missing" — the same symptom the drawer's
  # own URL exists to prevent, reached by a different door. Send the frame to the
  # drawer's address instead.
  #
  # This reads the Turbo-Frame header to pick a redirect TARGET, which is not the
  # content negotiation that caused the bug: each URL still has exactly one body.
  def session_redirect_target(session)
    drawer_frame_request? ? drawer_session_path(session) : session_path(session)
  end

  # True when this request came from the dashboard drawer's Turbo Frame.
  def drawer_frame_request?
    request.headers["Turbo-Frame"] == "session_detail"
  end

  # Loads everything #show and #drawer render: the session and the
  # form/selector collections the detail view needs.
  #
  # Not the timeline. That is #transcript_panel's job — see load_timeline_tail,
  # and the deferred frame in _detail.html.erb that fetches it.
  def load_session_detail
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

    # The filter level the transcript frame will be asked for. The frame carries
    # it in its own src, and the log-level select is rendered from it, so it is
    # still resolved here even though nothing on this page reads the transcript.
    @filter_level = resolved_filter_level

    # The Transcript disclosure is collapsed on every ordinary load (see _detail).
    # The one address that asks for it open is the log-level filter's own re-fetch
    # (log_level_filter_controller.js#refetchAtLevel). Exact-match, not `present?`:
    # the param is one instruction with one spelling, so anything else leaves the
    # disclosure where the default puts it.
    @transcript_open = params[:transcript] == "open"

    # Load MCP servers for the editable MCP selector, each carrying whether
    # Zimmer can actually start it — see McpServerOptions.
    @servers_for_select = McpServerOptions.all

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
  end

  # The filter level this request should render at: the explicit param, or the
  # "minimal" default the client-side filter also starts from.
  def resolved_filter_level
    level = params[:filter].presence || "minimal"
    VALID_FILTER_LEVELS.include?(level) ? level : "minimal"
  end

  # Everything the transcript panel renders: the newest items of the timeline and
  # the cursors infinite scroll pages backwards from.
  #
  # No total. Counting what the active filter would show means normalizing every
  # transcript entry, which is the one cost on this path that grows with the
  # session, so the client fetches it on its own once the page before this one
  # is in (#timeline_items with `total_only`). When there is nothing older the
  # tail IS the whole timeline and its size is the total, which the view states
  # directly.
  def load_timeline_tail
    @filter_level = resolved_filter_level

    page = build_timeline_items_backward(@session, @filter_level, timeline_limit_param(TRANSCRIPT_TAIL_LIMIT))
    @timeline_items = page[:items]
    @has_more_items = page[:has_more]
    @oldest_displayed_timestamp = page[:next_before_timestamp]&.iso8601(6)
    @oldest_displayed_line = page[:next_before_line]
  end

  # A transcript line index from params: a non-negative integer, or nil for a
  # missing or malformed value (which then reads as "no hint"), never a silent 0.
  def line_index_param(name)
    value = Integer(params[name], exception: false) if params[name].is_a?(String)
    value if value && value >= 0
  end

  # The `limit` param, clamped to 1..MAX_TIMELINE_PAGE_LIMIT.
  def timeline_limit_param(default)
    params.fetch(:limit, default).to_i.clamp(1, MAX_TIMELINE_PAGE_LIMIT)
  end

  # True when the current request is a deliberate human page/drawer load, as
  # opposed to passive machinery. We require an HTML request and exclude the
  # browser's speculative hover-prefetch (SpeculativeRequest), which would
  # otherwise count "hovering a link" as a view.
  def human_initiated_view?
    return false unless request.format.html?

    !prefetch_request?
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
    with_db_retry { session.mark_notifications_read! }
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

  # Run one catalog-selection change and render the failure branch if there is
  # one. Returns the Result on success and nil once it has rendered, so an
  # action reads `return unless (result = apply_catalog_selection(...))`.
  def apply_catalog_selection(attribute, values)
    label = Session::CATALOG_SELECTIONS.fetch(attribute)[:label]
    unless values.nil? || values.is_a?(Array)
      render json: { error: "#{attribute} must be an array" }, status: :unprocessable_entity
      return nil
    end

    result = Sessions::UpdateCatalogSelection.call(
      session: @session,
      attribute: attribute,
      values: values || [],
      actor: :web
    )
    return result if result.ok?

    Rails.logger.warn "[SessionsController##{action_name}] #{label} update rejected: #{result.error}"
    status = result.error_code == :database_unavailable ? :service_unavailable : :unprocessable_entity
    render json: { error: result.error }, status: status
    nil
  end

  # Locals for the partials re-rendered after an MCP server change.
  # Mirrors the select-data structure expected by _session_metadata.html.erb and
  # _mobile_mcp_servers.html.erb so they render with edit affordances intact.
  def mcp_partials_locals(session)
    {
      agent_session: session,
      servers_for_select: McpServerOptions.all,
      catalog_skills_for_select: SkillsConfig.all.map { |s| { id: s.id, name: s.name, title: s.title, description: s.description, category: s.category } },
      catalog_hooks_for_select: HooksConfig.all.map { |h| { id: h.id, name: h.name, title: h.title, description: h.description } },
      plugins_for_select: PluginsConfig.all.map { |p| { id: p.id, title: p.title, description: p.description } },
      available_models: ModelCatalog.model_ids_for(session.agent_runtime),
      goals_for_select: GoalsConfig.all.map { |g| { id: g.id, name: g.name, description: g.description } }
    }
  end

  # The new-session form's half of the spawn-defaults resolution: work out which
  # root the form means and what it named, then hand the rest to
  # Sessions::ResolveSpawnDefaults, the resolution every spawn surface shares.
  #
  # The root is the one the form names. A post that names none falls back to the
  # root whose url is the posted git_root (and whose subdirectory is the posted
  # one, when a subdirectory was posted), and that fallback is a root like any
  # other — its defaults apply and its key is stamped.
  #
  # What counts as "named" here, and why it differs from REST and MCP:
  #   - agent_runtime and model: named only when the value is one the form could
  #     have offered. An unregistered runtime or an out-of-catalog model falls
  #     through to the root's, so a bad param never 500s the form.
  #   - mcp_servers: named when the key is present. The form always sends it (its
  #     picker emits a blank input when nothing is selected), so an empty list
  #     here is a human who picked no servers.
  #   - skills, hooks, plugins: always named. The form renders the root's
  #     defaults into those pickers, and a picker cleared to nothing submits no
  #     key at all, so an absent key is a cleared picker, never an omission —
  #     reading it as omitted would put back the defaults the human removed.
  def resolve_form_spawn_defaults!
    agent_root = if params[:agent_root_name].present?
      AgentRootsConfig.find(params[:agent_root_name])
    elsif @session.git_root.present?
      # The key this stamps outranks every later URL lookup, so where roots share
      # a repo the posted subdirectory has to pick among them.
      same_repo = AgentRootsConfig.all.select { |ar| ar.url == @session.git_root }
      if @session.subdirectory.present?
        same_repo.find { |ar| ar.subdirectory.to_s == @session.subdirectory }
      else
        same_repo.first
      end
    end

    requested_runtime = params[:agent_runtime].presence
    requested_runtime = nil unless RuntimeRegistry.registered_runtimes.include?(requested_runtime)
    @session.agent_runtime = requested_runtime if requested_runtime

    Sessions::ResolveSpawnDefaults.call(
      @session,
      agent_root_name: agent_root&.name,
      explicit_runtime: requested_runtime.present?,
      # The param, not the attribute: `sessions.branch` carries a column default,
      # so the attribute is present even on a post that named no branch.
      explicit_branch: session_params[:branch].present?,
      explicit_lists: { mcp_servers: session_params.key?(:mcp_servers), skills: true, hooks: true, plugins: true }
    )

    # Validated against the runtime just resolved, so it runs after it.
    requested_model = params[:model].to_s.strip.first(100).presence
    if requested_model && ModelCatalog.valid_model?(@session.agent_runtime, requested_model)
      @session.config = @session.config.merge("model" => requested_model)
    end

    # Not filtered like the model: an effort the model does not take is a
    # validation error the form re-renders with, not a silent fallback.
    requested_effort = params[:effort].to_s.strip.presence
    @session.config = @session.config.merge("effort" => requested_effort) if requested_effort

    # A root the catalog cannot resolve still records what the form posted,
    # which is what the existing-row heal and the "not in catalog" rendering
    # are for.
    if agent_root.nil? && params[:agent_root_name].present?
      @session.metadata = (@session.metadata || {}).merge("agent_root_key" => params[:agent_root_name])
    end
  end

  def session_params
    params.require(:session).permit(:prompt, :git_root, :subdirectory, :branch, :goal, :auto_compact_window, :scheduling_class, :precedence, mcp_servers: [], catalog_skills: [], catalog_hooks: [], catalog_plugins: []).tap do |permitted|
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
    @servers_for_select = McpServerOptions.all
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
    # runtime => model => { levels:, default: } for the effort picker, which
    # follows the model picker and hides itself for a model that takes none.
    @effort_options = ModelCatalog.effort_options_by_runtime

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
    @default_model = QuickRouterOptions.default_model_for(default_agent_root, @default_runtime)

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

  # Find session by numeric id or slug.
  def find_session
    Session.locate!(params[:id])
  end

  # The JSON the visibility control reads back. `board_visible` is the one the
  # page acts on.
  def visibility_payload(session)
    {
      success: true,
      session_id: session.id,
      visibility: session.visibility,
      effective_visibility: session.effective_visibility,
      board_visible: session.board_visible?,
      snoozed_until: session.snoozed_until&.iso8601,
      summary: session.visibility_summary
    }
  end

  # The JSON a CarPlay-fit control reads back.
  def carplay_fit_payload(session, result)
    {
      success: true,
      applied: result.applied?,
      message: result.message,
      session_id: session.id,
      carplay_fit: session.carplay_fit,
      effective_carplay_fit: session.effective_carplay_fit,
      carplay_fit_reason: session.carplay_fit_reason,
      carplay_fit_source: session.carplay_fit_source,
      summary: session.carplay_fit_summary
    }
  end

  def carplay_fit_notice(session)
    return "Session #{session.id}'s CarPlay fit cleared." if session.carplay_fit.blank?

    "Session #{session.id} marked #{session.carplay_fit_label}."
  end

  def visibility_notice(session)
    case session.visibility
    when SessionVisibility::HIDDEN then "Session #{session.id} hidden from the board."
    when SessionVisibility::SNOOZED then "Session #{session.id} snoozed until #{session.snoozed_until}."
    else "Session #{session.id} is back on the board."
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

  # Where a single-session #refresh should land. The per-card refresh icon on the
  # dashboard fires from the sessions index, and yanking the user to the session detail
  # page after clicking a small inline icon would be jarring — send them back to the
  # dashboard (which re-renders with the new status) instead. Refreshing from the
  # session's own page still lands on that page.
  #
  # The referer is used verbatim rather than a bare root_path so the dashboard's own
  # state survives the round trip: the flat "Sort By Last Touched" / "Sort By Created
  # Time" views and their page live in the query string, and dropping it would bounce
  # the user to an unfiltered view on page 1.
  # referrer_is_sessions_index? has already checked that the referer is this host's
  # index path, so it is not an open redirect.
  def refresh_redirect_target(session)
    referrer_is_sessions_index? ? request.referer : session_redirect_target(session)
  end

  # Check if the HTTP referer is the sessions index (home) page
  # Used to determine redirect behavior after refresh
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
      stderr_log_path = @session.stderr_log_path
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
      # The monitoring job will verify process status in the correct PID namespace, and
      # only for this pid — the one this restore was decided about.
      AgentSessionJob.enqueue_for_monitoring(session.id, monitor_pid: process_pid)

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
  # is sent to nudge the agent to continue where it left off. That operation — the
  # prompt choice, the key set, the transaction and its retry, the log rows, the
  # resume and the enqueue — belongs to Sessions::RestartWithPrompt, shared with the
  # REST API and the MCP tool so that the same request means the same thing through
  # every door. This method is only the dispatch to the from-scratch branch, the
  # session_id precondition, and the translation into the [success, error_message]
  # tuple the restart callers here already speak.
  #
  # @param session [Session] The failed session to restart
  # @return [Array<Boolean, String|nil>] [success, error_message] tuple
  def restart_with_continue_prompt(session)
    # When there is no conversation to prompt into — setup never completed (no
    # session_id, no working directory), or the session never ran at all — the
    # session cannot be restarted with a follow-up prompt, because there's no
    # clone to send it to. Re-enqueue as a new session to re-run the full setup
    # pipeline (git clone, MCP configuration, skill injection, process spawn).
    if session.needs_restart_from_scratch?
      return restart_from_scratch(session)
    end

    # Everything past here resumes a conversation, so it needs the id that
    # conversation is filed under. A session with no id but a transcript to lose
    # reaches this point (#needs_restart_from_scratch? deliberately does not claim
    # it), and is refused rather than silently started over. The job handles clone
    # recreation if the directory is missing, so working_directory is not checked.
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

    result = Sessions::RestartWithPrompt.call(session, actor: :web)

    result.ok? ? [ true, nil ] : [ false, result.error ]
  end

  # Restart a session from scratch by re-running the full setup pipeline.
  #
  # Used when a session failed before setup completed (e.g. the git clone failed)
  # and there are no setup artifacts to resume from. The operation itself —
  # the git_root guard, the metadata reset, the transaction and its retry, the
  # log rows, the resume, the enqueue and the job-id claim — belongs to
  # Sessions::RestartFromScratch, shared with the REST API and the MCP tool so
  # that the same request means the same thing through every door. This method is
  # only the translation into the [success, error_message] tuple the restart
  # callers here already speak.
  #
  # @param session [Session] The failed session to restart from scratch
  # @return [Array<Boolean, String|nil>] [success, error_message] tuple
  def restart_from_scratch(session)
    result = Sessions::RestartFromScratch.call(session, actor: :web)

    result.ok? ? [ true, nil ] : [ false, result.error ]
  end

  # What the flash says once a restart is under way, named for the state it was
  # asked from rather than for the `waiting` the session is in by now. The two
  # states the Restart control is offered from mean different things — a failed
  # session is being recovered, a `needs_input` one is being taken over — and
  # telling someone who clicked Restart on a paused session that Zimmer is
  # "restarting a failed session" is simply untrue.
  def restart_initiated_notice(restarted_a_failed_session)
    return "Attempting to restart failed session..." if restarted_a_failed_session

    "Restarting paused session..."
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

    working_directory = session.working_directory
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
        stale_keys = Session::STALE_RETRY_METADATA_KEYS

        # For pre-prompt failures, also clear runtime_started so the job
        # uses --session-id (with --mcp-config) instead of --resume.
        stale_keys += [ "runtime_started" ] if use_initial_prompt

        session.remove_metadata!(stale_keys)

        # Hand the turn over BEFORE enqueuing the job (the session queues in
        # `waiting`; a worker's `start` runs it)
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

  # How far past the page boundary the backward read keeps going. Transcript
  # lines are written in time order, but not strictly — a tool result can carry
  # an earlier timestamp than the line before it — and the page is cut by
  # sort_time, not by line. Reading a few lines further than the boundary is what
  # keeps an item that sorts just inside the page from being left out of it.
  BACKWARD_READ_OVERLAP = 20

  # One page of the timeline, read from the newest end backwards: the `limit`
  # newest items older than `before_ts` (all of them, when there is no cursor),
  # with the cursors for the page before it.
  #
  # The transcript is read through Session#each_transcript_line in reverse,
  # which fetches one stored chunk at a time and stops as soon as the page is
  # full — so the newest ten items of a 30 MB transcript cost the last chunk or
  # two, not the document. `before_line` starts the read below lines the client
  # already has; `through_index` keeps it going until that transcript index is
  # in the page (a deep link), however many items that takes.
  #
  # Logs (show-logs, verbose) are their own source, cut by the same timestamp
  # in SQL, and merged before the page is taken.
  #
  # Lines with no timestamp of their own (Claude's `last-prompt`, `mode`,
  # `cost-state` bookkeeping) sort at the session's created_at, all of them
  # together, whatever line they were written on. They cannot take part in a
  # backward read — counted against a page, they would fill it and drag the
  # cursor to created_at, ending the history early — so they are left out of
  # every page except the one spanning created_at, which collects all of them
  # in one full pass (see #undated_timeline_events).
  #
  # @return [Hash] items:, has_more:, next_before_timestamp:, next_before_line:
  def build_timeline_items_backward(session, filter_level, limit, before_ts: nil, before_line: nil, through_index: nil)
    upper = session.transcript_line_count
    upper = [ upper, before_line + BACKWARD_READ_OVERLAP ].min if before_line
    source = session.transcript_present? ? TranscriptRuntime.source_for(session) : nil
    undated_at = session.created_at

    per_line = []
    visible = 0
    stop_at = nil
    transcript_exhausted = true

    if source
      session.each_transcript_line(0, upper, reverse: true) do |index, line|
        break if stop_at && index < stop_at

        entry = source.parse_events(line).first
        next if entry.nil?

        events = build_transcript_timeline_item(entry, index, session).reject { |event| event[:sort_time] == undated_at }
        events = events.select { |event| event[:sort_time] < before_ts } if before_ts
        per_line << events
        visible += events.count { |event| item_visible_for_filter?(event, filter_level) }

        next if stop_at || visible <= limit
        next if through_index && index > through_index

        stop_at = index - BACKWARD_READ_OVERLAP
        transcript_exhausted = stop_at <= 0
      end
    end

    transcript_events = per_line.reverse.flatten(1)
    include_logs = filter_level == "show-logs" || filter_level == "verbose"
    timeline_items = transcript_events.dup
    if include_logs
      logs = timeline_logs(session, filter_level)
      logs = logs.where("created_at < ?", before_ts) if before_ts
      page_logs = logs.order(created_at: :desc).limit(limit + 1).to_a.reverse
      # A deep link can reach further back than `limit` logs would: every log
      # from the deep-linked row onwards belongs on the page with it.
      floor = transcript_events.select { |event| through_index && event[:transcript_index].to_i >= through_index }.map { |event| event[:sort_time] }.min
      page_logs = (logs.where("created_at >= ?", floor).to_a + page_logs).uniq(&:id).sort_by(&:created_at) if floor
      page_logs.each { |log| timeline_items << build_log_timeline_item(log) }
    end

    filtered = filter_timeline_items(OpenTranscript.sort_events(timeline_items), filter_level)
    take = limit
    if through_index
      first_wanted = filtered.index { |item| item[:transcript_index] && item[:transcript_index] >= through_index }
      take = [ take, filtered.size - first_wanted ].max if first_wanted
    end
    # Never cut a page between two items with the same sort_time: the next page
    # asks for items strictly older than this page's oldest, so the other half of
    # a tie would never be shown. A log and a transcript line stamped the same
    # second is the ordinary case.
    take += 1 while take < filtered.size && filtered[-take - 1][:sort_time] == filtered[-take][:sort_time]
    items = filtered.last(take)
    left_behind = filtered.first(filtered.size - items.size)

    has_more = left_behind.any? || !transcript_exhausted
    if include_logs && !has_more && items.any?
      has_more = timeline_logs(session, filter_level).where("created_at < ?", items.first[:sort_time]).exists?
    end
    next_before_line = next_backward_line(items, left_behind, stop_at)
    next_before_timestamp = items.first&.dig(:sort_time)

    # The undated lines all sort at created_at, so they belong to whichever page
    # spans that instant: usually the last one, since a session is created
    # before its conversation, but a fork's inherited history is older than the
    # fork itself.
    if source && undated_at < (before_ts || Float::INFINITY) && (!has_more || (items.any? && undated_at >= items.first[:sort_time]))
      items = OpenTranscript.sort_events(undated_timeline_events(session, source, filter_level) + items)
    end

    { items: items, has_more: has_more, next_before_timestamp: next_before_timestamp, next_before_line: next_before_line }
  end

  # Every visible event whose line carried no timestamp of its own, in line
  # order. A full read of the transcript, so it is reached only once, by the
  # page spanning the session's created_at.
  def undated_timeline_events(session, source, filter_level)
    events = []
    session.each_transcript_line(0, session.transcript_line_count) do |index, line|
      entry = source.parse_events(line).first
      next if entry.nil?

      events.concat(build_transcript_timeline_item(entry, index, session).select { |event| event[:sort_time] == session.created_at })
    end
    filter_timeline_items(OpenTranscript.sort_events(events), filter_level)
  end

  # The logs a filter level shows: show-logs leaves verbose logs out, so they
  # must not fill the page's SQL limit and push an older info log off it.
  def timeline_logs(session, filter_level)
    filter_level == "show-logs" ? session.logs.where.not(level: "verbose") : session.logs
  end

  # Where the next page's backward read starts: just above the highest line any
  # item left off this page came from, so nothing read and not shown is skipped.
  # nil when nothing on this page came from the transcript — the next read then
  # starts at the end, and the timestamp alone decides.
  def next_backward_line(items, left_behind, stop_at)
    lines = left_behind.filter_map { |item| item[:transcript_index] }
    return lines.max + 1 if lines.any?

    shown = items.filter_map { |item| item[:transcript_index] }
    return nil if shown.empty?

    [ shown.min, stop_at.to_i ].max
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
    #
    # That scan is linear in transcript size, so its answer is cached against the
    # transcript itself: every write moves `transcript_digest` (and an append
    # moves the line and byte counts too), so a count is never served for a
    # transcript other than the one it was taken over.
    cache_key = [
      "session-timeline-transcript-count", session.id, session.transcript_digest,
      session.transcript_line_count, session.transcript_byte_size, filter_level
    ]
    transcript_count = Rails.cache.fetch(cache_key, expires_in: 1.day) do
      count_transcript_entries_for_filter(session, filter_level)
    end

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

    # A tool call that renders an MCP App view is not tool noise: the view IS the
    # result, and it is the one tool row a reader can act on. So it is in the
    # `message` bucket at every filter level, which is the same answer
    # _item.html.erb writes into data-filter-category for the client-side filter.
    # See McpApps::TimelineTrigger.
    return true if mcp_apps_trigger.panel_for(item)

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

  # One MCP Apps trigger per request. Memoized because the filter asks it about
  # every item in the transcript, and it is what holds the settings read and the
  # per-server tool index for all of them.
  def mcp_apps_trigger
    @mcp_apps_trigger ||= McpApps::TimelineTrigger.new(@session)
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

      # Determine the speaker label. A line the CLI wrote into its own
      # transcript wearing a user role is labelled for what it is — the copied
      # text is read by the same person reading the timeline, and it carried the
      # same false attribution.
      label = if ClaudeTranscriptNormalizer.runtime_notice_markers(entry).any?
        "Runtime Notice (agent runtime, not a person)"
      else
        case role
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

  # The Quick Router's spot opt-in, shared by the dashboard quick prompt and the
  # chat bubble.
  #
  # Only an explicit "spot" writes anything. An untouched submission returns nil
  # so the row's `scheduling_class` stays NULL and the class keeps deriving from
  # the `web_ui` genesis on every read, which is what lets /inference move these
  # sessions by moving that genesis. Stamping "priority" here instead would pin
  # the shipped default onto every Quick Router session and sever that link.
  def quick_router_scheduling_class
    params[:scheduling_class].to_s.strip == SessionGenesis::SPOT ? SessionGenesis::SPOT : nil
  end

  # The runtime this Quick Router submission runs under: the harness the user
  # picked when they picked one the registry carries, the router root's own
  # otherwise (which has already folded in the global base default). Both the
  # model validation below and the created row key on this one value — the model
  # is only valid for the runtime it was validated against, so resolving the pair
  # twice is how they could come apart.
  def quick_router_effective_runtime
    quick_router_options.effective_runtime(params[:agent_runtime])
  end

  # The Quick Router's model opt-in.
  #
  # Only a model the effective runtime actually offers writes anything. An
  # untouched picker posts a blank `model`, which returns nil here so `config`
  # is left unset and Sessions::ResolveSpawnDefaults resolves the model at
  # create time — the router root's default_model, then the Settings default,
  # then the runtime's catalog default. The form never submits that default
  # itself: a dashboard tab left open across a Settings change or a roots.json
  # edit would otherwise post yesterday's default as if someone had chosen it,
  # and the resolution would live in two places.
  #
  # On `quick_prompt` an unrecognized value is ignored rather than rejected,
  # matching the spot opt-in: that surface redirects, so rejecting would throw
  # away the prompt someone just typed, and the prompt is worth more than a form
  # field. The action says so in its notice when it happens. `chat_bubble` loses
  # nothing on a rejection — its panel stays open with the draft in it — so it
  # rejects instead; see that action.
  def quick_router_model(runtime)
    quick_router_options.resolve_model(runtime, params[:model])
  end

  # Where a Quick-Router spot submission lands in the spot queue.
  #
  # A human typed this one seconds ago and chose to let it wait for quota room —
  # that is a statement about quota, not about importance. Leaving it at the
  # default precedence of 0 files it beneath every automated spot session ranked
  # above 0, and behind every older session tied at 0, so it goes to the top of
  # the queue instead; the UI on each surface says so.
  #
  # nil for a priority submission, which leaves the ordinary inheritance alone
  # (the chat bubble's child-of-parent bump, DEFAULT everywhere else).
  def quick_router_precedence(scheduling_class)
    return nil unless scheduling_class == SessionGenesis::SPOT

    Session.precedence_for_place(SessionPrecedence::PLACE_TOP_OF_SPOT)
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
