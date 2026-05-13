# Plan: LLM-Generated Conversation Titles

**Date:** 2026-05-13

## What was done

Added LLM-generated short titles (≤50 chars) to conversations so the sidebar displays a meaningful label instead of truncating the raw first prompt.

## Files changed

1. **`apps/fountain/priv/repo/migrations/20260513100000_add_title_to_conversations.exs`** — New migration adding a nullable `:title` string column to the `conversations` table.

2. **`apps/fountain/lib/fountain/conversations/conversation.ex`** — Added `field :title, :string` to the schema and `:title` to the `cast/2` list in `changeset/2`.

3. **`apps/fountain/lib/fountain/conversations/title_generator.ex`** — New module that calls an LLM API to produce a 3–7 word title from the first turn's prompt. Credential priority: `claude_code_oauth_token` → `anthropic_api_key` → `openai_api_key` → `gemini_api_key`. Uses `Req.post/2` with a 10 s timeout; returns `{:ok, title}` or `{:error, reason}`.

4. **`apps/fountain/test/fountain/conversations/title_generator_test.exs`** — ExUnit tests covering all three providers, credential priority, sanitisation (quote stripping, first-line extraction, 50-char truncation), error paths (non-200, request failure), and the no-credentials case. Uses `Mimic` to stub `Req.post/2`.

5. **`apps/fountain/lib/fountain/conversations/conversation_server.ex`** — In `kick_turn/4`, after images are stored, a `Task.start/1` fires on `turn_number == 1` to call `TitleGenerator.generate/2` asynchronously. On success it re-fetches the conversation struct and calls `Conversations.update_conversation/2` (which already broadcasts the sidebar update via PubSub). Failures are logged as warnings.

6. **`apps/fountain/lib/fountain_web/live/conversations_live/index.ex`** — The "Task" column in the conversations table now renders `c.title` (bold, truncated, with the raw prompt as a hover tooltip) when a title is available, falling back to the previous raw-prompt display (muted styling) for untitled conversations.

## Design decisions

- **Async / best-effort:** title generation is fire-and-forget; a failure never blocks or crashes a turn.
- **First turn only:** title is generated once; subsequent turns do not overwrite it.
- **Credential priority mirrors the inference stack:** existing `state.inference_credentials` map is reused directly — no new credential storage.
- **50-char hard cap** enforced in `sanitize/1`; leading/trailing quotes and multi-line responses are cleaned up before slicing.
