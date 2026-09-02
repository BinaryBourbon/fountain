defmodule Fountain.Run do
  @moduledoc """
  A running turn. Work starts immediately and events are broadcast to every consumer.

  The run server is owned by the process that created the handle and is cleaned up when that
  process exits. Pass the handle to consumers while its owner remains alive.
  """
  alias Fountain.{Error, HTTP}
  defstruct [:server, :http]

  def new(http, plan, opts \\ []) when is_function(plan, 0) do
    {:ok, server} = Fountain.Run.Server.start({self(), http, plan, opts})
    %__MODULE__{server: server, http: http}
  end

  @doc "Waits for the completed turn."
  def await(%__MODULE__{server: server}), do: GenServer.call(server, :await, :infinity)

  def await!(run) do
    case await(run) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Streams atom-keyed run events; multiple consumers receive the same underlying run."
  def stream(%__MODULE__{server: server}) do
    Stream.resource(fn -> subscribe(server) end, &next/1, &unsubscribe/1)
  end

  def text_stream(run),
    do: run |> stream() |> Stream.filter(&(&1.type == :text)) |> Stream.map(& &1.text)

  def cancel(%__MODULE__{server: server}), do: GenServer.call(server, :cancel)

  def conversation_id(run),
    do: with({:ok, conversation} <- conversation(run), do: {:ok, conversation["id"]})

  def url(run),
    do:
      with(
        {:ok, conversation} <- conversation(run),
        do: {:ok, Fountain.Config.conversation_url(conversation["id"], run.http.config)}
      )

  def conversation(%__MODULE__{server: server}),
    do: GenServer.call(server, :conversation, :infinity)

  def cursor(%__MODULE__{server: server}), do: GenServer.call(server, :cursor)

  def answer(run, request_id, option_id),
    do:
      with(
        {:ok, id} <- conversation_id(run),
        do:
          void(
            HTTP.request(
              run.http,
              "POST",
              "/api/conversations/#{id}/requests/#{escape(request_id)}",
              body: %{"option_id" => option_id}
            )
          )
      )

  def interrupt(run),
    do:
      with(
        {:ok, id} <- conversation_id(run),
        do: void(HTTP.request(run.http, "POST", "/api/conversations/#{id}/interrupt"))
      )

  def terminate(run),
    do:
      with(
        {:ok, id} <- conversation_id(run),
        do: void(HTTP.request(run.http, "POST", "/api/conversations/#{id}/terminate"))
      )

  defp subscribe(server) do
    subscription_ref = make_ref()

    case GenServer.call(server, {:subscribe, self(), subscription_ref}) do
      {:live, events} ->
        %{server: server, subscription_ref: subscription_ref, queue: events, done: false}

      {:done, events, completion} ->
        %{
          server: server,
          subscription_ref: subscription_ref,
          queue: events,
          done: completion
        }
    end
  end

  defp next(%{queue: [event | rest]} = state), do: {[event], %{state | queue: rest}}
  defp next(%{done: {:ok, _}} = state), do: {:halt, state}
  defp next(%{done: {:error, error}}), do: raise(error)

  defp next(state) do
    receive do
      {:fountain_run, server, subscription_ref, {:event, event}}
      when server == state.server and subscription_ref == state.subscription_ref ->
        {[event], state}

      {:fountain_run, server, subscription_ref, {:done, completion}}
      when server == state.server and subscription_ref == state.subscription_ref ->
        next(%{state | done: completion})
    end
  end

  defp unsubscribe(%{server: server, subscription_ref: subscription_ref}) do
    if Process.alive?(server) do
      try do
        GenServer.call(server, {:unsubscribe, subscription_ref})
      catch
        :exit, _ -> :ok
      end
    end

    drain_subscription(server, subscription_ref)
  end

  defp drain_subscription(server, subscription_ref) do
    receive do
      {:fountain_run, ^server, ^subscription_ref, _message} ->
        drain_subscription(server, subscription_ref)
    after
      0 -> :ok
    end
  end

  defp void({:ok, _}), do: :ok
  defp void(error), do: error
  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end

