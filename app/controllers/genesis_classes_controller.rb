# frozen_string_literal: true

# One-click promotion (and demotion) of a whole genesis kind — for the kinds
# nothing triggers.
#
# The unit here is the GENESIS, not the session. Clicking "Make spot" on `web_ui`
# reclassifies every session a human started in the web app — past, present and
# future — because Session#priority_class derives from the stored genesis on
# every read whenever the session names no class of its own. That is the point:
# the operator's lever is the policy, not a backlog of rows.
#
# The five trigger-backed kinds are rejected here rather than offered. Their
# selector lives on the Trigger, so that one Slack trigger can be spot without
# moving every other session that shares the genesis — the case this route used
# to force. SessionGenesis ignores an override for them on read, so accepting one
# would be a click that appears to work and changes nothing.
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
    unless SessionGenesis.settable?(genesis)
      return redirect_to settings_path(anchor: "spot-gate"),
        alert: "#{SessionGenesis.label(genesis)} takes its class from the trigger that fires it. " \
               "Set it on the trigger instead."
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
