# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Which delivered label events fire a `github_label` condition, and how long the claim a fire takes
# lives. Every matching rule here is GithubTriggerPollerJob#process_label_condition's rule; the
# comments in GithubEventJob#label_matches name the part of the poller each one mirrors.
#
# The fixture is the merge gate's shape: one trigger, pull requests in one repo, one watched label
# ("ready to merge"), already baselined with nothing labelled.
class GithubLabelEventJobTest < ActiveJob::TestCase
  include GithubWebhookTestHelpers
  include UntrustedFenceAssertions

  setup { setup_github_label_webhook }
  teardown { teardown_github_webhook }

  # One delivery, run the way Webhooks::GithubController runs it.
  def deliver_label(object, event: "pull_request.labeled", label: LABEL, repository: { "full_name" => REPO })
    GithubEventJob.perform_now(
      "delivery-#{SecureRandom.hex(4)}", event,
      GithubEventJob.item_arguments(object, repository: repository, pull_request: event.start_with?("pull_request.")),
      label
    )
  end

  def fires(object, **options)
    before = Session.count
    deliver_label(object, **options)
    Session.count - before
  end

  # --- what fires ---------------------------------------------------------------------

  test "a label added to an open pull request fires, and claims the item and the label" do
    assert_equal 1, fires(github_pull_request(number: 10))

    claim = TriggerEventClaim.sole
    assert_equal [ @condition.id, "github:tadasant/zimmer#10:label:ready to merge", "webhook", Session.order(:id).last.id ],
      [ claim.trigger_condition_id, claim.event_key, claim.claimed_via, claim.session_id ]
  end

  test "the session reads exactly as the poller's does, down to the event line" do
    deliver_label(github_pull_request(number: 11, title: "Fix the thing"))

    prompt = Session.order(:id).last.prompt
    assert_includes prompt, "tadasant/zimmer#11 was labelled (label added: ready to merge)."
    assert_includes prompt, "Link: https://github.com/tadasant/zimmer/pull/11"
  end

  test "a pull request opened already carrying the label fires, and so does a reopened one" do
    assert_equal 1, fires(github_pull_request(number: 12, labels: [ LABEL, "bug" ]), event: "pull_request.opened", label: nil)
    assert_equal 1, fires(github_pull_request(number: 13, labels: [ LABEL ]), event: "pull_request.reopened", label: nil)

    assert_equal [ "github:tadasant/zimmer#12:label:ready to merge", "github:tadasant/zimmer#13:label:ready to merge" ],
      TriggerEventClaim.order(:event_key).pluck(:event_key)
  end

  test "the label matches whatever case GitHub spells it in, and keys on the configured casing" do
    assert_equal 1, fires(github_pull_request(number: 14), label: "Ready To Merge")

    assert_equal "github:tadasant/zimmer#14:label:ready to merge", TriggerEventClaim.sole.event_key
  end

  test "a repo spelled in another case is still the watched repo" do
    assert_equal 1, fires(github_pull_request(number: 15, repo: "TadasAnt/Zimmer"), repository: { "full_name" => "TadasAnt/Zimmer" })
  end

  test "hostile title, labels and body reach the session fenced and verbatim" do
    @trigger.update_columns(prompt_template: "Rate this PR.")
    deliver_label(github_pull_request(number: 16, title: HOSTILE_EVENT_LINE, body: HOSTILE_EVENT_TEXT, labels: [ LABEL ]))

    prompt = Session.order(:id).last.prompt
    assert_includes prompt, "## GitHub pull request (label added: ready to merge)"
    assert_fenced_verbatim(prompt, "title", HOSTILE_EVENT_LINE)
    assert_fenced_verbatim(prompt, "body", HOSTILE_EVENT_TEXT)
    assert_operator prompt.index("- **URL:**"), :<, prompt.index("[begin untrusted")
  end

  # --- what does not ------------------------------------------------------------------

  test "a label the condition does not watch fires nothing" do
    assert_equal 0, fires(github_pull_request(number: 20), label: "bug")
  end

  test "a label added to a CLOSED pull request fires nothing, because `is:open` would not return it" do
    assert_equal 0, fires(github_pull_request(number: 21, state: "closed"))
  end

  test "a pull request in a repo the condition does not watch fires nothing" do
    assert_equal 0, fires(github_pull_request(number: 22, repo: "someone/else"), repository: { "full_name" => "someone/else" })
  end

  test "an ISSUE labelled fires nothing for a condition that watches pull requests" do
    assert_equal 0, fires(github_issue(number: 23), event: "issues.labeled")
  end

  test "a pull request labelled fires nothing for a condition that watches issues" do
    configure_condition(@condition.configuration.merge("target" => "issue"))

    assert_equal 0, fires(github_pull_request(number: 24))
    assert_equal 1, fires(github_issue(number: 24), event: "issues.labeled")
  end

  test "a condition the poller has not baselined yet fires nothing; its first tick owns that" do
    configure_condition(@condition.configuration.except("seen_items"))

    assert_equal 0, fires(github_pull_request(number: 25))
  end

  test "a condition whose target flipped fires nothing until the poller re-baselines it" do
    configure_condition(@condition.configuration.merge(
      "baseline_scope" => { "repos" => [ REPO ], "target" => "issue", "labels" => [ LABEL ] }
    ))

    assert_equal 0, fires(github_pull_request(number: 26))
  end

  test "a label in a repo the baseline does not cover is absorbed, not fired" do
    # The repo was added to a live condition; its already-labelled items are state, not events.
    configure_condition(@condition.configuration.merge(
      "repos" => [ REPO, "tadasant/strad" ],
      "baseline_scope" => { "repos" => [ REPO ], "target" => "pull_request", "labels" => [ LABEL ] }
    ))

    assert_equal 0, fires(github_pull_request(number: 27, repo: "tadasant/strad"), repository: { "full_name" => "tadasant/strad" })
    assert_equal 1, fires(github_pull_request(number: 28))
  end

  test "an item the poller already has in its seen-set fires nothing" do
    configure_condition(@condition.configuration.merge("seen_items" => [ "tadasant/zimmer#29:ready to merge" ]))

    assert_equal 0, fires(github_pull_request(number: 29))
  end

  test "a condition on a disabled trigger fires nothing" do
    @trigger.update_columns(status: "disabled")

    assert_equal 0, fires(github_pull_request(number: 30))
  end

  test "a job that runs after GitHub was switched back to poll fires nothing" do
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = "poll"

    assert_equal 0, fires(github_pull_request(number: 31))
    assert_equal 0, TriggerEventClaim.count
  end

  test "a delivery never moves the poller's seen-set" do
    deliver_label(github_pull_request(number: 32))

    assert_empty @condition.reload.github_seen_items
  end

  # --- the claim's lifetime -------------------------------------------------------------
  #
  # The reason this slice is its own PR. A `github_issue` claim covers an event that cannot recur,
  # so a fixed retention is right for it. A label event CAN recur, and the poller's seen-set is the
  # only thing that knows when it has.

  test "the webhook's claim survives the poller's next tick, so the item fires exactly once" do
    pull_request = github_pull_request(number: 40, labels: [ LABEL ])

    assert_difference -> { Session.count }, 1 do
      deliver_label(pull_request)
      poll_label_items([ searched_pull_request(pull_request) ])
    end

    assert_equal "webhook", TriggerEventClaim.sole.claimed_via
    # The poller lost the claim and recorded the item anyway, so its seen-set is unchanged by the
    # existence of the webhook.
    assert_equal [ "tadasant/zimmer#40:ready to merge" ], @condition.reload.github_seen_items
  end

  test "the poller's claim blocks a delivery that arrives after it" do
    pull_request = github_pull_request(number: 41, labels: [ LABEL ])

    assert_difference -> { Session.count }, 1 do
      poll_label_items([ searched_pull_request(pull_request) ])
      deliver_label(pull_request)
    end

    assert_equal "poll", TriggerEventClaim.sole.claimed_via
  end

  # THE behaviour the claim lifetime exists to preserve. A claim that outlived the seen-set would
  # swallow this silently.
  test "removing a label for the full grace window and re-adding it fires a second time" do
    pull_request = github_pull_request(number: 42, labels: [ LABEL ])
    searched = searched_pull_request(pull_request)
    unlabelled = searched_pull_request(github_pull_request(number: 42))

    assert_difference(-> { Session.count }, 1) { deliver_label(pull_request) }
    poll_label_items([ searched ])
    assert_equal [ "tadasant/zimmer#42:ready to merge" ], @condition.reload.github_seen_items

    # The label comes off. Inside the grace window the poller still holds the key, so a re-add is
    # not an event for either path — the webhook mirrors the poller here rather than second-guessing
    # it, exactly as it does everywhere else.
    (GithubTriggerPollerJob::REMOVAL_GRACE_TICKS - 1).times do
      poll_label_items([])
      assert_equal 1, TriggerEventClaim.count, "the claim must live as long as the key does"
      assert_equal 0, fires(pull_request), "inside the grace window the poller would not fire either"
    end

    # The tick that accepts the removal drops the key AND releases the claim with it.
    poll_label_items([ unlabelled ])
    assert_empty @condition.reload.github_seen_items
    assert_equal 0, TriggerEventClaim.count

    # Re-added: a second, legitimate "the label was added".
    assert_equal 1, fires(pull_request)
    assert_equal 2, Session.for_trigger(@trigger.id).count
    assert_equal "github:tadasant/zimmer#42:label:ready to merge", TriggerEventClaim.sole.event_key
  end

  test "the poller's own re-add fires a second time too, with the claim released in between" do
    pull_request = searched_pull_request(github_pull_request(number: 43, labels: [ LABEL ]))

    assert_difference(-> { Session.count }, 1) { poll_label_items([ pull_request ]) }
    GithubTriggerPollerJob::REMOVAL_GRACE_TICKS.times { poll_label_items([]) }
    assert_equal 0, TriggerEventClaim.count

    assert_difference(-> { Session.count }, 1) { poll_label_items([ pull_request ]) }
    assert_equal 1, TriggerEventClaim.count
  end

  test "a key still inside the grace window keeps its claim, so a blip cannot re-fire it" do
    pull_request = searched_pull_request(github_pull_request(number: 44, labels: [ LABEL ]))

    poll_label_items([ pull_request ])
    poll_label_items([])

    assert_equal 1, TriggerEventClaim.count
    assert_equal [ "tadasant/zimmer#44:ready to merge" ], @condition.reload.github_seen_items
  end

  # The release must never reach a claim the webhook has just taken for an item this poller has not
  # recorded yet: deleting it would hand the next tick an item that already has a session, which is
  # #704's double spawn on the merge gate.
  test "a tick that drops one key leaves a fresh claim the webhook took for another item alone" do
    old = github_pull_request(number: 45, labels: [ LABEL ])
    fresh = github_pull_request(number: 46, labels: [ LABEL ])

    poll_label_items([ searched_pull_request(old) ])
    GithubTriggerPollerJob::REMOVAL_GRACE_TICKS.times { poll_label_items([]) }

    # The webhook fires #46 while a tick whose search predates the label is still in flight.
    deliver_label(fresh)
    poll_label_items([])

    assert_equal [ "github:tadasant/zimmer#46:label:ready to merge" ], TriggerEventClaim.pluck(:event_key)
    assert_difference -> { Session.count }, 0 do
      poll_label_items([ searched_pull_request(fresh) ])
    end
  end

  test "a re-baseline releases the claims on the keys it does not carry forward" do
    poll_label_items([ searched_pull_request(github_pull_request(number: 47, labels: [ LABEL ])) ])
    assert_equal 1, TriggerEventClaim.count

    # A target flip: the keys no longer denote the same items, so everything is re-baselined.
    configure_condition(@condition.configuration.merge(
      "baseline_scope" => { "repos" => [ REPO ], "target" => "issue", "labels" => [ LABEL ] }
    ))
    poll_label_items([])

    assert_equal 0, TriggerEventClaim.count
  end

  test "a label claim for one condition does not block another condition watching the same label" do
    second = @trigger.trigger_conditions.create!(
      condition_type: "github_label",
      configuration: { "repos" => [ REPO ], "target" => "pull_request", "labels" => [ LABEL ], "seen_items" => [] }
    )

    assert_equal 2, fires(github_pull_request(number: 48))
    assert_equal [ @condition.id, second.id ].sort, TriggerEventClaim.pluck(:trigger_condition_id).sort
  end

  # --- claims the poller never recorded a key for ------------------------------------------
  #
  # #release_label_claims can only drop a claim whose key the seen-set HELD. The merge gate's own
  # shape produces claims it never held: label added, gate declines, label removed, all inside the
  # up-to-60-second gap before the poller's next tick. #release_orphaned_label_claims is what stops
  # those swallowing the next add of the same label.

  test "the gate's own shape — labelled, fired, unlabelled before the first tick — does not swallow the next add" do
    pull_request = github_pull_request(number: 70, labels: [ LABEL ])

    assert_equal 1, fires(pull_request)
    assert_equal 1, TriggerEventClaim.count

    # The label came off before the poller ever saw it, so the key never enters the seen-set and
    # nothing in the ordinary release path can ever reach the claim.
    poll_label_items([])
    assert_empty @condition.reload.github_seen_items
    assert_equal 1, TriggerEventClaim.count, "a claim younger than the index lag must not be swept"

    # Past the index lag, a tick that still does not see the item carrying the label ends the event.
    TriggerEventClaim.update_all(created_at: (GithubTriggerPollerJob::INDEX_LAG_GRACE + 1.minute).ago)
    poll_label_items([])
    assert_equal 0, TriggerEventClaim.count

    assert_equal 1, fires(pull_request)
    assert_equal 2, Session.for_trigger(@trigger.id).count
  end

  test "an orphaned claim is NOT swept while the item is still carrying the label" do
    pull_request = github_pull_request(number: 71, labels: [ LABEL ])
    deliver_label(pull_request)
    TriggerEventClaim.update_all(created_at: (GithubTriggerPollerJob::INDEX_LAG_GRACE + 1.minute).ago)

    # The search returns it, so the poller meets the claim, records the key, and keeps the claim.
    assert_no_difference -> { Session.count } do
      poll_label_items([ searched_pull_request(pull_request) ])
    end

    assert_equal 1, TriggerEventClaim.count
    assert_equal [ "tadasant/zimmer#71:ready to merge" ], @condition.reload.github_seen_items
  end

  test "a claim younger than the index lag survives a tick whose search has not indexed the label yet" do
    pull_request = github_pull_request(number: 72, labels: [ LABEL ])
    deliver_label(pull_request)

    # GitHub has not indexed the new label; the poller's search comes back empty.
    poll_label_items([])
    assert_equal 1, TriggerEventClaim.count

    # It appears on the next tick. Because the claim survived, the poller does not spawn a second
    # session for the label the webhook already handled — this is the #704 direction.
    assert_no_difference -> { Session.count } do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
    assert_equal [ "tadasant/zimmer#72:ready to merge" ], @condition.reload.github_seen_items
  end

  test "the sweep leaves another condition's claims alone" do
    other = @trigger.trigger_conditions.create!(
      condition_type: "github_label",
      configuration: { "repos" => [ REPO ], "target" => "pull_request", "labels" => [ LABEL ], "seen_items" => [] }
    )
    TriggerEventClaim.claim!(other, [ TriggerEventClaim.github_label_event_key(REPO, 73, LABEL) ], via: "webhook")
    TriggerEventClaim.update_all(created_at: (GithubTriggerPollerJob::INDEX_LAG_GRACE + 1.minute).ago)

    poll_label_items([])

    assert_equal [ other.id ], TriggerEventClaim.pluck(:trigger_condition_id)
  end

  test "the sweep leaves a github_issue claim alone, whatever its age" do
    issue_condition = trigger_conditions(:github_issue_condition)
    TriggerEventClaim.claim!(issue_condition, [ TriggerEventClaim.github_issue_event_key(REPO, 74) ], via: "webhook")
    TriggerEventClaim.update_all(created_at: 60.days.ago)

    poll_label_items([])

    assert_equal [ "github:tadasant/zimmer#74:opened" ], TriggerEventClaim.pluck(:event_key)
  end

  # --- mirroring the search's own normalisation --------------------------------------------

  # GithubSearchService.label_group drops an embedded double quote, because GitHub has no escape
  # for one — so the poller's query asks for a name the condition did not configure, and the
  # webhook has to ask for that same name or it fires for items the poller can never see. A claim
  # taken on such a fire would be orphaned with no self-heal.
  test "a watched label containing a double quote is matched the way the search asks for it" do
    configure_condition(@condition.configuration.merge("labels" => [ 'ready "to" merge' ]))

    assert_equal 0, fires(github_pull_request(number: 75), label: 'ready "to" merge')
    assert_equal 0, TriggerEventClaim.count

    # `label:"ready to merge"` is what the query actually contains, so that is what fires — and the
    # key carries the CONFIGURED spelling, which is what the poller's seen-set would hold.
    assert_equal 1, fires(github_pull_request(number: 76), label: "ready to merge")
    assert_equal 'github:tadasant/zimmer#76:label:ready "to" merge', TriggerEventClaim.sole.event_key
  end

  test "a seen key is matched case-insensitively on the repository, like every clause around it" do
    configure_condition(@condition.configuration.merge("seen_items" => [ "TadasAnt/Zimmer#77:ready to merge" ]))

    assert_equal 0, fires(github_pull_request(number: 77))
  end

  # --- argument shapes ---------------------------------------------------------------------

  test "a job carrying arguments this release does not read fires nothing rather than raising" do
    assert_nothing_raised do
      assert_no_difference [ -> { Session.count }, -> { TriggerEventClaim.count } ] do
        GithubEventJob.perform_now("stale-delivery", GithubEventJob.item_arguments(github_pull_request(number: 78)))
      end
    end
  end

  test "the controller's firing events and the job's label events do not drift apart" do
    assert_equal (GithubEventJob::LABEL_EVENTS | [ GithubEventJob::ISSUE_OPENED ]).sort,
      Webhooks::GithubController::FIRING_EVENTS.keys.sort
  end

  # --- spawning nothing, and failing ------------------------------------------------------

  test "a delivery that spawns nothing releases its claim, so the poller fires the label later" do
    pull_request = github_pull_request(number: 50, labels: [ LABEL ])
    Trigger.any_instance.stubs(:create_session!).returns(nil)

    assert_equal 0, fires(pull_request)
    assert_equal 0, TriggerEventClaim.count

    Trigger.any_instance.unstub(:create_session!)
    assert_difference -> { Session.count }, 1 do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
    assert_equal "poll", TriggerEventClaim.sole.claimed_via
  end

  test "a fire that raises rolls its claim back, so the poller can still fire the label" do
    pull_request = github_pull_request(number: 51, labels: [ LABEL ])
    Trigger.any_instance.stubs(:create_session!).raises(StandardError, "spawn exploded")

    assert_equal 0, fires(pull_request)
    assert_equal 0, TriggerEventClaim.count

    Trigger.any_instance.unstub(:create_session!)
    assert_difference -> { Session.count }, 1 do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
  end

  test "a raise after the session row is written rolls the session back with its claim" do
    pull_request = github_pull_request(number: 52, labels: [ LABEL ])
    AgentSessionJob.stubs(:enqueue_new_session).raises(StandardError, "enqueue exploded")

    assert_no_difference [ -> { Session.count }, -> { TriggerEventClaim.count } ] do
      deliver_label(pull_request)
    end

    AgentSessionJob.stubs(:enqueue_new_session)
    assert_difference -> { Session.count }, 1 do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
  end

  # #704 on the claimed path. A raise from an `after_commit` callback arrives once the session AND
  # its claim have committed, so the only honest answer is the database's: the label event is spent,
  # and the claim — not a rescue, and not the poller's seen-set write — is what makes it stay spent.
  test "a raise after the transaction commits reports the label as fired, because its session is live" do
    pull_request = github_pull_request(number: 53, labels: [ LABEL ])

    with_session_after_commit_raise do
      assert_difference [ -> { Session.count }, -> { TriggerEventClaim.count } ], 1 do
        deliver_label(pull_request)
      end
    end

    claim = TriggerEventClaim.sole
    assert_equal "github:tadasant/zimmer#53:label:ready to merge", claim.event_key
    assert_equal Session.order(:id).last.id, claim.session_id

    # The poller finds the item a minute later and does NOT spawn a second gate session — not
    # because a rescue guessed right, but because the claim is there.
    assert_no_difference -> { Session.count } do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
    assert_equal [ "tadasant/zimmer#53:ready to merge" ], @condition.reload.github_seen_items
  end

  # The same raise with the seen-set write lost as well: the claim alone still holds the line,
  # which is what makes it strictly stronger than #704's rescue.
  test "a committed claim stops the second spawn even when the poller never records the key" do
    pull_request = github_pull_request(number: 54, labels: [ LABEL ])
    deliver_label(pull_request)

    # Neither of the poller's state writes lands — the durability floor and the terminal write
    # both gone, which is the failure #record_fired_key exists for taken to its limit. The raise
    # out of the terminal write is what GithubTriggerPollerJob#perform's per-condition rescue
    # swallows in production; #process_condition itself lets it through.
    TriggerCondition.any_instance.stubs(:write_github_state!).raises(StandardError, "write lost")
    assert_no_difference -> { Session.count } do
      assert_raises(StandardError) { poll_label_items([ searched_pull_request(pull_request) ]) }
    end
    TriggerCondition.any_instance.unstub(:write_github_state!)

    assert_empty @condition.reload.github_seen_items
    assert_no_difference -> { Session.count } do
      poll_label_items([ searched_pull_request(pull_request) ])
    end
  end

  private

  # Make the next `after_commit` on a Session raise, the one way a fire can fail with its session
  # and its claim already committed.
  def with_session_after_commit_raise
    original = Session._commit_callbacks
    Session.set_callback(:commit, :after) { raise StandardError, "after_commit exploded" }
    yield
  ensure
    Session._commit_callbacks = original
  end
end
