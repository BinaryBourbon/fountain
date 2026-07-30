defmodule Fountain.SpriteSkillsTest do
  use ExUnit.Case, async: true

  alias Fountain.SpriteSkills

  describe "github_install_cmd/2" do
    test "unpinned source installs from the default branch" do
      cmd = SpriteSkills.github_install_cmd(%{"source" => "owner/repo"}, "claude")

      assert cmd == "npx -y skills@latest add owner/repo --global --agent claude --yes"
    end

    test "ref pins the source as owner/repo@ref" do
      cmd =
        SpriteSkills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "v1.2.0"},
          "claude"
        )

      assert cmd == "npx -y skills@latest add owner/repo@v1.2.0 --global --agent claude --yes"
    end

    test "empty ref is treated as unpinned" do
      cmd = SpriteSkills.github_install_cmd(%{"source" => "owner/repo", "ref" => ""}, "claude")

      assert cmd == "npx -y skills@latest add owner/repo --global --agent claude --yes"
    end

    test "name adds the --skill flag alongside a ref" do
      cmd =
        SpriteSkills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "abc123", "name" => "my-skill"},
          "claude"
        )

      assert cmd ==
               "npx -y skills@latest add owner/repo@abc123 --global --agent claude --yes --skill my-skill"
    end

    test "shell-unsafe ref raises instead of reaching the command" do
      assert_raise ArgumentError, fn ->
        SpriteSkills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "main; rm -rf /"},
          "claude"
        )
      end
    end

    test "shell-unsafe source raises" do
      assert_raise ArgumentError, fn ->
        SpriteSkills.github_install_cmd(%{"source" => "owner/repo$(whoami)"}, "claude")
      end
    end
  end
end
