defmodule FountainCli.Auth do
  @moduledoc """
  Subcommands for authentication against the Fountain API.

      fountain auth login [--profile <name>]
          Prompts for email and password, calls POST /api/auth/token,
          and writes the returned key to ~/.fountain/credentials.

      fountain auth logout [--profile <name>]
          Deletes the named profile from ~/.fountain/credentials.

      fountain auth whoami [--profile <name>]
          Calls GET /api/auth/me and prints email + role.
  """

  def dispatch(["login" | rest]), do: login(rest)
  def dispatch(["logout" | rest]), do: logout(rest)
  def dispatch(["whoami" | rest]), do: whoami(rest)

  def dispatch(args) do
    FountainCli.die(
      "unknown auth command: #{Enum.join(args, " ")}\n" <>
        "Available: login, logout, whoami"
    )
  end

  # ── login ──────────────────────────────────────────────────

  defp login(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [profile: :string])
    profile = FountainCli.Credentials.profile_name(opts)

    email = prompt("Email: ")
    password = prompt_password("Password: ")

    base = FountainCli.Config.base_url()
    url = (base <> "/api/auth/token") |> String.to_charlist()
    body = Jason.encode!(%{email: email, password: password})

    case :httpc.request(
           :post,
           {url, [], ~c"application/json", body},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, resp_body}} when status in 200..299 ->
        handle_login_response(resp_body, email, profile, base)

      {:ok, {{_, status, _}, _, resp_body}} ->
        FountainCli.die("login failed (HTTP #{status}): #{resp_body}")

      {:error, reason} ->
        FountainCli.die("request failed: #{inspect(reason)}")
    end
  end

  defp handle_login_response(resp_body, email, profile, base) do
    key =
      case Jason.decode(resp_body) do
        {:ok, %{"data" => %{"api_key" => k}}} when is_binary(k) -> k
        {:ok, %{"data" => %{"token" => k}}} when is_binary(k) -> k
        {:ok, %{"api_key" => k}} when is_binary(k) -> k
        {:ok, %{"token" => k}} when is_binary(k) -> k
        other -> FountainCli.die("unexpected login response: #{inspect(other)}")
      end

    FountainCli.Credentials.write_profile(profile, %{"api_key" => key, "base_url" => base})

    IO.puts(
      "Logged in as #{email}. " <>
        "Credentials written to ~/.fountain/credentials (profile: #{profile})."
    )
  end

  # ── logout ────────────────────────────────────────────────

  defp logout(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [profile: :string])
    profile = FountainCli.Credentials.profile_name(opts)
    FountainCli.Credentials.delete_profile(profile)
    IO.puts("Profile '#{profile}' removed from ~/.fountain/credentials.")
  end

  # ── whoami ───────────────────────────────────────────────

  defp whoami(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [profile: :string])
    profile = FountainCli.Credentials.profile_name(opts)
    api_opts = [profile: profile]

    case FountainCli.Api.get("/auth/me", api_opts) do
      {:ok, %{"data" => user}} ->
        IO.puts("email: #{user["email"]}")
        IO.puts("role:  #{user["role"]}")

      {:error, {401, _}} ->
        FountainCli.die(
          "not authenticated for profile '#{profile}'. " <>
            "Run `fountain auth login --profile #{profile}`."
        )

      {:error, e} ->
        FountainCli.die(inspect(e))
    end
  end

  # ── I/O helpers ────────────────────────────────────────────

  defp prompt(label) do
    IO.write(label)
    IO.gets("") |> String.trim()
  end

  defp prompt_password(label) do
    IO.write(label)
    tty_echo_off()
    password = IO.gets("") |> String.trim()
    tty_echo_on()
    IO.puts("")
    password
  end

  # Best-effort echo suppression via stty. No-op when stty is unavailable
  # (e.g., in a non-interactive pipe or on Windows).
  defp tty_echo_off, do: :os.cmd(~c"stty -echo 2>/dev/null; true")
  defp tty_echo_on, do: :os.cmd(~c"stty echo 2>/dev/null; true")
end
