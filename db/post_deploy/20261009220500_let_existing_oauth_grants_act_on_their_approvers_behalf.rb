# frozen_string_literal: true

# Raises every OAuth connection approved before connection privilege levels
# existed to "acts on my behalf" (OauthServer::ACT_AS_HUMAN_SCOPE).
#
# WHY. Those grants were approved on a consent screen that offered no choice, and
# the one that exists in practice is the operator's own Claude app connection —
# the assistant this level was introduced for. The operator decided its existing
# connections start elevated; a connection approved from now on gets whatever its
# approver picks. Each grant this raises shows "set when connection levels were
# introduced" on Settings → API keys, where it can be lowered in one click.
#
# WHY A TASK. It is a one-time data change that must run after the column it
# writes exists and must say what it covered; `post_deploy_task_runs` does both.
#
# IDEMPOTENT. It touches only live grants whose level was never chosen
# (`scope_changed_at` is NULL). A grant approved after the deploy has its level
# stamped at consent, and one this task raised is stamped `backfill`, so a second
# run finds nothing.
class LetExistingOauthGrantsActOnTheirApproversBehalf < PostDeployTask
  def up
    raised = []
    OauthServer::Grant.active.where(scope_changed_at: nil).find_each do |grant|
      raised << grant.id if grant.change_privilege!(OauthServer::ACT_AS_HUMAN, reason: "backfill")
    end
    checkpoint!(raised: stats.fetch("raised", 0) + raised.size, raised_grant_ids: raised)
  end
end
