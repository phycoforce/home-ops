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
# Read-only: it only lists pods and reads pods/log in this namespace (rbac.yaml).
set -u

API="https://kubernetes.default.svc"
SA="/var/run/secrets/kubernetes.io/serviceaccount"
NS="$(cat "${SA}/namespace")"
CA="${SA}/ca.crt"
SELECTOR="app.kubernetes.io/name%3Dpalworld"      # url-encoded '=' ; matches the game pod
OUT="/gamelog/palworld.log"
WINDOW="${GAMELOG_WINDOW_SECONDS:-600}"            # how much recent log to keep (10 min)
INTERVAL="${GAMELOG_INTERVAL_SECONDS:-10}"         # snapshot cadence

log() { echo "[relay] $*"; }

log "start ns=${NS} selector=${SELECTOR} window=${WINDOW}s interval=${INTERVAL}s"
last=""

while true; do
  # Re-read the token each loop: the projected ServiceAccount token rotates.
  TOKEN="$(cat "${SA}/token")"

  # Resolve the current game pod (name changes on restart). 2>&1 so TLS/conn
  # errors land in the payload we log on failure.
  pods="$(curl -sS --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
    "${API}/api/v1/namespaces/${NS}/pods?labelSelector=${SELECTOR}" 2>&1)"
  POD="$(printf '%s' "${pods}" | grep -o '"name":"[^"]*"' | head -n1 | cut -d'"' -f4)"

  if [ -z "${POD}" ]; then
    log "no game pod resolved; api said: $(printf '%s' "${pods}" | tr '\n' ' ' | head -c 200)"
    sleep "${INTERVAL}"; continue
  fi

  # Snapshot the last WINDOW seconds of the game pod's stdout. Capture the HTTP
  # code so a 403/401 (RBAC) isn't silently written over the good file.
  code="$(curl -sS --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
    -o /gamelog/.new -w '%{http_code}' \
    "${API}/api/v1/namespaces/${NS}/pods/${POD}/log?sinceSeconds=${WINDOW}" 2>/dev/null)"

  if [ "${code}" = "200" ]; then
    mv /gamelog/.new "${OUT}"
    if [ "${POD}|${code}" != "${last}" ]; then
      log "ok pod=${POD} http=${code} bytes=$(wc -c < "${OUT}" 2>/dev/null || echo '?')"
      last="${POD}|${code}"
    fi
  else
    log "log fetch failed pod=${POD} http=${code}: $(tr '\n' ' ' < /gamelog/.new 2>/dev/null | head -c 200)"
  fi

  sleep "${INTERVAL}"
done
