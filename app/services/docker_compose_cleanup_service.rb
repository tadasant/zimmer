# frozen_string_literal: true

require "open3"
require "timeout"

# Service for cleaning up Docker Compose resources associated with a clone directory.
#
# When agent sessions use Docker containers (via .agent-containers/docker-compose.dev.yml),
# archiving the session should tear down those containers, volumes, and networks.
# Without this, Docker resources accumulate on the host.
#
# Assumes containers were started using the same compose file path, so the project
# name (derived by Docker Compose from the directory) matches the running resources.
#
# Usage:
#   DockerComposeCleanupService.cleanup(clone_path)
#
class DockerComposeCleanupService
  COMPOSE_FILE_RELATIVE_PATH = ".agent-containers/docker-compose.dev.yml"
  COMPOSE_DOWN_TIMEOUT = 120 # seconds — overall timeout for the entire docker compose down operation
  CONTAINER_STOP_TIMEOUT = 30 # seconds — per-container stop grace period passed to docker compose

  class << self
    # Clean up Docker Compose resources for a clone directory.
    # Checks if a docker-compose file exists and runs `docker compose down -v` to
    # remove containers, volumes, and networks.
    #
    # @param clone_path [String] the path to the clone directory
    # @return [Boolean] true if cleanup was performed, false if skipped (no compose file)
    def cleanup(clone_path)
      return false unless clone_path

      compose_file = File.join(clone_path, COMPOSE_FILE_RELATIVE_PATH)
      return false unless File.exist?(compose_file)

      Rails.logger.info "[DockerComposeCleanupService] Found compose file at #{compose_file}, tearing down Docker resources"

      run_compose_down(compose_file)
      true
    rescue StandardError => e
      Rails.logger.error "[DockerComposeCleanupService] Error during Docker cleanup for #{clone_path}: #{e.class} - #{e.message}"
      # Don't re-raise — Docker cleanup failure should not prevent clone directory cleanup
      false
    end

    private

    def run_compose_down(compose_file)
      command = [
        "docker", "compose", "-f", compose_file,
        "down", "-v", "--remove-orphans",
        "--timeout", CONTAINER_STOP_TIMEOUT.to_s
      ]

      stdout, stderr, status = Timeout.timeout(COMPOSE_DOWN_TIMEOUT) do
        Open3.capture3(*command)
      end

      if status.success?
        Rails.logger.info "[DockerComposeCleanupService] Docker Compose down succeeded"
      else
        Rails.logger.warn "[DockerComposeCleanupService] Docker Compose down exited with status #{status.exitstatus}: stdout=#{stdout.to_s.truncate(500)} stderr=#{stderr.to_s.truncate(500)}"
      end
    end
  end
end
