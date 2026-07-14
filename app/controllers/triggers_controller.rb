# frozen_string_literal: true

# Controller for managing Triggers - automated session creation based on external events
#
# Triggers monitor external sources (like Slack channels, time schedules, or Zimmer events)
# and automatically create agent sessions when configured events occur.
# A trigger can have multiple conditions (OR semantics) — if any condition fires,
# the trigger's session template executes.
class TriggersController < ApplicationController
  before_action :set_trigger, only: %i[show edit update destroy toggle toggle_enqueue_messages toggle_resuscitate_archived invoke]
  before_action :load_form_data, only: %i[new create edit update]

  def index
    @triggers = Trigger.includes(:trigger_conditions).order(created_at: :desc)
  end

  def show
    # Load recent sessions created by this trigger
    @recent_sessions = Session
      .where("metadata->>'trigger_id' = ?", @trigger.id.to_s)
      .order(created_at: :desc)
      .limit(10)
  end

  def new
    @trigger = Trigger.new(status: "enabled")
    # Add a default condition based on type param
    condition_type = TriggerCondition::CONDITION_TYPES.include?(params[:type]) ? params[:type] : "slack"
    @trigger.trigger_conditions.build(condition_type: condition_type, configuration: {})
  end

  def create
    @trigger = Trigger.new(trigger_params)

    if @trigger.save
      redirect_to @trigger, notice: "Trigger created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @trigger.update(trigger_params)
      redirect_to @trigger, notice: "Trigger updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @trigger.destroy
    redirect_to triggers_path, notice: "Trigger deleted successfully."
  end

  # Toggle trigger enabled/disabled status
  def toggle
    @trigger.toggle!

    respond_to do |format|
      format.html { redirect_to triggers_path, notice: "Trigger #{@trigger.enabled? ? 'enabled' : 'disabled'}." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "trigger_#{@trigger.id}",
          partial: "trigger",
          locals: { trigger: @trigger }
        )
      end
    end
  end

  # Toggle enqueue_messages setting (only when reuse_session is enabled)
  def toggle_enqueue_messages
    unless @trigger.reuse_session
      redirect_to @trigger, alert: "Enqueue messages can only be enabled when re-use session is enabled."
      return
    end

    @trigger.update!(enqueue_messages: !@trigger.enqueue_messages)

    respond_to do |format|
      format.html { redirect_to @trigger, notice: "Enqueue messages #{@trigger.enqueue_messages ? 'enabled' : 'disabled'}." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "trigger_#{@trigger.id}",
          partial: "trigger",
          locals: { trigger: @trigger }
        )
      end
    end
  end

  # Toggle resuscitate_archived setting (only when reuse_session is enabled)
  def toggle_resuscitate_archived
    unless @trigger.reuse_session
      redirect_to @trigger, alert: "Resuscitate archived can only be enabled when re-use session is enabled."
      return
    end

    @trigger.update!(resuscitate_archived: !@trigger.resuscitate_archived)

    respond_to do |format|
      format.html { redirect_to @trigger, notice: "Resuscitate archived #{@trigger.resuscitate_archived ? 'enabled' : 'disabled'}." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "trigger_#{@trigger.id}",
          partial: "trigger",
          locals: { trigger: @trigger }
        )
      end
    end
  end

  # Manually invoke a trigger, optionally with variable overrides
  def invoke
    # Must stay in step with Trigger::USER_INPUT_VARIABLES — the manual-run form renders an
    # input per variable the template uses, and anything not permitted here is silently
    # dropped and interpolated as an empty string.
    variables = params.permit(*Trigger::USER_INPUT_VARIABLES.map(&:to_sym))
    prompt = @trigger.interpolate_prompt(**variables.to_h.symbolize_keys)

    session = @trigger.create_session!(prompt: prompt)
    redirect_to session_path(session), notice: "Trigger \"#{@trigger.name}\" fired manually. Session created."
  rescue => e
    redirect_to trigger_path(@trigger), alert: "Failed to invoke trigger: #{e.message}"
  end

  # API endpoint to get available Slack channels for the form
  def channels
    unless SlackService.configured?
      render json: { error: "Slack is not configured. Please set SLACK_BOT_TOKEN." }, status: :service_unavailable
      return
    end

    channels = SlackService.list_channels
    render json: {
      channels: channels.map do |channel|
        {
          id: channel.id,
          name: channel.name,
          is_private: channel.is_private,
          num_members: channel.num_members
        }
      end
    }
  rescue SlackService::SlackError => e
    render json: { error: e.message }, status: :service_unavailable
  end

  private

  def set_trigger
    @trigger = Trigger.includes(:trigger_conditions).find(params[:id])
  end

  def load_form_data
    @agent_roots = AgentRootsConfig.all
    @servers_for_select = ServersConfig.all.map do |server|
      {
        name: server.name,
        title: server.title,
        description: server.description
      }
    end

    @goals = GoalsConfig.all.map do |goal|
      {
        id: goal.id,
        name: goal.name,
        description: goal.description
      }
    end

    # Catalog skills for multi-select
    @catalog_skills_for_select = SkillsConfig.all.map do |skill|
      {
        id: skill.id,
        name: skill.name,
        title: skill.title,
        description: skill.description,
        category: skill.category
      }
    end

    # Create a mapping of agent root names to their default MCP servers
    @agent_root_mcp_servers = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_mcp_servers.present?
        valid_servers = agent_root.default_mcp_servers.select { |name| ServersConfig.exists?(name) }
        hash[agent_root.name] = valid_servers if valid_servers.any?
      end
    end

    # Create a mapping of agent root names to their default catalog skills
    @agent_root_catalog_skills = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_skills.present?
        valid_skills = agent_root.default_skills.select { |name| SkillsConfig.exists?(name) }
        hash[agent_root.name] = valid_skills if valid_skills.any?
      end
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

    # Plugins for multi-select
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

    # Create a mapping of agent root names to their default goals
    @agent_root_goals = @agent_roots.each_with_object({}) do |agent_root, hash|
      if agent_root.default_goal.present?
        goal = GoalsConfig.find(agent_root.default_goal)
        hash[agent_root.name] = goal&.description if goal
      end
    end

    # Note: Slack channels are loaded asynchronously via JS to avoid blocking page load
    # See trigger_form_controller.js and the /triggers/channels endpoint
    @slack_configured = SlackService.configured?
  end

  def trigger_params
    params.require(:trigger).permit(
      :name,
      :status,
      :agent_root_name,
      :goal,
      :prompt_template,
      :reuse_session,
      :enqueue_messages,
      :resuscitate_archived,
      mcp_servers: [],
      catalog_skills: [],
      catalog_hooks: [],
      catalog_plugins: [],
      trigger_conditions_attributes: [
        :id, :condition_type, :_destroy,
        configuration: [ :channel_id, :channel_name, :event_type, :thread_ts, :interval, :unit, :time, :day_of_week, :timezone, :event_name, :scheduled_at, :watched_session_id, :target, allowed_user_ids: [], repos: [], labels: [] ]
      ]
    ).tap do |p|
      # Ensure mcp_servers is an array and strip blanks from form submission
      p[:mcp_servers] = (p[:mcp_servers] || []).reject(&:blank?)
      # Ensure catalog_skills is an array and strip blanks from form submission
      p[:catalog_skills] = (p[:catalog_skills] || []).reject(&:blank?)
      # Ensure catalog_hooks is an array and strip blanks from form submission
      p[:catalog_hooks] = (p[:catalog_hooks] || []).reject(&:blank?)
      # Ensure catalog_plugins is an array and strip blanks from form submission
      p[:catalog_plugins] = (p[:catalog_plugins] || []).reject(&:blank?)
    end
  end
end
