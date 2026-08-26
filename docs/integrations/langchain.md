# LangChain and Deep Agents

[LangChain](https://github.com/langchain-ai/langchain) is the agent framework,
and [Deep Agents](https://github.com/langchain-ai/deepagents) is its harness
for an orchestrator that plans and delegates to subagents. Fountain fits
there as a **subagent**. The orchestrator plans. A Fountain agent does the
work in a sandbox of its own, with its own repositories and credentials, and
reports back once.

```
  Deep Agent (LangGraph)  ──task tool──▶  FountainAgent runnable  ──HTTPS──▶  Fountain  ──▶  sandbox
    plans, reads reports                    POST /v1/chat/completions             /v1        the Fountain agent
                                            X-Fountain-Thread: <thread_id>:<agent>
```

It rides on the [OpenAI-compatible API](openai-compatible.md), so it is
alpha, behind the `openai_compat` flag. There is no package to install from
us. One file, `fountain_langchain.py`, is the whole integration, and the
example ships it.

## At a glance

| | |
|---|---|
| Direction | Inbound. LangChain drives Fountain. |
| Talks over | OpenAI chat completions, at `POST /v1/chat/completions`. |
| Configured on | Your LangChain code. |
| Plugin | None. One Python file, in the example. |
| Credential | A Fountain API key, as the bearer token. |
| Scope | One LangGraph `thread_id` is one sandbox per Fountain agent. |
| Status | Alpha, with the endpoint under it. Read [Feature status](../reference/feature-status.md). |

## Set it up

Make an API key.

```bash
fountain keys create langchain
```

Clone the example and install it.

```bash
git clone https://github.com/BinaryBourbon/fountain
cd fountain/examples/deepagents-contractor
pip install -r requirements.txt
export FOUNTAIN_TOKEN=ftn_...
export ANTHROPIC_API_KEY=sk-ant-...      # the orchestrator's model, not Fountain's
```

Run it.

```bash
python main.py --list                                  # the agents on your account
python main.py -a reflex-1 -a pr-reviewer \
  "Ask pr-reviewer to review the open PRs on jhgaylor/rounds, then summarise."
```

The orchestrator is an ordinary model that returns tool calls. Each `-a` names a Fountain
agent it can delegate to. `--thread` keeps the same sandboxes on a second
run.

## Three shapes

`FountainAgent(name)` has three shapes. All three send one prompt, wait for
the turn, and return the text.

A **Deep Agents subagent**, for `create_deep_agent`.

```python
from deepagents import create_deep_agent
from fountain_langchain import FountainAgent

agent = create_deep_agent(
    model="anthropic:claude-sonnet-5",
    subagents=[
        FountainAgent("pr-reviewer").as_subagent(
            "Reviews and fixes pull requests. Its sandbox has the repository."
        ),
    ],
)
agent.invoke({"messages": [("user", "...")]}, {"configurable": {"thread_id": "t1"}})
```

A **tool**, for `create_agent` or for a loop of your own.

```python
from langchain.agents import create_agent

agent = create_agent(model="anthropic:claude-sonnet-5",
                     tools=[FountainAgent("pr-reviewer").as_tool()])
```

A **runnable**, for a graph of your own. The input and the output both hold
`messages`, which is the shape a Deep Agents subagent must have.

```python
runnable = FountainAgent("pr-reviewer").as_runnable()
```

## The thread

The thread key is what keeps a conversation in one sandbox. The runnable reads
the LangGraph `thread_id` from the ambient config and appends the agent's
name. Thus one Deep Agents thread holds one sandbox per Fountain agent,
across turns and across runs. Pass `thread="..."` to fix it yourself. Without
either, the `FountainAgent` makes one random key and keeps it.

A busy thread is a `409` with `Retry-After`. The runnable waits and sends
again. Fountain does not queue a second prompt behind a turn that is in
progress.

## Why not `ChatOpenAI`

`ChatOpenAI(base_url="https://your-fountain/v1", model="pr-reviewer")` does
work, and it is the wrong tool. Two reasons.

- A Fountain agent never emits `tool_calls`. Its tools ran in the sandbox
  and the result is in the text. A LangGraph agent loop needs a model that
  returns tool calls, so a Fountain agent cannot be the model in the loop. It
  is a leaf that returns one report, which is what a subagent is.
- `langchain-openai` drops `reasoning_content`, the field Fountain streams
  while a sandbox provisions. A first turn looks silent for a minute. The
  example uses the stock `openai` client and prints those stages to stderr.

## What it does not do

- A sandbox backend for Deep Agents. That protocol needs `execute` inside
  the sandbox, and Fountain's unit is a conversation, not a shell.
- A package on PyPI. The file is small enough to copy.

The example is
[`examples/deepagents-contractor`](https://github.com/BinaryBourbon/fountain/tree/main/examples/deepagents-contractor).
