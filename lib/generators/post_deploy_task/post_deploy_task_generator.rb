# frozen_string_literal: true

require "rails/generators"

# `bin/rails generate post_deploy_task prune_orphaned_widgets`
#
# Writes a timestamped file in `db/post_deploy/`. The timestamp is the identity
# of the task in the ledger, so it has to be right — which is the whole reason
# this generator exists rather than a line of documentation telling you to type
# fourteen digits by hand. Same reason `rails g migration` exists.
class PostDeployTaskGenerator < Rails::Generators::NamedBase
  source_root File.expand_path("templates", __dir__)

  desc "Create a one-time post-deploy task in db/post_deploy/ (see PostDeployTask)"

  def create_task_file
    template "task.rb.tt", File.join("db/post_deploy", "#{timestamp}_#{file_name}.rb")
  end

  private

  # Matches the migration convention exactly, so the two directories sort and
  # read the same way.
  def timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")

  def task_class_name = file_name.camelize
end
