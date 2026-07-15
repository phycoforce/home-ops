#!/bin/sh
# `journalctl` shim (app container, on PATH ahead of the system dirs).
#
# The dashboard invokes `journalctl -u palworld -o cat --since -3h --no-pager` to
# read player chat. There is no journald in the pod, so we ignore the args and
# emit the game pod's recent stdout that the chat-relay sidecar keeps fresh in the
# shared file. If the relay hasn't written yet, emit nothing (exit 0) so the app's
# chat route simply returns an empty list instead of erroring.
cat /gamelog/palworld.log 2>/dev/null || true
