"""Tool schemas — what the Hermes model sees."""

_CONV_ID = {
    "type": "string",
    "description": "The Fountain conversation id (returned by fountain_run).",
}
_TIMEOUT = {
    "type": "integer",
    "description": (
        "Seconds to wait for the turn before returning with done=false. "
        "Defaults to the plugin's default_timeout_seconds (300). Keep it under Hermes's tool deadline; "
        "call fountain_wait to keep waiting."
    ),
}
_WAIT = {
    "type": "boolean",
    "description": "Wait for the turn to finish (default true). false returns immediately with the conversation id.",
    "default": True,
}

FOUNTAIN_AGENTS = {
    "name": "fountain_agents",
    "description": (
        "List the Fountain agents on the configured account — each is a named, sandboxed coding agent "
        "(runtime + model + environment) you can run with fountain_run. Call this first when the user "
        "names an agent you have not seen, or asks what agents exist."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "search": {"type": "string", "description": "Optional substring filter on agent name."},
        },
    },
}

FOUNTAIN_RUN = {
    "name": "fountain_run",
    "description": (
        "Delegate a task to a Fountain agent. Provisions a fresh sandbox for that agent, sends the prompt "
        "as turn 1, and (by default) waits for the agent's answer. Use it to hand off work that should run "
        "in an isolated sandbox with its own credentials — a code change in a repo the agent's environment "
        "clones, a long investigation, or fanning a task out across several agents (call it once per agent "
        "with wait=false, then fountain_wait each). Returns the conversation_id (keep it: fountain_send "
        "continues the same conversation, and the sandbox remembers everything so far) plus the agent's "
        "output. If done=false the turn is still running — call fountain_wait."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "agent": {"type": "string", "description": "Fountain agent name or id (see fountain_agents)."},
            "prompt": {"type": "string", "description": "The task for the agent. Be complete: it has no other context."},
            "vault": {
                "type": "string",
                "description": "Optional vault name or id whose secrets override the environment's for this conversation.",
            },
            "environment": {
                "type": "string",
                "description": "Optional environment name or id to provision from instead of the agent's default (must be allowed on the agent).",
            },
            "wait": _WAIT,
            "timeout_seconds": _TIMEOUT,
        },
        "required": ["agent", "prompt"],
    },
}

FOUNTAIN_SEND = {
    "name": "fountain_send",
    "description": (
        "Send a follow-up prompt to an existing Fountain conversation (turn 2+). The agent's session "
        "resumes in the same sandbox with everything from earlier turns. Waits for the answer by default."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "conversation_id": _CONV_ID,
            "prompt": {"type": "string", "description": "The follow-up prompt."},
            "wait": _WAIT,
            "timeout_seconds": _TIMEOUT,
        },
        "required": ["conversation_id", "prompt"],
    },
}

FOUNTAIN_WAIT = {
    "name": "fountain_wait",
    "description": (
        "Keep waiting on a Fountain conversation's current turn and collect its output. Call this after "
        "fountain_run / fountain_send returned done=false, or after starting with wait=false. Returns the "
        "text the agent produced since you last looked, and done=true once the turn finished."
    ),
    "parameters": {
        "type": "object",
        "properties": {"conversation_id": _CONV_ID, "timeout_seconds": _TIMEOUT},
        "required": ["conversation_id"],
    },
}

FOUNTAIN_STATUS = {
    "name": "fountain_status",
    "description": (
        "Show a Fountain conversation: lifecycle status (pending, running, idle, failed, terminated), "
        "runtime, and its turns with their statuses. Cheap; does not wait."
    ),
    "parameters": {
        "type": "object",
        "properties": {"conversation_id": _CONV_ID},
        "required": ["conversation_id"],
    },
}

FOUNTAIN_CONVERSATIONS = {
    "name": "fountain_conversations",
    "description": "List the account's Fountain conversations (most recent first), by default only ones that are still alive.",
    "parameters": {
        "type": "object",
        "properties": {
            "active_only": {"type": "boolean", "description": "Hide failed/terminated conversations (default true).", "default": True},
            "limit": {"type": "integer", "description": "Max conversations to return (default 20).", "default": 20},
        },
    },
}

FOUNTAIN_TERMINATE = {
    "name": "fountain_terminate",
    "description": (
        "End a Fountain conversation and destroy its sandbox. Do this when the delegated work is finished "
        "and no follow-up is expected; idle conversations are also reclaimed by Fountain on their own."
    ),
    "parameters": {
        "type": "object",
        "properties": {"conversation_id": _CONV_ID},
        "required": ["conversation_id"],
    },
}

ALL = [
    FOUNTAIN_AGENTS,
    FOUNTAIN_RUN,
    FOUNTAIN_SEND,
    FOUNTAIN_WAIT,
    FOUNTAIN_STATUS,
    FOUNTAIN_CONVERSATIONS,
    FOUNTAIN_TERMINATE,
]
