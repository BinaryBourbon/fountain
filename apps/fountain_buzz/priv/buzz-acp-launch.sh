#!/bin/sh
# Port middleman for a hosted buzz-acp (Fountain ADR 0020 / gate #736; harness.ex).
#
# Why this exists: buzz-acp does not use its stdio to talk to the BEAM (it drives
# `fountain acp` over its own pipes and closes ours), so a bare spawn_executable
# port saw a false EOF and the harness restarted a still-live buzz-acp — leaking
# orphaned processes that stayed on the relay (the agent "online" after stop).
#
# This wrapper:
#   * holds the BEAM's stdin open (fd 3) regardless of what buzz-acp does, so the
#     port delivers exactly one true exit_status — when buzz-acp actually exits;
#   * on Port.close (BEAM closes the port), TERMs buzz-acp, and if it does not go
#     within the grace window, KILLs it — never orphaning it. buzz-acp SIGTERM-
#     cleans its own `fountain acp` child, and that child exits on stdio EOF if
#     buzz-acp is killed outright.

# A backgrounded `&` command has its stdin redirected to /dev/null, which would
# EOF the closer immediately; dup the real port pipe to fd 3 first.
exec 3<&0

"$@" &
child=$!

{
  cat <&3 >/dev/null 2>&1        # blocks until the BEAM closes the port
  kill -TERM "$child" 2>/dev/null
  i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$child" 2>/dev/null
} &
closer=$!

wait "$child"
status=$?

kill -TERM "$closer" 2>/dev/null
exit "$status"
