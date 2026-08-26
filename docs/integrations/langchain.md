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

`FountainAgent(name)` has three shapes that treat the agent as a leaf, and a
fourth that makes it the model. The three send one prompt, wait for the turn,
and return the text.

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

## A Fountain agent as the model

The fourth shape puts a Fountain agent *inside* the loop. `create_agent`
needs a model that returns tool calls. Fountain returns the calls to the
tools that *you* pass on the request, and runs its own tools in the sandbox
([Your tools](openai-compatible.md#your-tools)). So `ChatOpenAI` with the
Fountain base URL is a model, and your LangChain tools run on your side.

```python
from langchain.agents import create_agent
from langchain_core.tools import tool
from fountain_langchain import FountainAgent

@tool
def lookup_order(id: str) -> str:
    """Find an order by id."""
    return orders[id]

agent = create_agent(model=FountainAgent("support").as_model(), tools=[lookup_order])
agent.invoke({"messages": [("user", "Where is order A-17?")]})
```

`as_model()` is `ChatOpenAI(base_url=..., model=...)` with the thread header
set, so the loop stays in one sandbox. Two caveats.

- `langchain-openai` drops `reasoning_content`, the field Fountain streams
  while a sandbox provisions. A first turn looks silent for a minute. The
  three shapes above use the stock `openai` client and print those stages to
  stderr.
- The agent's own tools do not come back as tool calls. Only the tools you
  pass do. A tool call that you do not answer in five minutes returns an
  error to the agent, and the turn continues.

## What it does not do

- A sandbox backend for Deep Agents. That protocol needs `execute` inside
  the sandbox, and Fountain's unit is a conversation, not a shell.
- A package on PyPI. The file is small enough to copy.

The example is
[`examples/deepagents-contractor`](https://github.com/BinaryBourbon/fountain/tree/main/examples/deepagents-contractor).
