# frozen_string_literal: true

# Feature flag (default OFF) selecting the PTY-driven Claude print-mode runner
# for headless inference instead of the native `claude -p` invocation. The PTY
# technique drives the interactive Claude TUI inside a pseudo-terminal and is
# inherently fragile (it depends on Claude Code's TUI/Ink internals), so the
# native path stays the default.
class AddPtyHeadlessInferenceToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :pty_headless_inference, :boolean, null: false, default: false
  end
end
