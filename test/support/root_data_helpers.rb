# frozen_string_literal: true

# Builds catalog roots carrying `data_namespace` / `data_collections`, and
# sessions created from them, for the root data tests.
module RootDataHelpers
  NOTES_SCHEMA = {
    "type" => "object",
    "required" => [ "title" ],
    "properties" => { "title" => { "type" => "string" }, "status" => { "type" => "string" } }
  }.freeze

  def root_data_root(name, **config)
    AgentRootsConfig::AgentRoot.new(
      name,
      { "name" => name, "url" => "https://github.com/tadasant/zimmer.git" }.merge(config.deep_stringify_keys)
    )
  end

  def default_root_data_collections
    {
      "notes" => { "description" => "Notes", "schema" => NOTES_SCHEMA, "retention_days" => 30 },
      "runs" => {}
    }
  end

  # Stub the catalog to exactly these roots.
  def stub_root_data_catalog(*roots)
    AgentRootsConfig.stubs(:all).returns(roots)
  end

  def root_data_session(root_key)
    session = sessions(:running)
    session.update_columns(metadata: (session.metadata || {}).merge("agent_root_key" => root_key))
    session
  end
end
