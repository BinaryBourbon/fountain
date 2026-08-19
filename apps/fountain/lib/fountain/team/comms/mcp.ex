defmodule Fountain.Team.Comms.Mcp do
  @moduledoc """
  Server-side MCP tools that let a teammate use its email address and phone
  number (flag `team_comms`).

  The AgentMail and AgentPhone keys stay with Fountain; the teammate's sandbox
  calls a tool and Fountain performs the send or the read under its own key,
  scoped to this teammate's inbox and number. Every send is a tool call
  Fountain can see and audit.

  This is the pure protocol/tool layer, the same shape as `Fountain.Buzz.Mcp`:
  `handle/2` takes one JSON-RPC request map and a `ctx`, returns one response
  map (or `:noreply` for a notification). The transport and the `ctx`
  construction live in `FountainWeb.TeamCommsMcpController`.

  `ctx` fields:
    * `:contact` — the `%Fountain.Team.Contact{}` the tools act for
    * `:mail`    — the AgentMail client module (default
                   `Fountain.Team.Comms.AgentMail`), injectable for tests
    * `:phone`   — the AgentPhone client module (default
                   `Fountain.Team.Comms.AgentPhone`)
    * `:audit`   — optional `(tool_name, summary_map) -> any` called after a
                   successful send, for the audit trail
  """

  alias Fountain.Team.Contact

  # The MCP protocol revision we implement (Streamable HTTP transport).
  @protocol_version "2025-06-18"
  @server_info %{name: "fountain-comms", version: "1"}

  @default_list_limit 20
  @max_list_limit 100

  @doc "The tool catalogue advertised by `tools/list`, for this contact."
  def tools(%Contact{} = contact) do
    email_tools(contact) ++ phone_tools(contact) ++ [whoami_tool()]
  end

  defp email_tools(%Contact{} = c) do
    if Contact.email?(c) do
      [
        %{
          name: "email_send",
          description:
            "Send an email from your own address (#{c.email_address}). " <>
              "Use email_reply to answer a message you received.",
          inputSchema: %{
            type: "object",
            properties: %{
              to: %{
                type: "array",
                items: %{type: "string"},
                description: "Recipient addresses"
              },
              subject: %{type: "string"},
              text: %{type: "string", description: "Plain-text body"},
              cc: %{type: "array", items: %{type: "string"}},
              html: %{type: "string", description: "Optional HTML body"}
            },
            required: ["to", "subject", "text"]
          }
        },
        %{
          name: "email_reply",
          description:
            "Reply to an email in your inbox, in its thread. Give the message_id " <>
              "from email_list / email_get.",
          inputSchema: %{
            type: "object",
            properties: %{
              message_id: %{type: "string"},
              text: %{type: "string", description: "Plain-text body"},
              reply_all: %{type: "boolean", description: "Reply to every recipient"},
              html: %{type: "string"}
            },
            required: ["message_id", "text"]
          }
        },
        %{
          name: "email_list",
          description:
            "List the messages in your inbox (#{c.email_address}), newest first: " <>
              "sender, subject, timestamp, a preview and the message_id to read or reply with.",
          inputSchema: %{
            type: "object",
            properties: %{
              limit: %{type: "integer", description: "Max messages (default 20, max 100)"},
              unread_only: %{type: "boolean", description: "Only messages labelled unread"},
              after: %{
                type: "string",
                description: "ISO-8601 timestamp; only messages after it"
              },
              from: %{type: "string", description: "Only messages whose sender contains this"}
            }
          }
        },
        %{
          name: "email_get",
          description: "Read one email in full: headers and the text body.",
          inputSchema: %{
            type: "object",
            properties: %{message_id: %{type: "string"}},
            required: ["message_id"]
          }
        }
      ]
    else
      []
    end
  end

  defp phone_tools(%Contact{} = c) do
    if Contact.phone?(c) do
      [
        %{
          name: "sms_send",
          description: "Send a text message (SMS) from your own number (#{c.phone_number}).",
          inputSchema: %{
            type: "object",
            properties: %{
              to: %{type: "string", description: "Recipient phone number, E.164 preferred"},
              body: %{type: "string"}
            },
            required: ["to", "body"]
          }
        },
        %{
          name: "sms_list",
          description:
            "List the text messages on your number (#{c.phone_number}), newest first, " <>
              "both sent and received.",
          inputSchema: %{
            type: "object",
            properties: %{
              limit: %{type: "integer", description: "Max messages (default 20, max 100)"},
              after: %{
                type: "string",
                description: "ISO-8601 timestamp; only messages after it"
              }
            }
          }
        }
      ]
    else
      []
    end
  end

  defp whoami_tool do
    %{
      name: "my_contact_info",
      description: "Your own email address and phone number, to share with people.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  @doc "The `instructions` string `initialize` returns — who the teammate is."
  def instructions(%Contact{} = c) do
    [
      "You have your own contact details.",
      Contact.email?(c) && "Your email address is #{c.email_address}.",
      Contact.phone?(c) && "Your phone number is #{c.phone_number}.",
      Contact.phone?(c) && is_binary(c.prompt_from_number) &&
        "Texts from #{c.prompt_from_number} to your number reach you as messages; answer them with sms_send.",
      "Use the email_* and sms_* tools to send and read; nothing you write elsewhere is sent."
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join(" ")
  end

  @doc """
  Handle one JSON-RPC 2.0 request map against `ctx`.

  Returns a response map to send back, or `:noreply` for a notification (a
  request with no `id`), which per JSON-RPC gets no response.
  """
  def handle(%{"method" => method} = req, ctx) do
    id = Map.get(req, "id")

    if is_nil(id) and String.starts_with?(method, "notifications/") do
      :noreply
    else
      dispatch(method, id, Map.get(req, "params", %{}), ctx)
    end
  end

  def handle(_req, _ctx), do: error(nil, -32_600, "invalid request")

  defp dispatch("initialize", id, _params, ctx) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: @server_info,
      instructions: instructions(ctx.contact)
    })
  end

  defp dispatch("ping", id, _params, _ctx), do: result(id, %{})

  defp dispatch("tools/list", id, _params, ctx), do: result(id, %{tools: tools(ctx.contact)})

  defp dispatch("tools/call", id, %{"name" => name} = params, ctx) do
    call_tool(id, name, Map.get(params, "arguments", %{}) || %{}, ctx)
  end

  defp dispatch(_unknown, nil, _params, _ctx), do: :noreply

  defp dispatch(method, id, _params, _ctx) do
    error(id, -32_601, "method not found: #{method}")
  end

  # ── tools ──────────────────────────────────────────────────────────────────

  defp call_tool(id, "my_contact_info", _args, %{contact: c}) do
    ok(id, %{
      email: (Contact.email?(c) && c.email_address) || nil,
      phone: (Contact.phone?(c) && c.phone_number) || nil
    })
  end

  defp call_tool(id, "email_send", args, ctx) do
    with {:ok, c} <- email_contact(ctx),
         {:ok, to} <- require_addresses(args, "to"),
         {:ok, subject} <- require_arg(args, "subject"),
         {:ok, text} <- require_arg(args, "text") do
      body =
        %{"to" => to, "subject" => subject, "text" => text}
        |> put_present("cc", addresses(args["cc"]))
        |> put_present("html", present(args["html"]))

      case mail(ctx).send_message(c.email_inbox_id, body) do
        {:ok, %{"message_id" => mid} = resp} ->
          audit(ctx, "email_send", %{"recipients" => length(to)})
          ok(id, %{message_id: mid, thread_id: resp["thread_id"]})

        {:ok, other} ->
          ok(id, other)

        {:error, reason} ->
          tool_error(id, "email_send failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "email_reply", args, ctx) do
    with {:ok, c} <- email_contact(ctx),
         {:ok, message_id} <- require_arg(args, "message_id"),
         {:ok, text} <- require_arg(args, "text") do
      body =
        %{"text" => text}
        |> put_present("html", present(args["html"]))
        |> put_present("reply_all", if(args["reply_all"] == true, do: true))

      case mail(ctx).reply_to_message(c.email_inbox_id, message_id, body) do
        {:ok, %{"message_id" => mid} = resp} ->
          audit(ctx, "email_reply", %{"reply_all" => args["reply_all"] == true})
          ok(id, %{message_id: mid, thread_id: resp["thread_id"]})

        {:ok, other} ->
          ok(id, other)

        {:error, reason} ->
          tool_error(id, "email_reply failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "email_list", args, ctx) do
    with {:ok, c} <- email_contact(ctx) do
      params =
        [limit: limit(args)]
        |> put_param(:labels, if(args["unread_only"] == true, do: ["unread"]))
        |> put_param(:after, present(args["after"]))
        |> put_param(:from, present(args["from"]))

      case mail(ctx).list_messages(c.email_inbox_id, params) do
        {:ok, %{"messages" => messages} = resp} ->
          ok(id, %{
            count: length(messages),
            next_page_token: resp["next_page_token"],
            messages: Enum.map(messages, &email_summary/1)
          })

        {:ok, other} ->
          ok(id, other)

        {:error, reason} ->
          tool_error(id, "email_list failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "email_get", args, ctx) do
    with {:ok, c} <- email_contact(ctx),
         {:ok, message_id} <- require_arg(args, "message_id") do
      case mail(ctx).get_message(c.email_inbox_id, message_id) do
        {:ok, message} -> ok(id, email_full(message))
        {:error, reason} -> tool_error(id, "email_get failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "sms_send", args, ctx) do
    with {:ok, c} <- phone_contact(ctx),
         {:ok, to} <- require_arg(args, "to"),
         {:ok, body} <- require_arg(args, "body") do
      payload = %{"number_id" => c.phone_number_id, "to_number" => to, "body" => body}

      case phone(ctx).send_message(payload) do
        {:ok, %{"id" => mid} = resp} ->
          audit(ctx, "sms_send", %{})
          ok(id, %{message_id: mid, status: resp["status"], channel: resp["channel"]})

        {:ok, other} ->
          ok(id, other)

        {:error, reason} ->
          tool_error(id, "sms_send failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "sms_list", args, ctx) do
    with {:ok, c} <- phone_contact(ctx) do
      params = [limit: limit(args)] |> put_param(:after, present(args["after"]))

      case phone(ctx).list_messages(c.phone_number_id, params) do
        {:ok, %{"data" => messages} = resp} ->
          ok(id, %{
            count: length(messages),
            has_more: resp["hasMore"] == true,
            messages: Enum.map(messages, &sms_summary/1)
          })

        {:ok, other} ->
          ok(id, other)

        {:error, reason} ->
          tool_error(id, "sms_list failed: #{describe(reason)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, name, _args, _ctx), do: tool_error(id, "unknown tool: #{name}")

  # ── shaping ────────────────────────────────────────────────────────────────

  defp email_summary(m) do
    %{
      message_id: m["message_id"],
      thread_id: m["thread_id"],
      from: m["from"],
      to: m["to"],
      subject: m["subject"],
      timestamp: m["timestamp"],
      labels: m["labels"],
      preview: m["preview"],
      attachments:
        Enum.map(m["attachments"] || [], &Map.take(&1, ["filename", "content_type", "size"]))
    }
  end

  defp email_full(m) do
    m
    |> email_summary()
    |> Map.merge(%{
      cc: m["cc"],
      reply_to: m["reply_to"],
      in_reply_to: m["in_reply_to"],
      text: m["extracted_text"] || m["text"] || strip_html(m["html"])
    })
  end

  defp sms_summary(m) do
    %{
      message_id: m["id"],
      from: m["from_"] || m["from"],
      to: m["to"],
      body: m["body"],
      direction: m["direction"],
      received_at: m["receivedAt"],
      status: m["status"]
    }
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) when is_binary(html),
    do: html |> String.replace(~r/<[^>]*>/, " ") |> String.trim()

  # ── helpers ────────────────────────────────────────────────────────────────

  defp mail(ctx), do: Map.get(ctx, :mail, Fountain.Team.Comms.AgentMail)
  defp phone(ctx), do: Map.get(ctx, :phone, Fountain.Team.Comms.AgentPhone)

  defp email_contact(%{contact: %Contact{} = c}) do
    if Contact.email?(c), do: {:ok, c}, else: {:error, "this teammate has no email address"}
  end

  defp phone_contact(%{contact: %Contact{} = c}) do
    if Contact.phone?(c), do: {:ok, c}, else: {:error, "this teammate has no phone number"}
  end

  defp audit(%{audit: audit}, tool, summary) when is_function(audit, 2), do: audit.(tool, summary)
  defp audit(_ctx, _tool, _summary), do: :ok

  defp require_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  defp require_addresses(args, key) do
    case addresses(Map.get(args, key)) do
      [] -> {:error, "missing required argument: #{key}"}
      list -> {:ok, list}
    end
  end

  defp addresses(nil), do: []

  defp addresses(v) when is_binary(v),
    do: v |> String.split(~r/[,;]\s*/, trim: true) |> Enum.map(&String.trim/1)

  defp addresses(v) when is_list(v),
    do: v |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp addresses(_), do: []

  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil

  defp limit(args) do
    case args["limit"] do
      n when is_integer(n) and n > 0 -> min(n, @max_list_limit)
      _ -> @default_list_limit
    end
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, _k, []), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp put_param(params, _k, nil), do: params
  defp put_param(params, k, v), do: Keyword.put(params, k, v)

  defp describe({:status, status, body}) when is_map(body),
    do:
      "HTTP #{status}: #{body["message"] || body["error"] || body["detail"] || Jason.encode!(body)}"

  defp describe({:status, status, body}), do: "HTTP #{status}: #{inspect(body)}"
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other)

  defp text(str), do: %{type: "text", text: to_string(str)}

  defp ok(id, payload), do: result(id, %{content: [text(Jason.encode!(payload))], isError: false})

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # A tool-level failure is a successful JSON-RPC response carrying isError, per
  # MCP — the model sees it and can recover, rather than the call itself failing.
  defp tool_error(id, message),
    do: result(id, %{content: [text(message)], isError: true})
end
