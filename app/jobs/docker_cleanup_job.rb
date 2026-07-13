# frozen_string_literal: true

require "open3"

# Periodic job to reclaim Docker disk space and clean up stale dev-server containers.
#
# Three responsibilities:
#
#   1. **Stale dev-server cleanup** — Dev-server Compose stacks (zimmer-dev-*, and the
#      inherited ao-dev-*/pulsemcp-dev-* from Zimmer's ancestor) are started by agent
#      sessions but aren't tracked in the DB by project name. If the
#      session's clone-based cleanup fails (disk full, timeout, clone already deleted), the
#      containers become permanent orphans. This job discovers them by naming convention and
#      stops any stack running longer than MAX_DEV_SERVER_AGE.
#
#   2. **Docker image pruning** — Each Zimmer deploy pulls an ~8.8 GB image. Without pruning,
#      old images accumulate after every deploy. Prunes images unused for 24+ hours.
#
#   3. **Emergency disk handling** — When disk usage exceeds EMERGENCY_THRESHOLD, aggressively
#      prunes all unused Docker resources (images, volumes, build cache) regardless of age.
#
# Runs every 6 hours via GoodJob cron. Safe to run at any time — only affects containers
# and images not currently in use.
#
class DockerCleanupJob < ApplicationJob
  queue_as :default

  # Dev-server Compose stacks older than this are considered stale.
  # 6 hours is generous — most sessions complete well within this window,
  # and restarting a dev-server is cheap if we accidentally stop an active one.
  MAX_DEV_SERVER_AGE = 6.hours

  # Docker Compose project name prefixes used by dev-server skills.
  # `zimmer-dev-` is Zimmer's own (.agent-containers/ac.sh names stacks this way);
  # `ao-dev-`/`pulsemcp-dev-` are inherited from Zimmer's ancestor and kept so a
  # mixed-history box doesn't leak either lineage's stacks.
  DEV_SERVER_PREFIXES = %w[zimmer-dev- ao-dev- pulsemcp-dev-].freeze

  # Keep images used in the last 24 hours (covers rollback window)
  IMAGE_AGE_FILTER = "24h"

  # Disk usage percentage that triggers aggressive cleanup
  EMERGENCY_THRESHOLD = 90

  def perform
    cleanup_stale_dev_servers
    prune_stopped_containers
    prune_old_images
    prune_dangling_volumes

    if disk_usage_percent >= EMERGENCY_THRESHOLD
      Rails.logger.warn "[DockerCleanupJob] Disk usage at #{disk_usage_percent}%, running emergency cleanup"
      emergency_cleanup
    end

    log_disk_usage
  end

  private

  # ---------------------------------------------------------------------------
  # Stale dev-server cleanup
  # ---------------------------------------------------------------------------

  def cleanup_stale_dev_servers
    stale_projects = find_stale_dev_server_projects
    return if stale_projects.empty?

    Rails.logger.info "[DockerCleanupJob] Found #{stale_projects.size} stale dev-server project(s): #{stale_projects.join(', ')}"

    stale_projects.each do |project_name|
      stop_compose_project(project_name)
    end
  end

  # Discovers running dev-server Compose projects that are older than MAX_DEV_SERVER_AGE.
  # Uses `docker ps` to find containers matching the naming convention, then extracts
  # unique project names from the container labels.
  def find_stale_dev_server_projects
    # List all running containers with their compose project and creation time
    stdout, _stderr, status = run_command(
      "docker", "ps",
      "--filter", "status=running",
      "--format", '{{.Label "com.docker.compose.project"}}\t{{.CreatedAt}}'
    )
    return [] unless status.success?

    cutoff = MAX_DEV_SERVER_AGE.ago
    stale_projects = Set.new

    stdout.each_line do |line|
      project, created_at_str = line.strip.split("\t", 2)
      next if project.blank? || created_at_str.blank?
      next unless DEV_SERVER_PREFIXES.any? { |prefix| project.start_with?(prefix) }

      # Parse Docker's timestamp format: "2026-04-11 20:15:11 +0000 UTC"
      created_at = Time.parse(created_at_str) rescue nil
      next unless created_at

      stale_projects << project if created_at < cutoff
    end

    stale_projects.to_a
  end

  # Stops a Compose project by name, removing volumes and orphans.
  # Uses `docker compose -p <name> down -v` which works without a compose file
  # because Docker tracks the project metadata.
  def stop_compose_project(project_name)
    stdout, stderr, status = run_command(
      "docker", "compose", "-p", project_name,
      "down", "-v", "--remove-orphans", "--timeout", "30"
    )

    if status.success?
      Rails.logger.info "[DockerCleanupJob] Stopped stale dev-server: #{project_name}"
    else
      Rails.logger.warn "[DockerCleanupJob] Failed to stop #{project_name}: #{stderr.to_s.truncate(200)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Standard Docker pruning
  # ---------------------------------------------------------------------------

  def prune_stopped_containers
    stdout, stderr, status = run_command("docker", "container", "prune", "-f")
    if status.success?
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Container prune: #{reclaimed}" if reclaimed.present?
    else
      Rails.logger.warn "[DockerCleanupJob] Container prune failed: #{stderr.to_s.truncate(200)}"
    end
  end

  def prune_old_images
    stdout, stderr, status = run_command(
      "docker", "image", "prune", "-a", "-f",
      "--filter", "until=#{IMAGE_AGE_FILTER}"
    )
    if status.success?
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Image prune: #{reclaimed}" if reclaimed.present?
    else
      Rails.logger.warn "[DockerCleanupJob] Image prune failed: #{stderr.to_s.truncate(200)}"
    end
  end

  def prune_dangling_volumes
    stdout, stderr, status = run_command("docker", "volume", "prune", "-f")
    if status.success?
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Volume prune: #{reclaimed}" if reclaimed.present?
    else
      Rails.logger.warn "[DockerCleanupJob] Volume prune failed: #{stderr.to_s.truncate(200)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Emergency disk cleanup
  # ---------------------------------------------------------------------------

  def emergency_cleanup
    # Aggressively prune ALL unused images (not just old ones)
    stdout, _stderr, status = run_command("docker", "image", "prune", "-a", "-f")
    if status.success?
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.warn "[DockerCleanupJob] Emergency image prune: #{reclaimed}" if reclaimed.present?
    end

    # Prune build cache
    stdout, _stderr, status = run_command("docker", "builder", "prune", "-f", "--all")
    if status.success?
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.warn "[DockerCleanupJob] Emergency builder prune: #{reclaimed}" if reclaimed.present?
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def disk_usage_percent
    stdout, _stderr, status = run_command("df", "--output=pcent", "/")
    return 0 unless status.success?

    # Output is like: "Use%\n 84%\n"
    match = stdout.match(/(\d+)%/)
    match ? match[1].to_i : 0
  end

  def log_disk_usage
    stdout, _stderr, status = run_command("df", "-h", "/")
    return unless status.success?

    usage_line = stdout.lines[1]&.strip
    Rails.logger.info "[DockerCleanupJob] Disk usage after cleanup: #{usage_line}" if usage_line.present?
  end

  FailedStatus = Struct.new(:success?)

  def run_command(*args)
    Open3.capture3(*args)
  rescue StandardError => e
    Rails.logger.error "[DockerCleanupJob] Command failed: #{args.join(' ')} — #{e.message}"
    [ "", e.message, FailedStatus.new(false) ]
  end

  def extract_reclaimed(output)
    match = output.match(/Total reclaimed space:\s*(.+)/i)
    match ? "reclaimed #{match[1].strip}" : output.lines.last&.strip
  end
end
