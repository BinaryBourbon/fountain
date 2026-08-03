defmodule Fountain.Conversations.ConversationServerRedactionTest do
  # #315: ConversationServer state holds plaintext tenant secrets, the raw
  # DEK, decrypted BYO inference credentials, the callback API key and the
  # platform Sprites token. Three leak vectors, each covered here:
  #
  #   1. A FunctionClauseError at a callback head embeds the full state in
  #      the exception message — format_status/1 cannot redact an exception
  #      message, so unknown calls/casts must not crash at the head.
  #   2. A crash inside a callback body produces a crash report whose state
  #      field feeds structured handlers (Sentry.LoggerHandler) —
  #      format_status/1 redacts it at the gen_server level.
  #   3. :sys.get_status (ops tooling, remote console) renders state through
  #      the same callback.
  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  @secret_env_value "sprite-env-secret-value-315"
  @dek_value "raw-tenant-dek-bytes-315"
  @inference_value "sk-ant-byo-credential-315"
  @callback_value "fnt_callback_key_315"
  @sprites_token "sprites-platform-token-315"

  defp start_server_with_secrets do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, ref, :alive} = start_server(conv)

    # Provisioning under stubs leaves most secret fields empty, so plant
    # realistic values through the server itself — whatever the state holds
    # at crash time is exactly what must come out redacted.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | sprite: %Sprites.Sprite{
            name: "test-sprite",
            client: %Sprites.Client{token: @sprites_token}
          },
          sprite_env: [{"MY_SECRET", @secret_env_value}, {"OTHER", "other-value-315"}],
          tenant_key: @dek_value,
          inference_credentials: %{"anthropic" => @inference_value},
          callback_token: @callback_value
      }
    end)

    {pid, ref}
  end

  defp refute_secrets(rendered) do
    refute rendered =~ @secret_env_value
    refute rendered =~ "other-value-315"
    refute rendered =~ @dek_value
    refute rendered =~ @inference_value
    refute rendered =~ @callback_value
    refute rendered =~ @sprites_token
  end

  test "unknown calls and casts do not crash at the callback head" do
    {pid, _ref} = start_server_with_secrets()

    log =
      capture_log(fn ->
        assert {:error, :unknown_call} = GenServer.call(pid, :no_such_call)
        GenServer.cast(pid, :no_such_cast)
        # Synchronize so the cast has been handled before asserting.
        _ = :sys.get_state(pid)
      end)

    assert Process.alive?(pid)
    assert log =~ "unexpected call"
    assert log =~ "unexpected cast"
    refute_secrets(log)
  end

  test "a crash inside a callback body does not leak secrets into the crash report" do
    {pid, ref} = start_server_with_secrets()

    # Corrupt a lifecycle field so the next :lifecycle_check raises deep in
    # the callback body — the unhandled-crash shape the issue describes.
    :sys.replace_state(pid, fn state ->
      %{state | sandbox_started_at: DateTime.utc_now(), last_activity_at: :corrupt}
    end)

    log =
      capture_log(fn ->
        send(pid, :lifecycle_check)
        assert_stopped(ref)
      end)

    assert log =~ "terminating"
    refute_secrets(log)
  end

  test "format_status redacts state for structured crash reports and :sys.get_status" do
    {pid, _ref} = start_server_with_secrets()

    rendered = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

    refute_secrets(rendered)

    # Key names survive so reports stay debuggable.
    assert rendered =~ "MY_SECRET"
    assert rendered =~ "[REDACTED]"
  end
end
