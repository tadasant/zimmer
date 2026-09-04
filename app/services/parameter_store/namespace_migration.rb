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
    #
    # `legacy_remaining` is the one that matters for "is this finished": true
    # when the old path still holds this variable after the run.
    Item = Struct.new(:variable, :action, :from_path, :to_path, :from_id, :to_id,
      :detail, :legacy_remaining, keyword_init: true) do
      def failed? = %i[conflict failed].include?(action)
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

      items = (old.keys | current.keys).sort.map { |variable| step(variable, old, current) }

      Report.new(dry_run: dry_run, env: env, project_id: @resolver.project_id,
        from_namespace: from_namespace, to_namespace: to_namespace, items: items)
    end

    private

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

      copied = new_value.nil? ? copy(item, old_value) : "the canonical path already holds it"
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
        return finish(item, :failed,
          "#{copied}, but #{item.to_path} does not resolve through the chain, so #{item.from_id} " \
          "was NOT deleted. The usual cause is the missing secretAccessor binding on the new " \
          "secret — see docs/operate/secrets-parameter-store.")
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
    # A fresh provider each time, deliberately: a shared one would serve a
    # snapshot taken before the write.
    def verified?(item)
      chain = SecretProviders::Chain.new([
        SecretProviders::ParameterStoreProvider.new(@resolver, namespaces: [ to_namespace ])
      ])
      provider = chain.provider_for(item.variable)

      !provider.nil? && provider.namespace_for(item.variable) == to_namespace
    end

    def finish(item, action, detail, legacy_remaining: nil)
      item.action = action
      item.detail = detail
      item.legacy_remaining = legacy_remaining.nil? ? action != :already_migrated : legacy_remaining
      item
    end
  end
end
