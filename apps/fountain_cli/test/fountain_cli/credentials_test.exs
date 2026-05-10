defmodule FountainCli.CredentialsTest do
  use ExUnit.Case, async: false

  alias FountainCli.Credentials

  # Use an application-env override so we never touch the real
  # ~/.fountain/credentials during tests.
  setup do
    tmp = Path.join(System.tmp_dir!(), "fountain_test_#{:rand.uniform(999_999)}")
    path = Path.join(tmp, "credentials")
    Application.put_env(:fountain_cli, :credentials_path_override, path)

    on_exit(fn ->
      Application.delete_env(:fountain_cli, :credentials_path_override)
      File.rm_rf!(tmp)
    end)

    {:ok, path: path}
  end

  # ── parse_all/1 ─────────────────────────────────────────────

  describe "parse_all/1" do
    test "parses a single profile" do
      toml = """
      [default]
      api_key = "ftn_abc123"
      base_url = "https://fountain.dev"
      """

      assert Credentials.parse_all(toml) == %{
               "default" => %{
                 "api_key" => "ftn_abc123",
                 "base_url" => "https://fountain.dev"
               }
             }
    end

    test "parses multiple profiles" do
      toml = """
      [default]
      api_key = "ftn_def456"
      base_url = "https://fountain.dev"

      [staging]
      api_key = "ftn_abc123"
      base_url = "https://staging.fountain.dev"
      """

      result = Credentials.parse_all(toml)
      assert result["default"]["api_key"] == "ftn_def456"
      assert result["staging"]["api_key"] == "ftn_abc123"
      assert result["staging"]["base_url"] == "https://staging.fountain.dev"
    end

    test "returns empty map for empty content" do
      assert Credentials.parse_all("") == %{}
    end

    test "ignores blank lines and comment lines" do
      toml = """
      # This is a comment
      [default]
      # Another comment
      api_key = "ftn_abc"
      """

      assert Credentials.parse_all(toml) == %{"default" => %{"api_key" => "ftn_abc"}}
    end

    test "handles values without quotes" do
      toml = """
      [default]
      api_key = ftn_noquotes
      """

      assert Credentials.parse_all(toml)["default"]["api_key"] == "ftn_noquotes"
    end
  end

  # ── read_profile/1 ────────────────────────────────────────

  describe "read_profile/1" do
    test "returns empty map when file does not exist" do
      assert Credentials.read_profile("default") == %{}
    end

    test "returns empty map for a missing profile" do
      Credentials.write_profile("default", %{"api_key" => "ftn_x"})
      assert Credentials.read_profile("nonexistent") == %{}
    end

    test "returns profile attrs when file and profile exist" do
      Credentials.write_profile("default", %{"api_key" => "ftn_abc", "base_url" => "https://fountain.dev"})
      assert Credentials.read_profile("default") == %{
               "api_key" => "ftn_abc",
               "base_url" => "https://fountain.dev"
             }
    end
  end

  # ── write_profile/2 ───────────────────────────────────────

  describe "write_profile/2" do
    test "creates credentials file and parent directories" do
      Credentials.write_profile("default", %{"api_key" => "ftn_abc123"})
      assert File.exists?(Credentials.credentials_path())
    end

    test "written profile can be read back" do
      Credentials.write_profile("default", %{"api_key" => "ftn_abc123", "base_url" => "https://fountain.dev"})
      assert Credentials.read_profile("default") == %{
               "api_key" => "ftn_abc123",
               "base_url" => "https://fountain.dev"
             }
    end

    test "writing staging profile does not alter default profile" do
      Credentials.write_profile("default", %{"api_key" => "ftn_default"})
      Credentials.write_profile("staging", %{"api_key" => "ftn_staging", "base_url" => "https://staging.fountain.dev"})

      assert Credentials.read_profile("default") == %{"api_key" => "ftn_default"}
      assert Credentials.read_profile("staging")["api_key"] == "ftn_staging"
      assert Credentials.read_profile("staging")["base_url"] == "https://staging.fountain.dev"
    end

    test "upsert: updating staging does not alter default" do
      Credentials.write_profile("default", %{"api_key" => "ftn_default"})
      Credentials.write_profile("staging", %{"api_key" => "ftn_staging_v1"})
      Credentials.write_profile("staging", %{"api_key" => "ftn_staging_v2"})

      assert Credentials.read_profile("default") == %{"api_key" => "ftn_default"}
      assert Credentials.read_profile("staging") == %{"api_key" => "ftn_staging_v2"}
    end
  end

  # ── delete_profile/1 ──────────────────────────────────────

  describe "delete_profile/1" do
    test "no-op when file does not exist" do
      assert Credentials.delete_profile("default") == :ok
    end

    test "removes the named section without affecting other profiles" do
      Credentials.write_profile("default", %{"api_key" => "ftn_default"})
      Credentials.write_profile("staging", %{"api_key" => "ftn_staging"})
      Credentials.delete_profile("staging")

      assert Credentials.read_profile("default") == %{"api_key" => "ftn_default"}
      assert Credentials.read_profile("staging") == %{}
    end

    test "no-op when deleting a profile that does not exist in the file" do
      Credentials.write_profile("default", %{"api_key" => "ftn_default"})
      assert Credentials.delete_profile("nonexistent") == :ok
      assert Credentials.read_profile("default") == %{"api_key" => "ftn_default"}
    end
  end

  # ── profile_name/1 ────────────────────────────────────────

  describe "profile_name/1" do
    setup do
      # Ensure FOUNTAIN_PROFILE is clean between tests
      System.delete_env("FOUNTAIN_PROFILE")
      on_exit(fn -> System.delete_env("FOUNTAIN_PROFILE") end)
      :ok
    end

    test "returns the :profile opt when provided" do
      assert Credentials.profile_name(profile: "staging") == "staging"
    end

    test "returns FOUNTAIN_PROFILE env var when no opt" do
      System.put_env("FOUNTAIN_PROFILE", "env_profile")
      assert Credentials.profile_name([]) == "env_profile"
    end

    test "defaults to 'default'" do
      assert Credentials.profile_name([]) == "default"
    end

    test "opt takes precedence over FOUNTAIN_PROFILE env var" do
      System.put_env("FOUNTAIN_PROFILE", "env_profile")
      assert Credentials.profile_name(profile: "opt_profile") == "opt_profile"
    end
  end
end
