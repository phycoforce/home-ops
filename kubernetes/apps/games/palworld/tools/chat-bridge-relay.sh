#!/bin/sh
# Chat bridge relay (dashboard-pod sidecar).
#
# The dashboard reads in-game player chat by running `journalctl -u palworld` on
# the game host and parsing the `[CHAT]` lines out of its stdout. That only works
# when the panel is co-located with the game. In this split-pod k8s deployment the
# dashboard pod can't reach the game pod's stdout, so this sidecar streams the
# game pod's recent logs (which carry the `[CHAT]` and join/leave lines) via the
# Kubernetes API into a shared file, which a `journalctl` shim then cats for the
# app container.
#
# Read-only: it only lists pods and reads pods/log in this namespace (see rbac.yaml).
set -u

API="https://kubernetes.default.svc"
SA="/var/run/secrets/kubernetes.io/serviceaccount"
NS="$(cat "${SA}/namespace")"
CA="${SA}/ca.crt"
SELECTOR="app.kubernetes.io/name%3Dpalworld"      # url-encoded '=' ; matches the game pod
OUT="/gamelog/palworld.log"
WINDOW="${GAMELOG_WINDOW_SECONDS:-600}"            # how much recent log to keep (10 min)
INTERVAL="${GAMELOG_INTERVAL_SECONDS:-10}"         # snapshot cadence

while true; do
  # Re-read the token each loop: the projected ServiceAccount token rotates.
  TOKEN="$(cat "${SA}/token")"

  # Resolve the current game pod (name changes on restart). items[0].metadata.name
  # is the first "name" in the PodList response.
  POD="$(curl -sS --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
    "${API}/api/v1/namespaces/${NS}/pods?labelSelector=${SELECTOR}" 2>/dev/null \
    | grep -o '"name":"[^"]*"' | head -n1 | cut -d'"' -f4)"

  # Atomic snapshot of the last WINDOW seconds of the game pod's stdout.
  if [ -n "${POD}" ] && curl -sS --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
      "${API}/api/v1/namespaces/${NS}/pods/${POD}/log?sinceSeconds=${WINDOW}" \
      -o "/gamelog/.new" 2>/dev/null; then
    mv "/gamelog/.new" "${OUT}"
  fi

  sleep "${INTERVAL}"
done
