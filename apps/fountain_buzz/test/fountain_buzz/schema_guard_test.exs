defmodule FountainBuzz.SchemaGuardTest do
  @moduledoc """
  The schema guard can see this extension (#1536).

  Every check is in `FountainWeb.ExtensionSchemaGuardCase`; the responses
  themselves are validated by the guard on every request the rest of this
  suite makes.
  """
  use FountainWeb.ExtensionSchemaGuardCase, extension: FountainBuzz.Extension
end
