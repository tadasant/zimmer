# Resolves the TranscriptSource + TranscriptNormalizer pair for a session's
# agent runtime.
#
# This is the single seam where the transcript pipeline branches on runtime.
# TranscriptPollerService, Session, SessionsController, and BroadcastService all
# obtain their source/normalizer here rather than instantiating the Claude
# classes directly, so adding a runtime (e.g. OpenAI Codex, see #3779) is a
# matter of teaching this resolver to return the new pair.
#
# The runtime branch is resolved through RuntimeRegistry, keyed on the session's
# `agent_runtime`. Adding a runtime (e.g. OpenAI Codex, see #3779) is a matter of
# registering its transcript source/normalizer classes in RuntimeRegistry.
module TranscriptRuntime
  module_function

  # @param session [Session] the session whose runtime to resolve
  # @param file_system [FileSystemAdapter, nil] adapter for the source's IO
  # @return [TranscriptSource]
  def source_for(session, file_system: nil)
    RuntimeRegistry.for(session&.agent_runtime).transcript_source_class.new(file_system: file_system)
  end

  # @param session [Session] the session whose runtime to resolve
  # @return [TranscriptNormalizer]
  def normalizer_for(session)
    RuntimeRegistry.for(session&.agent_runtime).transcript_normalizer_class.new
  end
end
