#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone unit tests for the GHCR retention selector.
# Runs without Rails/bundler:  ruby scripts/ghcr_retention_test.rb
require "minitest/autorun"
require_relative "ghcr_retention"

class GhcrRetentionTest < Minitest::Test
  def keep(versions, limit: 50)
    GhcrRetention.select_to_keep(versions, limit: limit).map(&:raw)
  end

  def prune(versions, limit: 50)
    GhcrRetention.select_to_prune(versions, limit: limit).map(&:raw)
  end

  def test_parse_ignores_non_semver
    assert_nil GhcrRetention.parse("latest")
    assert_nil GhcrRetention.parse("sha-deadbeef")
    refute_nil GhcrRetention.parse("v1.2.3")
    refute_nil GhcrRetention.parse("1.2.3-rc1")
  end

  def test_small_set_keeps_everything
    v = %w[1.0.0 1.0.1 1.1.0]
    assert_equal 3, keep(v).size
    assert_empty prune(v)
  end

  def test_non_semver_tags_never_pruned_or_counted
    v = %w[1.0.0 latest sha-abc main]
    assert_equal %w[1.0.0], keep(v)
    assert_empty prune(v) # non-semver tags are ignored entirely
  end

  def test_never_exceeds_limit
    v = (0..200).map { |i| "1.0.#{i}" }
    assert_operator keep(v).size, :<=, 50
    # Everything kept + pruned accounts for all distinct semver versions.
    assert_equal 201, keep(v).size + prune(v).size
  end

  def test_tier1_keeps_latest_of_every_major_even_when_capped
    # Many patches on major 1, plus older majors 2..0. Latest of each major must survive.
    v = (0..100).map { |i| "1.0.#{i}" } + %w[2.0.0 2.3.4 3.1.0 0.9.9]
    kept = keep(v)
    assert_includes kept, "3.1.0"        # latest of major 3
    assert_includes kept, "2.3.4"        # latest of major 2
    assert_includes kept, "1.0.100"      # latest of major 1
    assert_includes kept, "0.9.9"        # latest of major 0
  end

  def test_tier2_keeps_latest_of_every_minor
    v = %w[1.0.0 1.0.5 1.1.0 1.1.9 1.2.0 1.2.3]
    kept = keep(v)
    assert_includes kept, "1.0.5"
    assert_includes kept, "1.1.9"
    assert_includes kept, "1.2.3"
  end

  def test_tier3_keeps_latest_20_patches_in_lead_line
    # 40 patches on the leading line 2.5.x; the top 20 must all be kept.
    v = (0..39).map { |i| "2.5.#{i}" }
    kept = keep(v)
    (20..39).each { |i| assert_includes kept, "2.5.#{i}", "expected 2.5.#{i} kept" }
    # And the cap is still respected.
    assert_operator kept.size, :<=, 50
  end

  def test_tier4_modulo_cadence_favors_recent_older_versions
    # Leading line 1.5.x has 20 patches (all kept by tier3). Older line 1.4.x has
    # 30 patches; tier4 should thin them to a ~mod-10 cadence, keeping the most
    # recent of each stride, not every one.
    lead = (0..19).map { |i| "1.5.#{i}" }
    old = (0..29).map { |i| "1.4.#{i}" }
    kept = keep(lead + old)
    old_kept = kept.select { |k| k.start_with?("1.4.") }
    # Far fewer than all 30 older patches survive (cadence thinning happened),
    # but at least the latest older line representative (tier2) is present.
    assert_operator old_kept.size, :<, 30
    assert_includes kept, "1.4.29" # latest of the 1.4 minor (tier2)
  end

  def test_realistic_150_version_history_capped_to_50
    # Simulate a year of releases: majors 1..3, several minors each, many patches.
    v = []
    v += (0..49).map { |i| "3.2.#{i}" }      # current lead line, 50 patches
    v += (0..9).map { |i| "3.1.#{i}" }
    v += (0..9).map { |i| "3.0.#{i}" }
    v += (0..29).map { |i| "2.4.#{i}" }
    v += (0..9).map { |i| "2.0.#{i}" }
    v += (0..19).map { |i| "1.0.#{i}" }
    kept = keep(v)
    assert_operator kept.size, :<=, 50
    # Highest-priority guarantees hold under the cap:
    assert_includes kept, "3.2.49"           # overall latest
    assert_includes kept, "2.4.29"           # latest of a mid minor
    assert_includes kept, "1.0.19"           # latest of the oldest major
    # Top-20 of lead line preserved:
    (30..49).each { |i| assert_includes kept, "3.2.#{i}" }
  end

  def test_v_prefixed_and_bare_mix_dedup
    v = %w[v1.2.3 1.2.3 v1.2.4]
    kept = keep(v)
    # 1.2.3 and v1.2.3 are the same version; dedup to 2 distinct versions.
    assert_equal 2, (kept + prune(v)).size
  end
end
