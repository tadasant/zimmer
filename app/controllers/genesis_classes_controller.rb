# frozen_string_literal: true

# One-click promotion (and demotion) of a whole genesis kind.
#
# The unit here is the GENESIS, not the session. Clicking "Make priority" on
# `github_issue` reclassifies every session that came from a GitHub issue trigger
# — past, present and future — because Session#priority_class derives from the
# stored genesis on every read rather than being denormalized at creation. That
# is the point: the operator's lever is the policy, not a backlog of rows.
#
# Kept separate from AppSettingsController because this is a one-button action
# with its own route, not a form of many fields — and because a promotion should
# never be able to ride along with an unrelated settings submit.
class GenesisClassesController < ApplicationController
  def update
    setting = AppSetting.editable
    genesis = params[:genesis].to_s
    klass = params[:priority_class].to_s

    unless SessionGenesis.valid?(genesis)
      return redirect_to settings_path(anchor: "spot-gate"), alert: "Unknown genesis: #{genesis}"
    end
    unless SessionGenesis::CLASSES.include?(klass)
      return redirect_to settings_path(anchor: "spot-gate"), alert: "Unknown class: #{klass}"
    end

    setting.set_genesis_class(genesis, klass)

    if setting.save
      affected = Session.genesis_count_for(genesis)
      redirect_to settings_path(anchor: "spot-gate"),
        notice: "#{SessionGenesis.label(genesis)} is now #{klass}. " \
                "#{affected} live #{'session'.pluralize(affected)} reclassified."
    else
      redirect_to settings_path(anchor: "spot-gate"),
        alert: "Could not update: #{setting.errors.full_messages.join(', ')}"
    end
  end

  # Return every genesis to its shipped default.
  def destroy
    setting = AppSetting.editable
    setting.reset_genesis_classes

    if setting.save
      redirect_to settings_path(anchor: "spot-gate"), notice: "Genesis classes reset to defaults."
    else
      redirect_to settings_path(anchor: "spot-gate"),
        alert: "Could not reset: #{setting.errors.full_messages.join(', ')}"
    end
  end
end
