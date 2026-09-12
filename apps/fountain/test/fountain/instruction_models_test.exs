defmodule Fountain.InstructionModelsTest do
  use ExUnit.Case, async: true

  test "shipped help and skills never recommend adapter-refused models" do
    root = Application.app_dir(:fountain, "priv")
    help = Path.wildcard(Path.join(root, "help/*.md"))
    skills = Path.wildcard(Path.join(root, "external_skills/**/SKILL.md"))
    assert help != []
    assert skills != []

    refused =
      for path <- help ++ skills,
          content = File.read!(path),
          {model, observed} <- Fountain.RefusedModels.all(),
          String.contains?(content, model) do
        {Path.relative_to(path, root), model, observed}
      end

    assert refused == [], "Shipped instructions name refused models: #{inspect(refused)}"
  end
end
