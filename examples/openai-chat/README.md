# openai-chat

A terminal chat with a Fountain agent, written against the stock `openai`
Python package and nothing else. It is the smallest possible client of the
[OpenAI-compatible API](https://managoat.com/docs/integrations/openai-compatible):
the model list is `GET /v1/models`, each turn is a streamed
`POST /v1/chat/completions`, and one header keeps the session in one sandbox.

The endpoint is alpha, behind the `openai_compat` flag. On the hosted
platform ask for it on your account; self-hosted, set
`FEATURE_FLAGS_ON=openai_compat`.

```bash
pip install openai
export OPENAI_BASE_URL=https://your-fountain/v1
export OPENAI_API_KEY=ftn_...            # Account -> API keys, or `fountain keys create`

python chat.py                           # pick an agent, then chat
python chat.py pr-reviewer               # or name one
python chat.py pr-reviewer --thread prs-today    # resume the same sandbox tomorrow
```

What to notice while it runs:

- The first message on a thread provisions a sandbox. Its stages stream in
  dim text as `reasoning_content`, so a quiet minute reads as progress and
  not as a hang. `--quiet` hides that and shows only what the agent said.
- The second message answers in seconds and remembers the first. The script
  keeps a transcript only because the request shape wants one; Fountain sends
  the newest user message and the sandbox remembers the rest.
- `--system "You are Ada."` is delivered once, with the first message of a new
  thread. Rerun with a new thread to change it.
- Every other OpenAI client works the same way. Put the base URL and key into
  Open WebUI or LibreChat, or in front of LiteLLM, and the same agents appear
  in the model picker.
