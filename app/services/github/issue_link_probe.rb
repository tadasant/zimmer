# frozen_string_literal: true

module Github
  # Asks GitHub, for a batch of issues in one repo: is each one still open, and
  # which pull requests reference it — with each PR's state and when it last
  # moved.
  #
  # WHY THE TIMELINE AND NOT `linked:pr`
  #
  # Search's `linked:pr` qualifier matches only a **closing reference**, and the
  # population this exists for is mostly not that. The fleet's own PRs routinely
  # reference an issue without a closing keyword — deliberately, when a PR fixes
  # part of an issue and says so ("Addresses #419 … auto-closing on merge would
  # drop a known, still-live production gap"), and accidentally, when a PR that
  # finished an issue simply forgot the keyword. Both look identical to
  # `linked:pr`: no link at all. Of 12 backlog rows examined by hand on
  # 2026-09-11, those two shapes were 10 of them.
  #
  # `CROSS_REFERENCED_EVENT` catches every mention, which is the evidence a human
  # actually needs — and it comes back with the PR's state and `updatedAt`, so
  # "an open PR someone is pushing to" and "an open PR untouched for three weeks"
  # stop being the same answer. That distinction is the whole of
  # WorkBacklogItem::LIVENESS_PR_STALLED.
  #
  # A MENTION IS NOT A CLAIM OF COMPLETION, and nothing here pretends otherwise.
  # A PR that merely names an issue in passing arrives as a reference like any
  # other. That is tolerable precisely because no caller may act on this: it
  # feeds WorkBacklog::LivenessSweep, which classifies rows for a human to triage
  # and never changes the queue.
  #
  # ONE REQUEST PER BATCH. Issues are asked for as aliased fields on a single
  # `repository` node, so a repo's whole candidate set costs a handful of calls
  # rather than one per row.
  class IssueLinkProbe
    # A pull request that references the issue.
    Reference = Data.define(:number, :state, :updated_at) do
      def open? = state == "OPEN"
      def merged? = state == "MERGED"

      # Untouched for `window`. Only meaningful for an open one: a merged PR is
      # supposed to stop moving.
      def idle?(window, now: Time.current) = updated_at.nil? || updated_at < (now - window)
    end

    # One issue as GitHub currently has it.
    Probe = Data.define(:repo, :number, :state, :references) do
      def open? = state == "OPEN"
      def open_references = references.select(&:open?)
      def merged_references = references.select(&:merged?)
    end

    # Issues per GraphQL request. Well inside GitHub's node budget, and small
    # enough that one unresolvable issue number costs a small batch rather than a
    # big one.
    BATCH_SIZE = 40

    # One request is a single round trip; this is the bound on a hung one, in the
    # same spirit as GithubSearchService::REQUEST_TIMEOUT.
    REQUEST_TIMEOUT = 30

    # The probe could not be taken. Never means "the issue is gone" — see
    # GithubCli on why a failed call must not become a definite negative.
    class ProbeError < StandardError; end

    class << self
      # @param repo [String] "owner/name"
      # @param numbers [Array<Integer>] issue numbers in that repo
      # @return [Hash{Integer => Probe}] keyed by issue number. A number GitHub
      #   could not resolve is ABSENT rather than nil-valued, so a caller cannot
      #   accidentally read "not found" as "closed".
      def call(repo:, numbers:)
        owner, name = repo.to_s.split("/", 2)
        raise ProbeError, "repo must be owner/name (got #{repo.inspect})" if owner.blank? || name.blank?

        numbers.uniq.each_slice(BATCH_SIZE).reduce({}) do |found, slice|
          found.merge(request(owner, name, slice))
        end
      end

      private

      def request(owner, name, numbers)
        result = GithubCli.run(
          [ "gh", "api", "graphql", "-F", "owner=#{owner}", "-F", "name=#{name}", "-f", "query=#{query(numbers)}" ],
          timeout: REQUEST_TIMEOUT
        )

        # Parsed BEFORE the exit status is consulted, and that order is the point.
        # GraphQL answers a batch partially: one unresolvable issue number puts a
        # NOT_FOUND in `errors` and makes `gh` exit non-zero, while every other
        # issue in the same response is present and correct. Throwing that away
        # would let one deleted issue blind the sweep to a whole repo.
        payload = parse(result)
        unless payload
          raise ProbeError, "gh api graphql failed for #{owner}/#{name} (#{result.failure_description})"
        end

        repository = payload.dig("data", "repository")
        raise ProbeError, "no repository in the response for #{owner}/#{name}" unless repository.is_a?(Hash)

        repository.each_with_object({}) do |(_alias, node), found|
          next unless node.is_a?(Hash)

          probe = build(node, "#{owner}/#{name}")
          found[probe.number] = probe if probe
        end
      end

      def parse(result)
        JSON.parse(result.stdout.to_s)
      rescue JSON::ParserError
        nil
      end

      def build(node, repo)
        number = node["number"]
        return nil unless number.is_a?(Integer)

        nodes = node.dig("timelineItems", "nodes")
        references = Array(nodes).filter_map do |event|
          source = event.is_a?(Hash) ? event["source"] : nil
          # A cross-reference from an ISSUE, or from a PR in a repository this
          # token cannot see, comes back as an empty object — no number, no
          # state. Not a pull request we can say anything about, so it is not a
          # reference.
          next unless source.is_a?(Hash) && source["number"].is_a?(Integer) && source["state"].present?

          Reference.new(number: source["number"], state: source["state"],
                        updated_at: parse_time(source["updatedAt"]))
        end

        Probe.new(repo: repo, number: number, state: node["state"].to_s, references: references)
      end

      def parse_time(value)
        value.presence && Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      # `last: 30` rather than every reference: the interesting ones are the
      # recent ones, and an issue with more than thirty referencing PRs is not a
      # case a bigger page would settle.
      def query(numbers)
        fields = numbers.each_with_index.map do |number, index|
          <<~GRAPHQL
            i#{index}: issue(number: #{Integer(number)}) {
              number
              state
              timelineItems(last: 30, itemTypes: [CROSS_REFERENCED_EVENT]) {
                nodes { ... on CrossReferencedEvent { source { ... on PullRequest { number state updatedAt } } } }
              }
            }
          GRAPHQL
        end

        <<~GRAPHQL
          query($owner: String!, $name: String!) {
            repository(owner: $owner, name: $name) {
              #{fields.join("\n")}
            }
          }
        GRAPHQL
      end
    end
  end
end
