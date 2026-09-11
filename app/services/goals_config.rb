# frozen_string_literal: true

# Service class for managing goal configurations
# Reads and parses the goals.json catalog file
class GoalsConfig
  class GoalNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  GOALS_CONFIG_PATH = Rails.root.join("config", "goals.json")

  # Goal configuration object
  class Goal
    attr_reader :id, :name, :description, :checks

    def initialize(id, config)
      @id = id
      @name = config["name"]
      @description = config["description"]
      # What GoalCheck can read off recorded state for this goal — criterion keys
      # from GoalCheck::CRITERIA. Empty means the goal is prompt text only.
      @checks = Array(config["checks"]).map(&:to_s).freeze
    end

    # Convert to hash representation
    def to_h
      {
        id: id,
        name: name,
        description: description,
        checks: checks
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end

  class << self
    # Get all available goals
    # @return [Array<Goal>] list of goal objects
    def all
      @all ||= load_goals
    end

    # Find a goal by ID
    # @param id [String] the goal ID
    # @return [Goal, nil] the goal object or nil if not found
    def find(id)
      all.find { |goal| goal.id == id }
    end

    # Find a goal by ID, raise error if not found
    # @param id [String] the goal ID
    # @return [Goal] the goal object
    # @raise [GoalNotFoundError] if goal is not found
    def find!(id)
      find(id) || raise(GoalNotFoundError, "Goal '#{id}' not found in catalog")
    end

    # Get list of goal IDs
    # @return [Array<String>] list of goal IDs
    def ids
      all.map(&:id)
    end

    # Check if a goal exists
    # @param id [String] the goal ID
    # @return [Boolean] true if goal exists
    def exists?(id)
      find(id).present?
    end

    # The catalog goal a session's stored goal names, or nil for a free-text goal.
    #
    # A session's goal column holds one of two shapes for a catalog goal: the id
    # (the web form, `POST /api/v1/sessions`, `change_goal`, a trigger) or the
    # description verbatim, because MCP `start_session` swaps an id for its
    # description before it stores it. Both name the same goal.
    #
    # @param goal [String, nil] a session's goal
    # @return [Goal, nil]
    def resolve(goal)
      value = goal.to_s.strip
      return nil if value.empty?

      find(value) || all.find { |g| g.description.to_s.strip == value }
    end

    # The shape of a catalog id: one "word" of ASCII letters and digits, joined by
    # hyphens, underscores or dots. Deliberately ASCII — a sentence in a script
    # written without spaces is free text, not an id.
    ID_SHAPE = /\A[a-z0-9]+(?:[-_.][a-z0-9]+)*\z/i

    # A goal is either a catalog id or a sentence. A single word shaped like an id
    # can only have been meant as one — and an id the catalog does not have is a
    # typo that would otherwise reach the agent as free text ("The user has
    # indicated the goal for this task is: open-reviewd-pr").
    #
    # @param goal [String, nil]
    # @return [Boolean] true when the goal is id-shaped and names no catalog goal
    def unknown_id?(goal)
      value = goal.to_s.strip
      value.match?(ID_SHAPE) && !exists?(value)
    end

    # Why an id-shaped goal was refused, phrased to follow the word "Goal" — the
    # form ActiveModel's full_messages gives it, and the form every surface shows.
    #
    # @param goal [String]
    # @return [String]
    def unknown_id_reason(goal)
      "#{goal.to_s.strip.inspect} is not a known goal id (known: #{ids.join(', ')}). " \
        "A free-text goal is also accepted, but it has to be a sentence, not a single word."
    end

    # @param goal [String]
    # @return [String] the refusal as a whole sentence, for surfaces that do not
    #   prefix an attribute name
    def unknown_id_message(goal)
      "Goal #{unknown_id_reason(goal)}"
    end

    # Reload the configuration from disk
    # @return [Array<Goal>] reloaded list of goals
    def reload!
      @all = nil
      @config = nil
      all
    end

    # Get the raw configuration hash
    # @return [Hash] the parsed JSON configuration
    def config
      @config ||= load_config
    end

    private

    # Load and parse the goals.json file
    def load_config
      unless File.exist?(GOALS_CONFIG_PATH)
        raise ConfigurationError, "Goals configuration file not found at #{GOALS_CONFIG_PATH}"
      end

      JSON.parse(File.read(GOALS_CONFIG_PATH))
    rescue JSON::ParserError => e
      raise ConfigurationError, "Invalid JSON in goals configuration: #{e.message}"
    end

    # Load goals from configuration
    def load_goals
      goals_data = config["goals"] || {}
      goals_data.map { |id, goal_config| Goal.new(id, goal_config) }.each { |goal| validate_checks!(goal) }
    end

    # A check name GoalCheck does not implement would be silently skipped, which
    # would report a goal as checked on fewer criteria than its catalog entry
    # claims. Refuse to load instead.
    def validate_checks!(goal)
      unknown = goal.checks - GoalCheck::CRITERIA.keys
      return if unknown.empty?

      raise ConfigurationError,
        "Goal '#{goal.id}' declares unknown checks: #{unknown.join(', ')}. Known: #{GoalCheck::CRITERIA.keys.join(', ')}"
    end
  end
end
