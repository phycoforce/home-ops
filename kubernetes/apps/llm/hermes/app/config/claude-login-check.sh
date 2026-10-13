#!/bin/bash
# Claude login watchdog for hermes, run by a no-agent cron job: stdout goes to
# the Matrix home room verbatim and an empty stdout is a silent run. The init
# container copies it into /opt/data/scripts, the only place cron scripts load
# from. The job lives in /opt/data/cron and is created once, by hand:
#
#   kubectl -n llm exec deploy/hermes -c app -- hermes cron create "0 9 * * *" \
#     --no-agent --script claude-login-check.sh --deliver matrix \
#     --name claude-login-check
#
# A real one-turn request rather than `claude auth status`, which only reads
# the local credential file and still says "logged in" after the login has
# been revoked or has expired server-side.
set -u
# Hermes runs cron scripts with HOME=/opt/data/home (its per-profile home for
# subprocesses in a container), but the login lives under the pod's real
# HOME, where the gateway runs `claude` and `claude auth login` wrote it.
export HOME=/opt/data
cd /tmp || exit 1
if ! out=$(timeout 120 /opt/data/.local/bin/claude -p --model haiku --max-turns 1 \
  --tools '' --no-session-persistence 'Reply with the single word OK.' 2>&1 </dev/null); then
  printf 'Claude login check failed, so hermes cannot reach its models:\n\n%s\n\nLog in again with:\nkubectl -n llm exec -it deploy/hermes -c app -- claude auth login\n' \
    "$(printf '%s\n' "$out" | tail -n 5)"
fi
