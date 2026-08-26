# deepagents-contractor

A [Deep Agent](https://github.com/langchain-ai/deepagents) that plans, and
Fountain agents that do the work. The orchestrator is an ordinary
tool-calling model; every Fountain agent you name becomes a subagent it can
delegate to with the built-in `task` tool. The subagent runs in its own
Fountain sandbox with the repositories and credentials it was hired with, and
returns one report.

`fountain_langchain.py` is the whole integration: a `FountainAgent` that is a
Deep Agents subagent (`as_subagent`), a LangChain tool (`as_tool`) or a bare
runnable (`as_runnable`), all over Fountain's
[OpenAI-compatible API](https://managoat.com/docs/integrations/openai-compatible)
with the stock `openai` client. Copy the file into your own project.

The endpoint is alpha, behind the `openai_compat` flag. On the hosted
platform ask for it on your account; self-hosted, set
`FEATURE_FLAGS_ON=openai_compat`.

```bash
pip install -r requirements.txt
export FOUNTAIN_TOKEN=ftn_...            # Account -> API keys, or `fountain keys create`
export ANTHROPIC_API_KEY=sk-ant-...      # the orchestrator's model (any langchain model string works: --model)

python main.py --list                    # the agents on your account
python main.py -a reflex-1 -a "pr-reviewer=Reviews and fixes PRs; its sandbox has the repo." \
  "Have pr-reviewer list the open PRs on jhgaylor/rounds and ask reflex-1 what day it is."
python main.py --thread yesterday ...    # same thread, same sandboxes, same memory
```

What to notice while it runs:

- Each delegation prints as `→ agent: task`, and each report as `← report`.
  Between them the sandbox's provisioning stages stream dim on stderr as
  `reasoning_content`; set `FOUNTAIN_QUIET=1` to hide them.
- The thread key is `<thread_id>:<agent>`, so one Deep Agents thread keeps
  one sandbox per Fountain agent, and a second `task` to the same agent lands
  in a sandbox that remembers the first.
- Why not `ChatOpenAI(base_url=...)`: a Fountain agent never returns
  `tool_calls`, so it cannot be the model inside the loop, and
  `langchain-openai` drops `reasoning_content`. It is a leaf, which is what a
  subagent is.
