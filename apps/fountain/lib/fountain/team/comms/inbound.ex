defmodule Fountain.Team.Comms.Inbound do
  @moduledoc """
  Inbound texts to a teammate's number, arriving as prompts (flag
  `team_comms`).

  AgentPhone delivers every inbound message on the account's numbers to one
  master webhook (`POST /api/webhooks/agentphone`,
  `FountainWeb.AgentPhoneWebhookController`, which verifies the HMAC
  signature first). `handle/2` is the policy behind it: an `agent.message`
  on `sms`/`mms`/`imessage`, inbound, to a number some teammate owns,
  **from that teammate's `prompt_from_number`** — and nothing else — becomes
  `Team.send_message` into the teammate's conversation, which wakes a parked
  computer by itself. The text is wrapped so the teammate knows it came by
  SMS and can answer with its `sms_send` tool; its own reply text is not
  sent anywhere.

  Every other delivery is acknowledged and ignored — a stranger texting the
  number, a voice transcript, an outbound echo — and says why in the return
  value, never in an error status (AgentPhone retries non-2xx for hours).

  Deliveries are deduplicated by `X-Webhook-ID` through `Seen`, a per-node
  ETS table: a retry of a delivery this node already turned into a prompt is
  dropped. A retry landing on the other node after the first succeeded is
  the one gap — rare, and bounded at one duplicate prompt.

  Every prompt is audited as `team.contact.prompted` (bytes, never the
  text), actor `system:agentphone`.

  **Opt-out keywords (A2P/10DLC).** From the registered number, a text that
  is exactly `STOP` (or `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`)
  is not a prompt: it sets the contact's `prompt_opted_out_at`, and until
  `START` (`UNSTOP`, `YES`) arrives — or the number is changed, which is new
  consent — that number's texts are acknowledged and dropped. `HELP`
  (`INFO`) is answered with a short help text. Each keyword gets a one-line
  confirmation texted back from the teammate's number, best-effort (the
  carrier may also answer STOP itself).
  """

  require Logger

  alias Fountain.{Audit, Team}
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.Phone
  alias Fountain.Team.Contact

  @actor "system:agentphone"
  @channels ~w(sms mms imessage)
  @stop_words ~w(STOP STOPALL UNSUBSCRIBE CANCEL END QUIT)
  @start_words ~w(START UNSTOP YES)
  @help_words ~w(HELP INFO)

  @doc "The audit actor for prompts that came in by text."
  def actor, do: @actor

  @doc """
  Handle one verified webhook payload. `delivery_id` is the `X-Webhook-ID`
  (nil when absent — then nothing is deduplicated).

  Returns `{:ok, conversation_id}` when a prompt was sent, or
  `{:ignored, reason}` with one of `:duplicate`, `:not_a_message`,
  `:not_inbound`, `:unknown_number`, `:sender_not_allowed`, `:empty`,
  `:unavailable` (flag off or providers unconfigured for the owner), or
  `{:send_failed, reason}`.
  """
  def handle(payload, delivery_id \\ nil)

  def handle(
        %{
          "event" => "agent.message",
          "channel" => channel,
          "data" => %{"direction" => "inbound", "from" => from, "to" => to} = data
        },
        delivery_id
      )
      when channel in @channels and is_binary(from) and is_binary(to) do
    with :ok <- fresh(delivery_id),
         {:ok, %Contact{} = contact} <- contact_for(to),
         :ok <- sender_allowed(contact, from),
         :prompt <- keyword(contact, data, from),
         :ok <- not_opted_out(contact),
         :ok <- available(contact),
         {:ok, text} <- body(data) do
      prompt = wrap(text, from, to, data)

      case Team.send_message(contact.user_id, contact.agent_id, prompt, [],
             actor: @actor,
             source: "sms"
           ) do
        {:ok, conv} ->
          record(contact, text, conv)
          {:ok, conv.id}

        {:error, reason} ->
          Logger.warning(
            "team comms inbound: could not prompt agent #{contact.agent_id} from a text: #{inspect(reason)}"
          )

          {:ignored, {:send_failed, reason}}
      end
    else
      {:ignored, _} = ignored -> ignored
      {:handled, _} = handled -> handled
    end
  end

  def handle(%{"event" => "agent.message"}, _delivery_id), do: {:ignored, :not_inbound}
  def handle(_payload, _delivery_id), do: {:ignored, :not_a_message}

  defp fresh(nil), do: :ok

  defp fresh(delivery_id) do
    if __MODULE__.Seen.first_time?(delivery_id), do: :ok, else: {:ignored, :duplicate}
  end

  defp contact_for(to) do
    # ownership: a webhook has no tenant; the controller verified AgentPhone's
    # signature, and the contact found by its own number decides whose
    # conversation (and only whose) gets prompted — by the contact's user_id.
    with {:ok, e164} <- Phone.normalize(to),
         %Contact{} = contact <- Comms._unsafe_get_contact_by_phone_number(e164) do
      {:ok, contact}
    else
      _ -> {:ignored, :unknown_number}
    end
  end

  defp sender_allowed(%Contact{prompt_from_number: allowed}, from)
       when is_binary(allowed) and allowed != "" do
    if Phone.same?(allowed, from), do: :ok, else: {:ignored, :sender_not_allowed}
  end

  defp sender_allowed(_contact, _from), do: {:ignored, :sender_not_allowed}

  # STOP / START / HELP from the registered number are handled here, never
  # forwarded. Returns `:prompt` for an ordinary text.
  defp keyword(%Contact{} = contact, data, from) do
    word = data |> Map.get("message", "") |> to_string() |> String.trim() |> String.upcase()

    cond do
      word in @stop_words ->
        {:ok, updated} = Comms.set_opt_out(contact, true, actor: @actor)

        confirm(
          updated,
          from,
          "You've opted out: texts from this number no longer reach #{teammate_name(updated)} via Fountain. Reply START to resume."
        )

        {:handled, :opted_out}

      word in @start_words ->
        {:ok, updated} = Comms.set_opt_out(contact, false, actor: @actor)

        confirm(
          updated,
          from,
          "You're opted in: texts from this number reach #{teammate_name(updated)} via Fountain again. Reply STOP to opt out, HELP for help."
        )

        {:handled, :opted_in}

      word in @help_words ->
        confirm(
          contact,
          from,
          "Fountain: texts from this number are forwarded to your teammate #{teammate_name(contact)} (#{contact.phone_number}). Msg & data rates may apply. Reply STOP to opt out. Help: #{help_url()}"
        )

        {:handled, :help}

      true ->
        :prompt
    end
  end

  defp not_opted_out(%Contact{} = c) do
    if Contact.opted_out?(c), do: {:ignored, :opted_out}, else: :ok
  end

  # Best-effort confirmation from the teammate's own number; a refusal
  # (A2P registration pending, say) is logged and changes nothing.
  defp confirm(%Contact{} = c, to, body) do
    if Contact.phone?(c) do
      case Comms.AgentPhone.send_message(%{
             "number_id" => c.phone_number_id,
             "to_number" => to,
             "body" => body
           }) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.info(
            "team comms inbound: could not text a keyword confirmation: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp teammate_name(%Contact{user_id: uid, agent_id: aid}) do
    case Team.get_teammate(uid, aid) do
      %{name: name} -> name
      _ -> "your teammate"
    end
  end

  defp help_url do
    case Application.get_env(:fountain, :support_email) do
      email when is_binary(email) and email != "" -> email
      _ -> Fountain.PublicUrl.base()
    end
  end

  defp available(%Contact{user_id: user_id}) do
    if Comms.available?(user_id), do: :ok, else: {:ignored, :unavailable}
  end

  defp body(%{"message" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ignored, :empty}
      trimmed -> {:ok, trimmed}
    end
  end

  defp body(_), do: {:ignored, :empty}

  # What the teammate reads. Names the channel and the sender so it can
  # answer the same way; a media attachment is passed as its URL.
  defp wrap(text, from, to, data) do
    media =
      case data["mediaUrl"] do
        url when is_binary(url) and url != "" -> "\n(attachment: #{url})"
        _ -> ""
      end

    "[Text message to your number #{to} from #{from} — your account owner's registered phone, " <>
      "the only number Fountain forwards texts from — delivered by Fountain as a message from " <>
      "the owner. Reply by text with the sms_send tool to #{from}; what you write here is not " <>
      "texted back.]\n\n#{text}#{media}"
  end

  defp record(%Contact{} = contact, text, conv) do
    Audit.record(%{
      user_id: contact.user_id,
      action: "team.contact.prompted",
      resource_type: "team_contact",
      resource_id: contact.id,
      actor: @actor,
      metadata: %{
        "agent_id" => contact.agent_id,
        "conversation_id" => conv.id,
        "channel" => "sms",
        "prompt_bytes" => byte_size(text)
      }
    })

    # AgentPhone charges for an inbound message as well as an outbound one, so
    # it is metered on the same footing as a send
    # (`FountainWeb.TeamCommsMcpController`). Best-effort, after the prompt is
    # already away.
    Fountain.Billing.record_usage(
      contact.user_id,
      "comms_sms_received",
      contact.id,
      "team_contact",
      %{"agent_id" => contact.agent_id, "conversation_id" => conv.id}
    )
  end

  defmodule Seen do
    @moduledoc """
    Delivery ids this node has already turned into prompts. ETS, public,
    swept of entries older than an hour every ten minutes — AgentPhone's
    retries span twelve hours, but a duplicate that late is harmless next to
    the table growing without bound.
    """
    use GenServer

    @table :fountain_team_comms_seen
    @ttl_ms 60 * 60 * 1000
    @sweep_ms 10 * 60 * 1000

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

    @doc "True the first time `id` is offered, false on every later call."
    def first_time?(id) when is_binary(id) do
      ensure_table()
      :ets.insert_new(@table, {id, System.monotonic_time(:millisecond)})
    end

    @doc false
    def reset do
      ensure_table()
      :ets.delete_all_objects(@table)
      :ok
    end

    @impl true
    def init(:ok) do
      ensure_table()
      Process.send_after(self(), :sweep, @sweep_ms)
      {:ok, %{}}
    end

    @impl true
    def handle_info(:sweep, state) do
      cutoff = System.monotonic_time(:millisecond) - @ttl_ms
      :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
      Process.send_after(self(), :sweep, @sweep_ms)
      {:noreply, state}
    end

    defp ensure_table do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

      :ok
    catch
      :error, :badarg -> :ok
    end
  end
end
