# frozen_string_literal: true

require "test_helper"

# The boundary tadasant/zimmer#617 is about: exactly one mechanism may wake a
# given auth-outage-parked session, and this is where that is decided.
class AuthOutageWakeAuthorityTest < ActiveSupport::TestCase
  def session(scheduling_class)
    Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :waiting,
      scheduling_class: scheduling_class,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid
    )
  end

  test "a priority park belongs to Zimmer's own sweep" do
    parked = session(SessionGenesis::PRIORITY)

    assert_equal AuthOutageWakeAuthority::SWEEP, AuthOutageWakeAuthority.for(parked)
    assert AuthOutageWakeAuthority.sweep_owned?(parked)
    assert_not AuthOutageWakeAuthority.fleet_owned?(parked)
  end

  test "a spot park belongs to the ranked fleet wake" do
    parked = session(SessionGenesis::SPOT)

    assert_equal AuthOutageWakeAuthority::FLEET, AuthOutageWakeAuthority.for(parked)
    assert AuthOutageWakeAuthority.fleet_owned?(parked)
    assert_not AuthOutageWakeAuthority.sweep_owned?(parked)
  end

  # Every park has exactly one owner. A session that answered to both is #617;
  # one that answered to neither is the stranding shape of #655.
  test "every session has exactly one owner" do
    [ SessionGenesis::SPOT, SessionGenesis::PRIORITY ].each do |klass|
      parked = session(klass)
      owners = AuthOutageWakeAuthority::OWNERS.select do |owner|
        owner == AuthOutageWakeAuthority.for(parked)
      end

      assert_equal 1, owners.size, "#{klass} must have exactly one wake authority"
    end
  end

  # Derived, not stored. A class changed while the session is parked moves it to
  # the other mechanism on the next sweep; a stamped owner would leave it naming
  # one that no longer looks for it.
  test "reclassifying a parked session changes hands" do
    parked = session(SessionGenesis::SPOT)
    assert AuthOutageWakeAuthority.fleet_owned?(parked)

    parked.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert AuthOutageWakeAuthority.sweep_owned?(parked.reload)
  end

  # The sweep asks #sweep_owned? about sessions it is iterating, and the safe
  # answer for one it cannot classify is "not mine".
  test "a nil session is nobody's to wake by the sweep" do
    assert_not AuthOutageWakeAuthority.sweep_owned?(nil)
  end

  test "the sentences name the owner each population actually has" do
    spot = session(SessionGenesis::SPOT)
    priority = session(SessionGenesis::PRIORITY)

    assert_match(/fleet wake/, AuthOutageWakeAuthority.resume_sentence(spot))
    assert_match(/precedence order/, AuthOutageWakeAuthority.resume_sentence(spot))
    assert_match(/fifteen minutes/, AuthOutageWakeAuthority.resume_sentence(priority))

    # The half the fleet wake must not touch has to say so, because `get_session`
    # and `quick_search_sessions` are what it reads to decide.
    assert_match(/must not\s+restart it/, AuthOutageWakeAuthority.instruction(priority))
    assert_match(/fleet wake's to\s+start/, AuthOutageWakeAuthority.instruction(spot))
  end
end
