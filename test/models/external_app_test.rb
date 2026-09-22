# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ExternalAppTest < ActiveSupport::TestCase
  include ExternalAppTestHelpers

  setup do
    @trigger = triggers(:enabled_slack_trigger)
  end

  test "names are required, unique case-insensitively, and free of control characters" do
    ExternalApp.create!(name: "Housing search")

    assert_not ExternalApp.new(name: "").valid?
    assert_not ExternalApp.new(name: "housing SEARCH").valid?
    assert_not ExternalApp.new(name: "evil\nname").valid?
  end

  test "replace_triggers! sets the allowlist exactly, and refuses unknown or workflow triggers without touching it" do
    app = ExternalApp.create!(name: "Housing search")
    other = triggers(:disabled_slack_trigger)

    app.replace_triggers!([ @trigger.id, other.id.to_s ])
    assert_equal [ @trigger.id, other.id ].sort, app.reload.trigger_ids.sort

    error = assert_raises(ExternalApp::InvalidAllowlist) { app.replace_triggers!([ @trigger.id, 999_999_999 ]) }
    assert_includes error.message, "999999999"
    assert_raises(ExternalApp::InvalidAllowlist) { app.replace_triggers!([ "1; drop table" ]) }
    assert_equal [ @trigger.id, other.id ].sort, app.reload.trigger_ids.sort

    Trigger.any_instance.stubs(:workflow_backed?).returns(true)
    assert_raises(ExternalApp::InvalidAllowlist) { app.replace_triggers!([ @trigger.id ]) }
  end

  test "replace_triggers! with an empty list empties the allowlist" do
    app, = create_plugin_with_key(triggers: [ @trigger ])
    app.replace_triggers!([])
    assert_empty app.reload.triggers
  end

  test "mint_key! creates an external_app key that belongs to the app, and a second mint does not collide" do
    app = ExternalApp.create!(name: "Housing search")

    key, token = app.mint_key!
    key2, token2 = app.mint_key!

    assert_equal ApiKey::EXTERNAL_APP_GRANT, key.effective_grant
    assert_equal app, key.external_app
    assert_predicate key, :external_app?
    assert_not_equal key.name, key2.name
    assert_not_equal token, token2
    assert token.start_with?(ApiKey::MINTED_PREFIX)
    assert_equal ApiKey.digest(token), key.token_digest
  end

  test "mint_key! keeps working for a 100-character name, however often it is called" do
    app = ExternalApp.create!(name: "h" * 100)
    keys = 3.times.map { app.mint_key!.first }

    assert_equal 3, keys.map(&:name).uniq.size
    assert(keys.all? { |key| key.name.length <= 100 })
  end

  test "an external_app key needs an app, and no other key may have one" do
    app = ExternalApp.create!(name: "Housing search")

    orphan = ApiKey.new(name: "orphan", source: ApiKey::MINTED_SOURCE, token_digest: ApiKey.digest("a"), grant: ApiKey::EXTERNAL_APP_GRANT)
    assert_not orphan.valid?
    assert_includes orphan.errors[:external_app].join, "must be set"

    widened = ApiKey.new(name: "widened", source: ApiKey::MINTED_SOURCE, token_digest: ApiKey.digest("b"), grant: ApiKey::API_GRANT, external_app: app)
    assert_not widened.valid?
    assert_includes widened.errors[:external_app].join, "can only be set"
  end

  test "the database refuses an external_app key without an app, and an app on any other key" do
    app = ExternalApp.create!(name: "Housing search")
    key, = app.mint_key!

    # Each in a savepoint, so the first violation does not abort the test's
    # transaction and make the second pass for the wrong reason.
    assert_raises(ActiveRecord::CheckViolation) do
      ApiKey.transaction(requires_new: true) { key.update_columns(grant: ApiKey::API_GRANT) }
    end
    assert_raises(ActiveRecord::CheckViolation) do
      ApiKey.transaction(requires_new: true) { ApiKey.where(id: key.id).update_all(external_app_id: nil) }
    end
    assert_equal app.id, key.reload.external_app_id
  end

  test "the API keys form cannot mint a plugin key: it has no app to give it" do
    assert_raises(ActiveRecord::RecordInvalid) { ApiKey.mint!(name: "sneaky", grant: ApiKey::EXTERNAL_APP_GRANT) }
    assert_not_includes ApiKey::FORM_GRANTS, ApiKey::EXTERNAL_APP_GRANT
  end

  test "deleting the app deletes its keys and its allowlist, and deleting a trigger takes it off the allowlist" do
    app, token = create_plugin_with_key(triggers: [ @trigger, triggers(:disabled_slack_trigger) ])

    triggers(:disabled_slack_trigger).destroy!
    assert_equal [ @trigger.id ], app.reload.trigger_ids

    app.destroy!
    assert_nil ApiKey.find_by(token_digest: ApiKey.digest(token))
    assert_equal 0, ExternalAppTrigger.where(external_app_id: app.id).count
  end

  test "record_invocation! writes at most once per resolution" do
    app = ExternalApp.create!(name: "Housing search")
    now = Time.current

    app.record_invocation!(now: now)
    assert_in_delta now, app.reload.last_invoked_at, 1

    app.record_invocation!(now: now + 10.seconds)
    assert_in_delta now, app.reload.last_invoked_at, 1

    app.record_invocation!(now: now + 2.minutes)
    assert_in_delta now + 2.minutes, app.reload.last_invoked_at, 1
  end
end
