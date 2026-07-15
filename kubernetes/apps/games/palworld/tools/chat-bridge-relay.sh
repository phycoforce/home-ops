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
# Uses busybox wget (ghcr.io/home-operations/busybox). busybox can't validate the
# API server's TLS cert; that's acceptable for in-cluster traffic to
# kubernetes.default.svc, and the SA token is read-only pods/log in this namespace
# (rbac.yaml).
set -u

API="https://kubernetes.default.svc"
SA="/var/run/secrets/kubernetes.io/serviceaccount"
NS="$(cat "${SA}/namespace")"
SELECTOR="app.kubernetes.io/name%3Dpalworld"      # url-encoded '=' ; matches the game pod
OUT="/gamelog/palworld.log"
ERR="/tmp/wget.err"
WINDOW="${GAMELOG_WINDOW_SECONDS:-600}"            # how much recent log to keep (10 min)
INTERVAL="${GAMELOG_INTERVAL_SECONDS:-10}"         # snapshot cadence

log() { echo "[relay] $*"; }
# busybox wget always notes 'TLS certificate validation not implemented'; drop it
# so the real error (if any) is what we log.
werr() { grep -v 'certificate validation' "${ERR}" 2>/dev/null | tr '\n' ' ' | head -c 200; }

log "start ns=${NS} selector=${SELECTOR} window=${WINDOW}s interval=${INTERVAL}s"
last=""

while true; do
  # Re-read the token each loop: the projected ServiceAccount token rotates.
  TOKEN="$(cat "${SA}/token")"

  pods="$(wget -q -O - --no-check-certificate \
    --header="Authorization: Bearer ${TOKEN}" \
    "${API}/api/v1/namespaces/${NS}/pods?labelSelector=${SELECTOR}" 2>"${ERR}")"
  # The apiserver pretty-prints JSON for these clients (`"name": "…"` with a space
  # after the colon), so tolerate whitespace. items[0].metadata.name (the first
  # "name" in the list) is the game pod.
  POD="$(printf '%s' "${pods}" | grep -oE '"name":[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4)"

  if [ -z "${POD}" ]; then
    log "no game pod resolved; wget: $(werr)"
    sleep "${INTERVAL}"; continue
  fi

  # Snapshot the last WINDOW seconds of the game pod's stdout. busybox wget exits
  # non-zero on an HTTP error, so a 403 (RBAC) won't overwrite the good file.
  if wget -q -O /gamelog/.new --no-check-certificate \
      --header="Authorization: Bearer ${TOKEN}" \
      "${API}/api/v1/namespaces/${NS}/pods/${POD}/log?sinceSeconds=${WINDOW}" 2>"${ERR}"; then
    mv /gamelog/.new "${OUT}"
    if [ "${POD}" != "${last}" ]; then
      log "ok pod=${POD} bytes=$(wc -c < "${OUT}" 2>/dev/null || echo '?')"
      last="${POD}"
    fi
  else
    log "log fetch failed pod=${POD} wget: $(werr)"
  fi

  sleep "${INTERVAL}"
done
