# frozen_string_literal: true

# Builders for work backlog tests. Items are created directly, bypassing the
# ranking, so a test can lay the queue out exactly and then exercise the rules.
module WorkBacklogHelpers
  def backlog_item(key: "zimmer##{SecureRandom.hex(3)}", cost: "small", precedence: nil, **overrides)
    precedence ||= WorkBacklog::Ranking.band_for(cost).base
    WorkBacklogItem.create!({
      key: key,
      issue_url: "https://github.com/tadasant/zimmer/issues/#{key[/\d+/] || 1}",
      repo: "tadasant/zimmer",
      surface: "zimmer",
      title: "Item #{key}",
      kind: "bug",
      scope_direction: "convergent",
      estimated_cost: cost,
      gate_verdict: "auto-proceed",
      decided_at: Date.new(2026, 8, 29),
      added_at: Time.current,
      added_by: "issue-work-gate",
      added_via: WorkBacklogItem::IMPORT,
      precedence: precedence,
      pinned: false,
      status: WorkBacklogItem::QUEUED,
      payload: { "ratings" => { "estimated_cost" => cost } }
    }.merge(overrides))
  end

  def append_attributes(key: "zimmer##{SecureRandom.hex(3)}", cost: "small", **overrides)
    {
      "key" => key,
      "issue_url" => "https://github.com/tadasant/zimmer/issues/#{key[/\d+/] || 1}",
      "repo" => "tadasant/zimmer",
      "surface" => "zimmer",
      "title" => "Item #{key}",
      "kind" => "bug",
      "scope_direction" => "convergent",
      "estimated_cost" => cost,
      "gate_verdict" => "auto-proceed",
      "decided_at" => "2026-08-29",
      "ratings" => { "estimated_cost" => cost, "requirement_impact" => "medium" }
    }.merge(overrides)
  end

  def queued_keys
    WorkBacklogItem.queued.in_rank_order.pluck(:key)
  end
end
