# frozen_string_literal: true

module ParameterStore
  # Moves Zimmer's secrets from the pre-rename namespace to the canonical one.
  #
  # ## Why this is not a rename
  #
  # {Namespace.parameter_id} folds a whole path into one flat GCP resource id,
  # and the fold is LOSSY, so a renamed path lands on a DIFFERENT id. There is no
  # GCP verb that renames a parameter, and even if there were, that id is
  # embedded in the `__REF__` the envelope carries. So a move is four steps per
  # variable, in this order and no other:
  #
  #   1. **Read** the value at the old path — through `:render`, the resolver's
  #      only read verb, which is why this needs the resolver credential and not
  #      just the writer's.
  #   2. **Write** it at the new path: a Secret Manager secret, a Parameter
  #      Manager parameter, the IAM binding that lets the parameter dereference
  #      its own secret, and the envelope joining them ({WriteClient#upsert}).
  #   3. **Verify** the new path resolves *through the ordinary resolution
  #      chain*, fenced to the canonical namespace so the old copy cannot answer
  #      in its place and make the check vacuous.
  #   4. **Delete** the old pair — only then.
  #
  # ## Re-runnable, because it holds no cursor
  #
  # Every step is decided from what the store holds right now: old copy only
  # means "copy it", both copies mean "verify and delete the old", canonical only
  # means "done". A run that dies halfway leaves a state the next run reads
  # correctly, and a run over a finished migration does nothing and says so.
  # {Report#complete?} is the question that decides whether the resolver's
  # pre-rename read path can be dropped.
  #
  # ## What it refuses to do
  #
  # If both paths hold the variable with DIFFERENT values, this does not choose.
  # The canonical value is the live one — it wins the chain's precedence — so
  # copying the old one over it would silently roll back whatever rotation put it
  # there. That variable is reported as a conflict and left untouched.
  #
  # ## No value is ever printed
  #
  # The report carries names, paths, ids and verdicts. Never a value, never a
  # length, never a digest.
  class NamespaceMigration
    # One variable's disposition. `action` is what this run did — or, in a dry
    # run, what it would have done.
    #
    #   :already_migrated — the old path does not hold it. Nothing to do.
    #   :copied           — value now at the canonical path; old copy left alone.
    #   :migrated         — copied, verified, and the old pair deleted.
    #   :conflict         — both paths hold it, with different values.
    #   :failed           — the store refused, or the verify did not pass.
    #   :skipped          — the run stopped before reaching it.
    #
    # `legacy_remaining` is the one that matters for "is this finished": true
    # when the old path still holds this variable after the run.
    Item = Struct.new(:variable, :action, :from_path, :to_path, :from_id, :to_id,
      :detail, :legacy_remaining, keyword_init: true) do
      def failed? = %i[conflict failed skipped].include?(action)
    end

    Report = Struct.new(:dry_run, :env, :project_id, :from_namespace, :to_namespace, :items,
      keyword_init: true) do
      def failures = items.select(&:failed?)
      def ok? = failures.empty?

      # Names still in the pre-rename namespace when this run finished. In a dry
      # run, the ones that would still be there had nothing been done.
      def legacy_remaining = items.select(&:legacy_remaining).map(&:variable)

      # Nothing left at the old path — the precondition for dropping the
      # resolver's pre-rename read path.
      def complete? = ok? && legacy_remaining.empty?

      def counts = items.group_by(&:action).transform_values(&:size)
    end

    attr_reader :env, :dry_run, :prune

    # @param resolver [GcpClient] the read half.
    # @param writer [WriteClient, nil] the write half. nil is legal, and makes a
    #   dry run the only thing this can do.
    # @param env [String] the Rails environment whose namespaces to move. NOT
    #   necessarily the environment this process runs as: a migration of
    #   production's namespace is normally driven from somewhere else.
    # @param dry_run [Boolean] plan only; issue no write and no delete.
    # @param prune [Boolean] delete the old pair after a successful verify. False
    #   stops after the copy, which is the safe, fully reversible half-step.
    def initialize(resolver:, writer: nil, env: Rails.env, dry_run: true, prune: true)
      raise ArgumentError, "a live migration needs a write client" if !dry_run && writer.nil?

      @resolver = resolver
      @writer = writer
      @env = env.to_s
      @dry_run = dry_run
      @prune = prune

      # If these ever fold together — a follow-up that retires the pre-rename
      # read path by pointing LEGACY_SCOPE at SCOPE rather than by shortening
      # read_namespaces — then `old` and `current` below are the same map, every
      # variable reads as already-copied, and the prune deletes the only copy
      # immediately after verifying it. Refuse rather than discover that live.
      return unless from_namespace == to_namespace

      raise ArgumentError,
        "the pre-rename namespace and the canonical one are both #{to_namespace}; " \
        "there is nothing to migrate and a prune would delete the only copy"
    end


    def from_namespace = Namespace.legacy_static_namespace(env)
    def to_namespace = Namespace.static_namespace(env)

    # @return [Report]
    # @raise [StoreError, AuthError] only from the initial read: a store that
    #   cannot be listed is not a migration that partly ran.
    def call
      snapshot = @resolver.resolve_all([ to_namespace, from_namespace ])
      old = snapshot.fetch(from_namespace)
      current = snapshot.fetch(to_namespace)

      variables = (old.keys | current.keys).sort
      refuse_fold_collisions!(variables)
      @stop = false
      items = []
      variables.each_with_index do |variable, index|
        items << step(variable, old, current)
        next unless @stop

        # The store cannot be read at all now, so every later step would write a
        # copy it could not verify. Stop — and name the variables that were not
        # looked at, rather than leaving them off the report entirely.
        items.concat(variables[(index + 1)..].map { |name| skipped(name) })
        break
      end

      Report.new(dry_run: dry_run, env: env, project_id: @resolver.project_id,
        from_namespace: from_namespace, to_namespace: to_namespace, items: items)
    end

    private

    # Refuse the whole run when two names in scope fold onto ONE canonical id.
    #
    # Within a single namespace this cannot happen — two colliding names would
    # already be one parameter. Across two namespaces it can: the store may hold
    # `FOO_BAR` at the old path and `FOO__BAR` at the new one, which
    # {Namespace.parameter_id} collapses together. Migrating `FOO_BAR` would then
    # append its bytes to `FOO__BAR`'s Secret Manager secret (the create 409s and
    # is tolerated, and the envelope is left alone because the parameter already
    # has a version), silently changing what `FOO__BAR` resolves to. The verify
    # correctly fails — the canonical namespace answers for `FOO__BAR`, not for
    # `FOO_BAR` — and the rollback then deletes the pair, destroying the only
    # copy of a variable this run was never asked to touch.
    #
    # No guard downstream can catch it: `refuse_unmanaged!` passes because the
    # resource genuinely is Zimmer's, and the envelope-path fence is what makes
    # the two names distinguishable in the first place. So it is refused here,
    # before anything is written, and the operator renames one of them by hand.
    def refuse_fold_collisions!(variables)
      collisions = variables
        .group_by { |variable| Namespace.parameter_id(Namespace.parameter_path(variable, env)) }
        .select { |_id, names| names.size > 1 }
      return if collisions.empty?

      detail = collisions.map { |id, names| "#{names.sort.join(' and ')} both fold to #{id}" }
      raise ArgumentError,
        "refusing to migrate: #{detail.join('; ')}. Writing either one would overwrite the other's " \
        "secret in place. Rename one of them in the store by hand, then re-run."
    end

    def step(variable, old, current)
      item = new_item(variable)
      old_value = old[variable]
      new_value = current[variable]

      return finish(item, :already_migrated, "only the canonical path holds it") if old_value.nil?

      if !new_value.nil? && new_value != old_value
        return finish(item, :conflict,
          "both paths hold it, with different values. The canonical path wins the resolution " \
          "chain, so its value is the live one and copying the old one over it would roll that " \
          "back silently. Resolve it by hand — delete whichever copy is wrong — and re-run.")
      end

      if new_value.nil?
        copied = copy(item, old_value)
        # Recorded before the verify so roll_back can tell "this run wrote it"
        # from "it was already there".
        item.action = :copied
      else
        copied = "the canonical path already holds it"
      end
      settle(item, copied)
    rescue StoreError, AuthError => e
      # The class and the message, never a body: on these verbs Google's error
      # body can quote the payload.
      finish(item, :failed, "#{e.class}: #{e.message}")
    end

    def new_item(variable)
      from_path = Namespace.legacy_parameter_path(variable, env)
      to_path = Namespace.parameter_path(variable, env)

      Item.new(variable: variable, from_path: from_path, to_path: to_path,
        from_id: Namespace.parameter_id(from_path), to_id: Namespace.parameter_id(to_path))
    end

    # @return [String] what happened, for the item's detail.
    def copy(item, value)
      return "would create #{item.to_id} and copy the value there" if dry_run

      @writer.upsert(item.variable, value, env: env)
      "copied the value to #{item.to_id}"
    end

    def settle(item, copied)
      unless prune
        return finish(item, :copied, "#{copied}; left #{item.from_id} in place (pruning is off)",
          legacy_remaining: true)
      end

      # `legacy_remaining` stays true here on purpose: a dry run deleted nothing,
      # so the old path still holds it. Report#complete? answers "is the store
      # migrated", not "would this plan migrate it".
      if dry_run
        return finish(item, :migrated,
          "would verify #{item.to_path} through the chain, then delete #{item.from_id} (#{copied})")
      end

      unless verified?(item)
        # The canonical pair exists and cannot be rendered. That is not merely
        # this variable's problem: GcpClient#rendered_envelope re-raises any
        # non-404, so one unreadable parameter fails the resolve of the WHOLE
        # project — for this run's remaining variables AND for the live
        # deployment. Take back exactly what this run wrote, then stop.
        rolled_back = roll_back(item)
        @stop = true
        return finish(item, :failed,
          "#{copied}, but #{item.to_path} does not resolve through the chain, so #{item.from_id} " \
          "was NOT deleted#{rolled_back}. The usual cause is the missing secretAccessor binding " \
          "on the new secret — see docs/operate/secrets-parameter-store.")
      end

      @writer.delete(item.variable, env: env, path: item.from_path)
      finish(item, :migrated, "#{copied}, verified #{item.to_path}, deleted #{item.from_id}",
        legacy_remaining: false)
    end

    # Verify through the ORDINARY chain — the production provider class over the
    # production resolver client — fenced to the canonical namespace alone, so
    # the pre-rename copy cannot answer in its place. A check that let both
    # namespaces answer would confirm only that the store still holds the value
    # somewhere, which is exactly what is not in question.
    #
    # ONE provider for the whole run, invalidated before each check rather than
    # rebuilt. Freshness is what matters here — a snapshot taken before the write
    # would verify nothing — and `invalidate` gives exactly that. Rebuilding it
    # per variable gave the same freshness at N times the cost: a resolve is a
    # full project pass (one list, then a versions-list and a `:render` per
    # managed parameter), so a 40-secret migration issued thousands of calls
    # against a fan-out of 8. Slow, and a self-inflicted rate limit on the one
    # run that must not fail halfway.
    def verified?(item)
      verification_chain.invalidate
      provider = verification_chain.provider_for(item.variable)

      !provider.nil? && provider.namespace_for(item.variable) == to_namespace
    rescue StoreError, AuthError
      # A raise here is the WORST case, not an unrelated one: the commonest cause
      # is that the pair just written cannot be rendered, and an unrenderable
      # parameter fails the resolve of the whole project. Treating it as "not
      # verified" is what routes it into the rollback below; letting it escape to
      # step's rescue would mark the item failed and leave the poison in place.
      false
    end

    def verification_chain
      @verification_chain ||= SecretProviders::Chain.new([
        SecretProviders::ParameterStoreProvider.new(@resolver, namespaces: [ to_namespace ])
      ])
    end

    # Undo the canonical pair this run created, so a failed verify does not leave
    # a parameter behind that every subsequent read chokes on. Only what THIS run
    # wrote: a canonical copy that was already there is not ours to remove, and
    # the pre-rename copy is untouched either way, so the value stays reachable.
    #
    # @return [String] a clause for the item's detail.
    def roll_back(item)
      return " (the canonical copy was already there and was left alone)" unless item.action == :copied

      @writer.delete(item.variable, env: env)
      " (and #{item.to_id}, which this run created, was removed again)"
    rescue StoreError, AuthError => e
      " (and #{item.to_id} could NOT be removed again: #{e.class}: #{e.message} — it will fail " \
      "every read of this project until it is deleted by hand)"
    end

    def skipped(variable)
      finish(new_item(variable), :skipped,
        "not looked at: the run stopped after the failure above left the store unreadable")
    end

    def finish(item, action, detail, legacy_remaining: nil)
      item.action = action
      item.detail = detail
      item.legacy_remaining = legacy_remaining.nil? ? action != :already_migrated : legacy_remaining
      item
    end
  end
end
