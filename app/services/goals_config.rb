# frozen_string_literal: true

# Service class for managing goal configurations
# Reads and parses the goals.json catalog file
class GoalsConfig
  class GoalNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  GOALS_CONFIG_PATH = Rails.root.join("config", "goals.json")

  # Goal configuration object
  class Goal
    attr_reader :id, :name, :description

    def initialize(id, config)
      @id = id
      @name = config["name"]
      @description = config["description"]
    end

    # Convert to hash representation
    def to_h
      {
        id: id,
        name: name,
        description: description
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
      goals_data.map { |id, goal_config| Goal.new(id, goal_config) }
    end
  end
end
