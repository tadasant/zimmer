# frozen_string_literal: true

require "open3"

# Periodic job to reclaim Docker disk space and clean up stale dev-server containers.
#
# Which daemon this job reaches is decided by where it runs. GoodJob executes it in the
# Kamal **worker**, and no host Docker socket is mounted into that container. Under nested
# Docker (`ZIMMER_NESTED_DOCKER=1`, see docs/operate/nested-docker.md) `docker` resolves to
# the inner daemon `bin/docker-entrypoint` starts under sysbox — the daemon agent sessions'
# `.agent-containers/` stacks actually run in. With the switch off there is no daemon at
# all, and every `docker` command here fails; that is logged, not swallowed, so a job that
# cannot see a daemon does not look like one that found nothing to do.
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
#   2. **Docker image pruning** — Images the inner daemon pulled or built for dev stacks
#      (`postgres:16`, `redis:7-alpine`, the `Dockerfile.dev` app image) outlive the stacks that
#      used them. Prunes images unused for 24+ hours. Zimmer's own ~8.8 GB deploy images live
#      in the host daemon, which this job cannot see; Kamal's `retain_containers` in
#      config/deploy.yml is what bounds those.
#
#   3. **Emergency disk handling** — When disk usage exceeds EMERGENCY_THRESHOLD, aggressively
#      prunes all unused Docker resources (images, volumes, build cache) regardless of age.
#      `df /` inside the worker reports the host filesystem's real numbers, and the inner
#      daemon's storage lives on that same disk, so the signal and the reclaim both hold.
#
# Runs every 6 hours via GoodJob cron. Safe to run at any time — only affects containers
# and images not currently in use.
#
class DockerCleanupJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

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
  #
  # A `docker ps` that fails is reported at WARN with its exit status and stderr before it
  # is treated as "nothing to reap". That line is what separates a daemon that is down, a
  # socket this uid cannot open, or an inner dockerd that never came up from a clean run
  # with no stale stacks — `[]` alone reads identically in the logs (#409).
  def find_stale_dev_server_projects
    # List all running containers with their compose project and creation time
    stdout, stderr, status = run_command(
      "docker", "ps",
      "--filter", "status=running",
      "--format", '{{.Label "com.docker.compose.project"}}\t{{.CreatedAt}}'
    )
    unless SubprocessStatus.success?(status)
      log_command_failure("Stale dev-server discovery (`docker ps`)", status, stderr)
      return []
    end

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

    if SubprocessStatus.success?(status)
      Rails.logger.info "[DockerCleanupJob] Stopped stale dev-server: #{project_name}"
    else
      log_command_failure("Failed to stop #{project_name}", status, stderr)
    end
  end

  # ---------------------------------------------------------------------------
  # Standard Docker pruning
  # ---------------------------------------------------------------------------

  def prune_stopped_containers
    stdout, stderr, status = run_command("docker", "container", "prune", "-f")
    if SubprocessStatus.success?(status)
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Container prune: #{reclaimed}" if reclaimed.present?
    else
      log_command_failure("Container prune", status, stderr)
    end
  end

  def prune_old_images
    stdout, stderr, status = run_command(
      "docker", "image", "prune", "-a", "-f",
      "--filter", "until=#{IMAGE_AGE_FILTER}"
    )
    if SubprocessStatus.success?(status)
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Image prune: #{reclaimed}" if reclaimed.present?
    else
      log_command_failure("Image prune", status, stderr)
    end
  end

  def prune_dangling_volumes
    stdout, stderr, status = run_command("docker", "volume", "prune", "-f")
    if SubprocessStatus.success?(status)
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.info "[DockerCleanupJob] Volume prune: #{reclaimed}" if reclaimed.present?
    else
      log_command_failure("Volume prune", status, stderr)
    end
  end

  # ---------------------------------------------------------------------------
  # Emergency disk cleanup
  # ---------------------------------------------------------------------------

  def emergency_cleanup
    # Aggressively prune ALL unused images (not just old ones)
    stdout, stderr, status = run_command("docker", "image", "prune", "-a", "-f")
    if SubprocessStatus.success?(status)
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.warn "[DockerCleanupJob] Emergency image prune: #{reclaimed}" if reclaimed.present?
    else
      log_command_failure("Emergency image prune", status, stderr)
    end

    # Prune build cache
    stdout, stderr, status = run_command("docker", "builder", "prune", "-f", "--all")
    if SubprocessStatus.success?(status)
      reclaimed = extract_reclaimed(stdout)
      Rails.logger.warn "[DockerCleanupJob] Emergency builder prune: #{reclaimed}" if reclaimed.present?
    else
      log_command_failure("Emergency builder prune", status, stderr)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def disk_usage_percent
    stdout, _stderr, status = run_command("df", "--output=pcent", "/")
    return 0 unless SubprocessStatus.success?(status)

    # Output is like: "Use%\n 84%\n"
    match = stdout.match(/(\d+)%/)
    match ? match[1].to_i : 0
  end

  def log_disk_usage
    stdout, _stderr, status = run_command("df", "-h", "/")
    return unless SubprocessStatus.success?(status)

    usage_line = stdout.lines[1]&.strip
    Rails.logger.info "[DockerCleanupJob] Disk usage after cleanup: #{usage_line}" if usage_line.present?
  end

  # Stands in for a Process::Status when the command never ran (ENOENT, EACCES). It answers
  # everything SubprocessStatus asks of a status so the failure can be described, not just
  # detected: no exit code and no signal, because there was no child.
  FailedStatus = Struct.new(:success?, :exitstatus, :termsig)

  def run_command(*args)
    Open3.capture3(*args)
  rescue StandardError => e
    Rails.logger.error "[DockerCleanupJob] Command failed: #{args.join(' ')} — #{e.message}"
    [ "", e.message, FailedStatus.new(false) ]
  end

  # Every failed `docker` command reports why through SubprocessStatus, so an empty stderr
  # still yields a readable line: a non-zero exit names its code, a child reaped before its
  # waiter says the exit code was never read, and a command that never ran says so.
  def log_command_failure(what, status, stderr)
    Rails.logger.warn "[DockerCleanupJob] #{what} failed: " \
      "#{SubprocessStatus.describe_failure(status, stderr.to_s.truncate(200))}"
  end

  def extract_reclaimed(output)
    match = output.match(/Total reclaimed space:\s*(.+)/i)
    match ? "reclaimed #{match[1].strip}" : output.lines.last&.strip
  end
end