defmodule Fountain.Run.Server do
  @moduledoc false
  use GenServer
  alias Fountain.{Config, Error, HTTP, RunResult, SSE, TurnFollower}

  def start(args), do: GenServer.start(__MODULE__, args)

  @impl true
  def init({owner, http, plan, opts}) do
    send(self(), :start)
    owner_monitor = Process.monitor(owner)

    {:ok,
     %{
       http: http,
       plan: plan,
       opts: opts,
       worker: nil,
       events: [],
       subscribers: %{},
       completion: nil,
       conversation: nil,
       cursor: 0,
       awaiters: [],
       open_waiters: [],
       owner_monitor: owner_monitor
     }}
  end

  @impl true
  def handle_info(:start, state) do
    server = self()
    worker = spawn(fn -> execute(server, state.http, state.plan, state.opts) end)
    {:noreply, %{state | worker: worker}}
  end

  def handle_info({:opened, conversation, cursor}, state) do
    Enum.each(state.open_waiters, &GenServer.reply(&1, {:ok, conversation}))
    {:noreply, %{state | conversation: conversation, cursor: cursor, open_waiters: []}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:event, event}, state) do
    Enum.each(state.subscribers, fn {subscription_ref, pid} ->
      send(pid, {:fountain_run, self(), subscription_ref, {:event, event}})
    end)

    cursor =
      case event do
        %{type: :event, event: %{"id" => id}} when is_integer(id) -> max(id, state.cursor)
        _ -> state.cursor
      end

    {:noreply, %{state | events: [event | state.events], cursor: cursor}}
  end

  def handle_info({:complete, _completion}, %{completion: completion} = state)
      when not is_nil(completion), do: {:noreply, state}

  def handle_info({:complete, completion}, state) do
    Enum.each(state.subscribers, fn {subscription_ref, pid} ->
      send(pid, {:fountain_run, self(), subscription_ref, {:done, completion}})
    end)

    Enum.each(state.awaiters, &GenServer.reply(&1, completion))

    if state.conversation == nil,
      do: Enum.each(state.open_waiters, &GenServer.reply(&1, completion))

    {:noreply, %{state | completion: completion, awaiters: [], open_waiters: [], worker: nil}}
  end

  @impl true
  def handle_call(:await, from, %{completion: nil} = state),
    do: {:noreply, %{state | awaiters: [from | state.awaiters]}}

  def handle_call(:await, _from, state), do: {:reply, state.completion, state}

  def handle_call(:conversation, from, %{conversation: nil, completion: nil} = state),
    do: {:noreply, %{state | open_waiters: [from | state.open_waiters]}}

  def handle_call(:conversation, _from, %{conversation: conversation} = state)
      when not is_nil(conversation), do: {:reply, {:ok, conversation}, state}

  def handle_call(:conversation, _from, state), do: {:reply, state.completion, state}
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  def handle_call({:subscribe, _pid, _subscription_ref}, _from, %{completion: completion} = state)
      when not is_nil(completion),
      do: {:reply, {:done, Enum.reverse(state.events), completion}, state}

  def handle_call({:subscribe, pid, subscription_ref}, _from, state),
    do:
      {:reply, {:live, Enum.reverse(state.events)},
       %{state | subscribers: Map.put(state.subscribers, subscription_ref, pid)}}

  def handle_call({:unsubscribe, subscription_ref}, _from, state),
    do: {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, subscription_ref)}}

  def handle_call(:cancel, _from, %{completion: completion} = state)
      when not is_nil(completion), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, state) do
    if state.worker, do: Process.exit(state.worker, :kill)

    error = %Error{
      message: "run waiting was cancelled; the turn continues in Fountain",
      kind: :timeout,
      conversation_id: state.conversation && state.conversation["id"]
    }

    send(self(), {:complete, {:error, error}})
    {:reply, :ok, %{state | worker: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.worker, do: Process.exit(state.worker, :kill)
    :ok
  end

  defp execute(server, http, plan, opts) do
    try do
      {conversation, turn_number, after_cursor} = plan.()
      send(server, {:opened, conversation, after_cursor})
      url = Config.conversation_url(conversation["id"], http.config)

      publish(server, %{
        type: :conversation,
        conversation_id: conversation["id"],
        conversation: conversation,
        url: url
      })

      result = follow(server, http, conversation, turn_number, after_cursor, url, opts)
      send(server, {:complete, {:ok, result}})
    rescue
      error -> send(server, {:complete, {:error, error}})
    catch
      kind, reason ->
        send(
          server,
          {:complete,
           {:error, %Error{message: Exception.format(kind, reason), kind: :connection}}}
        )
    end
  end

  defp follow(server, http, conversation, turn_number, after_cursor, url, opts) do
    follower = TurnFollower.new(turn_number)
    collect? = Keyword.get(opts, :collect_events, false)
    timeout = Keyword.get(opts, :timeout, 0)

    deadline =
      if is_integer(timeout) and timeout > 0, do: System.monotonic_time(:millisecond) + timeout

    stream =
      SSE.stream_events(http, conversation["id"],
        after: after_cursor,
        deadline: deadline,
        max_retries: Keyword.get(opts, :max_retries, 5),
        retry_delay: Keyword.get(opts, :retry_delay, 500)
      )

    reducer = fn event, {state, events, _} ->
      result =
        if deadline && remaining(deadline) == 0 do
          {:halt, {state, events, :timeout}}
        else
          publish(server, %{type: :event, event: event})
          {state, output} = TurnFollower.apply(state, event)
          Enum.each(output, &publish(server, &1))
          events = if collect?, do: [event | events], else: events

          cond do
            TurnFollower.finished?(state) ->
              {:halt, {state, events, nil}}

            may_end?(event) and current_status(http, conversation) in ~w(failed terminated) ->
              {:halt, {state, events, stage_reason(event)}}

            true ->
              {:cont, {state, events, nil}}
          end
        end

      {_control, accumulator} = result
      Process.put(:fountain_run_accumulator, accumulator)
      result
    end

    {follower, collected, failure} = reduce_stream(stream, {follower, [], nil}, reducer, deadline)

    if failure == :timeout do
      raise %Error{
        message:
          "Timed out waiting for turn #{turn_number}. The turn is still running — resume conversation #{conversation["id"]}.",
        kind: :timeout,
        conversation_id: conversation["id"],
        partial_text: TurnFollower.text(follower)
      }
    end

    status = current_status(http, conversation)
    state = follower.state || if(failure, do: :failed, else: :timeout)

    unless TurnFollower.finished?(follower),
      do: publish(server, %{type: :turn_end, state: state, exit_code: nil, reason: failure})

    %RunResult{
      conversation_id: conversation["id"],
      url: url,
      turn_number: turn_number,
      text: TurnFollower.text(follower),
      tools_used: TurnFollower.tools_used(follower),
      state: state,
      exit_code: follower.exit_code,
      reason: follower.reason || failure,
      status: status,
      events: if(collect?, do: Enum.reverse(collected))
    }
  end

  defp publish(server, event), do: send(server, {:event, event})

  defp current_status(http, conversation) do
    case HTTP.data(http, "GET", "/api/conversations/#{conversation["id"]}") do
      {:ok, fresh} when is_map(fresh) -> fresh["status"] || conversation["status"]
      _ -> conversation["status"]
    end
  end

  defp may_end?(%{"kind" => "stage", "stage" => stage, "state" => state}),
    do: stage != "turn" and (state == "failed" or stage in ~w(terminate sandbox))

  defp may_end?(_), do: false

  defp stage_reason(event) do
    meta =
      if is_map(event["data"]) do
        event["data"]
      else
        case Jason.decode(event["data"] || "") do
          {:ok, value} when is_map(value) -> value
          _ -> %{}
        end
      end

    reason = meta["message"] || meta["reason"]

    if is_binary(reason) and reason != "",
      do: "#{event["stage"]}/#{event["state"]}: #{reason}",
      else: "#{event["stage"]}/#{event["state"]}"
  end

  defp remaining(nil), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp reduce_stream(stream, initial, reducer, deadline) do
    Process.put(:fountain_run_accumulator, initial)
    Enum.reduce_while(stream, initial, reducer)
  rescue
    error ->
      if deadline && remaining(deadline) == 0 do
        {follower, events, _} = Process.get(:fountain_run_accumulator, initial)
        {follower, events, :timeout}
      else
        reraise error, __STACKTRACE__
      end
  after
    Process.delete(:fountain_run_accumulator)
  end
end
