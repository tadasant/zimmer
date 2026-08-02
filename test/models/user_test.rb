# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  teardown do
    ENV.delete(User::ADMIN_ENV_KEY)
  end

  test "the roster ships with the two humans this deployment knows about" do
    assert_equal %w[tadasant juliehazz], User::SEEDED.map { |attrs| attrs[:key] }
    assert_equal %w[Tadas Julie], User::SEEDED.map { |attrs| attrs[:display_name] }
    assert_equal %w[tadas@tadasant.com julie@tadasant.com], User::SEEDED.map { |attrs| attrs[:email] }
    assert User::SEEDED.all? { |attrs| attrs[:notes].present? }
    # Slack IDs are deployment configuration and this repository is public.
    assert User::SEEDED.none? { |attrs| attrs.key?(:slack_user_ids) }
  end

  test "the seeded rows are creatable as written" do
    User.delete_all

    User::SEEDED.each { |attrs| User.create!(**attrs) }

    assert_equal %w[juliehazz tadasant], User.alphabetical.pluck(:key)
    assert_equal "tadas@tadasant.com", User.for_key("tadasant").email
  end

  test "for_key finds a human, and nobody for an unknown or blank key" do
    assert_equal "Tadas", User.for_key("tadasant").display_name
    assert_nil User.for_key("zimmer-router")
    assert_nil User.for_key(nil)
    assert_nil User.for_key("")
  end

  # ==========================================================================
  # The admin — who is responsible for web UI actions
  # ==========================================================================

  test "the admin is Tadas when the deployment configures nothing" do
    assert_nil ENV[User::ADMIN_ENV_KEY]

    assert_equal "tadasant", User.admin.key
  end

  test "the admin env var names who it says" do
    ENV[User::ADMIN_ENV_KEY] = "juliehazz"

    assert_equal "juliehazz", User.admin.key
  end

  test "the admin env var tolerates surrounding whitespace" do
    ENV[User::ADMIN_ENV_KEY] = "  juliehazz  "

    assert_equal "juliehazz", User.admin.key
  end

  # Nobody is a safer answer than somebody: web-UI capture records nothing
  # rather than attributing a message to a human who does not exist.
  test "an admin env var naming nobody resolves to nobody" do
    ENV[User::ADMIN_ENV_KEY] = "some-agent"

    assert_nil User.admin
  end

  test "the default admin resolves to nobody when that row is gone" do
    users(:tadasant).destroy!

    assert_nil User.admin
  end

  test "admin? answers for the configured key" do
    ENV[User::ADMIN_ENV_KEY] = "juliehazz"

    assert users(:juliehazz).admin?
    refute users(:tadasant).admin?
  end

  # ==========================================================================
  # Slack linkage
  # ==========================================================================

  test "no Slack user IDs are checked into the repository" do
    assert User.all.all? { |user| user.slack_user_ids.empty? }, "seeded rows must ship without Slack IDs"
    assert_nil User.for_slack_user_id("U01ANYTHING")
  end

  test "resolves a Slack user ID linked on the row" do
    users(:tadasant).update!(slack_user_ids: %w[U01TADAS U01TADAS_ALT])
    users(:juliehazz).update!(slack_user_ids: %w[U07JULIE])

    assert_equal "tadasant", User.for_slack_user_id("U01TADAS").key
    assert_equal "tadasant", User.for_slack_user_id("U01TADAS_ALT").key
    assert_equal "juliehazz", User.for_slack_user_id("U07JULIE").key
  end

  # An unmapped Slack account may be another workspace member, a bot, or an app
  # posting with a bot token. nil is the correct answer.
  test "an unmapped Slack user ID resolves to nobody" do
    users(:tadasant).update!(slack_user_ids: %w[U01TADAS])

    assert_nil User.for_slack_user_id("U99STRANGER")
    assert_nil User.for_slack_user_id(nil)
    assert_nil User.for_slack_user_id("")
  end

  test "Slack IDs are normalized and deduplicated" do
    users(:tadasant).update!(slack_user_ids: [ " U01TADAS ", "", "U01TADAS" ])

    assert_equal %w[U01TADAS], users(:tadasant).reload.slack_user_ids
  end

  # Two humans holding one Slack ID would make the author of a message depend on
  # row order.
  test "a Slack ID cannot belong to two humans" do
    users(:tadasant).update!(slack_user_ids: %w[U01TADAS])
    julie = users(:juliehazz)
    julie.slack_user_ids = %w[U01TADAS]

    refute julie.valid?
    assert_includes julie.errors[:slack_user_ids], "already belong to tadasant"
  end

  test "the comma-separated form field round-trips the array" do
    user = users(:tadasant)
    user.slack_user_ids_list = "U01TADAS, U01TADAS_ALT"
    user.save!

    assert_equal %w[U01TADAS U01TADAS_ALT], user.reload.slack_user_ids
    assert_equal "U01TADAS, U01TADAS_ALT", user.slack_user_ids_list
  end

  # ==========================================================================
  # Columns
  # ==========================================================================

  test "email is linked, normalized, and unique across humans" do
    assert_equal "tadas@tadasant.com", users(:tadasant).email
    assert_equal "julie@tadasant.com", users(:juliehazz).email

    users(:tadasant).update!(email: "  Tadas@Tadasant.com ")
    assert_equal "tadas@tadasant.com", users(:tadasant).reload.email

    julie = users(:juliehazz)
    julie.email = "TADAS@tadasant.com"
    refute julie.valid?
  end

  test "for_email finds a human case-insensitively" do
    assert_equal "tadasant", User.for_email("TADAS@tadasant.com").key
    assert_nil User.for_email("stranger@example.com")
    assert_nil User.for_email(nil)
  end

  test "email must look like an address, but may be absent" do
    user = users(:juliehazz)

    user.email = "not-an-address"
    refute user.valid?

    user.email = nil
    assert user.valid?
  end

  test "notes carry free-form context for policy decisions" do
    users(:juliehazz).update!(notes: "Tadas is master")

    assert_equal "Tadas is master", users(:juliehazz).reload.notes
    assert_nil User.new(key: "x", display_name: "X").notes
  end

  test "key is required, unique, and a stable slug" do
    refute User.new(display_name: "Nobody").valid?
    refute User.new(key: "tadasant", display_name: "Impostor").valid?
    refute User.new(key: "Tadas Ant", display_name: "Spaces").valid?
    assert User.new(key: "new.human_1-x", display_name: "New").valid?
  end

  test "display_name is required" do
    refute User.new(key: "nameless").valid?
  end
end
