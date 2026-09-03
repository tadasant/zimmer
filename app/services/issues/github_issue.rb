# frozen_string_literal: true

module Issues
  # One GitHub issue as the Issues page reads it: the handful of fields the queue
  # join, the direction chain and the trend series need, and nothing else.
  #
  # Deliberately NOT an ActiveRecord model. GitHub is the source of truth for
  # issue state, so there is no mirror table here — these are built on every
  # (uncached) request from a search result and thrown away with the response.
  GithubIssue = Data.define(:repo, :number, :title, :url, :state, :created_at, :closed_at, :labels) do
    # "zimmer#498" — the same key WorkBacklogItem uses, so the join between the
    # queue and GitHub is a hash lookup rather than a URL comparison.
    def key = "#{repo.to_s.split('/').last}##{number}"

    def open? = state == "open"

    # The day this issue first counted as open.
    def opened_on = created_at&.to_date

    # The last day it counted as open, or nil if it still does. An issue closed
    # at 15:00 was not open at the end of that day, so the last open day is the
    # one before it closed — which also means an issue opened and closed the same
    # day never appears in the series, correctly.
    def last_open_on
      return nil if closed_at.nil?

      closed_at.to_date - 1
    end

    # Whether this issue was open at the END of `date`. The trend series counts
    # exactly this over a run of days; Issues::Trend derives the same answer from
    # `opened_on` / `last_open_on` in one pass rather than asking per day.
    def open_on?(date)
      from = opened_on
      return false if from.nil? || from > date

      last = last_open_on
      last.nil? || last >= date
    end

    # From a `search/issues` item. Times come back as ISO 8601 strings; a nil
    # `closed_at` on an open issue is normal.
    def self.from_search_item(item, repo)
      new(
        repo: repo,
        number: item["number"].to_i,
        title: item["title"].to_s,
        url: item["html_url"].to_s,
        state: item["state"].to_s,
        created_at: parse_time(item["created_at"]),
        closed_at: parse_time(item["closed_at"]),
        labels: Array(item["labels"]).filter_map { |label| label.is_a?(Hash) ? label["name"] : label }
      )
    end

    def self.parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # The cache holds plain JSON-ish hashes rather than these objects — see
    # GithubSnapshot for why — so the round trip is spelled out here.
    def to_h_for_cache
      {
        "repo" => repo, "number" => number, "title" => title, "url" => url, "state" => state,
        "created_at" => created_at&.iso8601, "closed_at" => closed_at&.iso8601, "labels" => labels
      }
    end

    def self.from_cache(hash)
      new(
        repo: hash["repo"], number: hash["number"], title: hash["title"], url: hash["url"],
        state: hash["state"], created_at: parse_time(hash["created_at"]),
        closed_at: parse_time(hash["closed_at"]), labels: Array(hash["labels"])
      )
    end
  end
end
