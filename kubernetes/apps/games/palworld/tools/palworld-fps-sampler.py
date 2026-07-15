#!/usr/bin/env python3
"""Server-side FPS history sampler for the Palworld Server Dashboard.

The dashboard's FPS histogram reads a rolling ring of samples maintained by
this script — NOT collected in the browser. That means the history is always
populated for the full window (default: the last hour) even when nobody has
the panel open, hidden browser tabs can't thin the data out, and server
downtime shows up as an honest gap instead of an interpolated line.

Run it as a sidecar container (see docker-compose.yml) or as a systemd
service on the game host (see palworld-fps-sampler.service.example).

Configuration (environment variables):
  PALWORLD_REST_URL        Base URL of the Palworld REST API
                           (default: http://127.0.0.1:8212)
  PALWORLD_ADMIN_PASSWORD  The game's REST AdminPassword (required;
                           PALWORLD_REAL_ADMIN_PASSWORD is an accepted alias)
  FPS_HISTORY_FILE         Ring file path, shared with the dashboard's
                           PALWORLD_FPS_HISTORY_FILE
                           (default: /run/palworld-metrics/fps-history.json)
  FPS_SAMPLE_SECONDS       Poll cadence in seconds (default 5, clamped 1-60)
  FPS_WINDOW_MINUTES       History window in minutes (default 60, clamped 5-1440)
  FPS_SANE_MAX             Discard samples above this fps as invalid (default 65).
                           Palworld's engine frame limiter caps serverfps at 60,
                           but /metrics briefly reports the free-running tick
                           (1000+) while the world is still loading after a
                           restart; one such sample blows out the histogram's
                           auto-scaled axis. Raise only if you deliberately raise
                           the server frame cap.

Behavior notes:
  - Writes are atomic (tmp file + rename): the dashboard never reads a torn file.
  - The ring is pruned to the window on every write and capped in sample count.
  - REST unreachable (server stopped/restarting) => nothing is appended; the
    dashboard renders that span as a gap. The script keeps polling and logs
    only on state transitions, so logs stay quiet.
  - Existing ring data is reloaded on startup, so restarting the sampler does
    not wipe the window.
"""
import base64
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request


def env_int(name: str, default: int, lo: int, hi: int) -> int:
    try:
        return max(lo, min(hi, int(os.environ.get(name, ""))))
    except ValueError:
        return default


REST_URL = os.environ.get("PALWORLD_REST_URL", "http://127.0.0.1:8212").rstrip("/")
API_METRICS = f"{REST_URL}/v1/api/metrics"
PASSWORD = (
    os.environ.get("PALWORLD_ADMIN_PASSWORD")
    or os.environ.get("PALWORLD_REAL_ADMIN_PASSWORD")
    or ""
)
OUT_FILE = os.environ.get("FPS_HISTORY_FILE", "/run/palworld-metrics/fps-history.json")
TMP_FILE = os.path.join(os.path.dirname(OUT_FILE) or ".", f".{os.path.basename(OUT_FILE)}.tmp")

CADENCE_S = env_int("FPS_SAMPLE_SECONDS", 5, 1, 60)
WINDOW_MS = env_int("FPS_WINDOW_MINUTES", 60, 5, 1440) * 60 * 1000
FPS_SANE_MAX = env_int("FPS_SANE_MAX", 65, 1, 100000)
MAX_SAMPLES = WINDOW_MS // (CADENCE_S * 1000) + 1
HTTP_TIMEOUT_S = 4

_running = True


def _stop(signum, frame):
    global _running
    _running = False


def log(msg: str) -> None:
    print(msg, flush=True)


def build_request() -> urllib.request.Request:
    token = base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
    return urllib.request.Request(
        API_METRICS,
        headers={"Accept": "application/json", "Authorization": f"Basic {token}"},
    )


def load_existing() -> list:
    try:
        with open(OUT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        samples = data.get("samples", [])
        if isinstance(samples, list):
            return [
                s for s in samples
                if isinstance(s, dict)
                and isinstance(s.get("timestamp"), (int, float))
                and isinstance(s.get("fps"), (int, float))
            ]
    except (OSError, ValueError):
        pass
    return []


def prune(samples: list, now_ms: int) -> list:
    return [s for s in samples if now_ms - s["timestamp"] <= WINDOW_MS][-MAX_SAMPLES:]


def write_ring(samples: list, now_ms: int) -> None:
    payload = {
        "updatedAt": now_ms,
        "windowMs": WINDOW_MS,
        "cadenceMs": CADENCE_S * 1000,
        "samples": samples,
    }
    os.makedirs(os.path.dirname(OUT_FILE) or ".", exist_ok=True)
    with open(TMP_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"))
    os.chmod(TMP_FILE, 0o644)
    os.replace(TMP_FILE, OUT_FILE)


def main() -> int:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    if not PASSWORD:
        log("ERROR: PALWORLD_ADMIN_PASSWORD (or PALWORLD_REAL_ADMIN_PASSWORD) is not set")
        return 1

    samples = load_existing()
    log(
        f"palworld-fps-sampler: started (target {API_METRICS}, "
        f"loaded {len(samples)} existing samples, cadence {CADENCE_S}s, "
        f"window {WINDOW_MS // 60000}min -> {OUT_FILE})"
    )

    state = "init"  # init | ok | down | unauthorized
    start = time.monotonic()
    tick = 0

    while _running:
        now_ms = int(time.time() * 1000)
        new_state = state
        try:
            with urllib.request.urlopen(build_request(), timeout=HTTP_TIMEOUT_S) as resp:
                metrics = json.load(resp)
            fps = metrics.get("serverfps")
            if isinstance(fps, (int, float)) and fps > FPS_SANE_MAX:
                # Never drop silently — log each discard so real anomalies can't hide.
                log(f"DROP: serverfps={fps} > FPS_SANE_MAX={FPS_SANE_MAX} "
                    "(boot-window artifact) — sample discarded")
                new_state = "ok"
            elif isinstance(fps, (int, float)):
                samples.append({"timestamp": now_ms, "fps": fps})
                samples = prune(samples, now_ms)
                write_ring(samples, now_ms)
                new_state = "ok"
            else:
                log(f"WARN: /metrics response missing serverfps: {str(metrics)[:200]}")
        except urllib.error.HTTPError as e:
            new_state = "unauthorized" if e.code == 401 else "down"
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, ValueError):
            new_state = "down"  # server stopped / REST unreachable — honest gap

        if new_state != state:
            if new_state == "ok":
                log("REST reachable — sampling" if state == "init" else "REST reachable — sampling resumed")
            elif new_state == "down":
                log("REST unreachable (server down?) — sampling paused, gap will show in history")
            elif new_state == "unauthorized":
                log("REST 401 — check PALWORLD_ADMIN_PASSWORD; retrying")
            state = new_state

        # Monotonic alignment: no drift accumulation across ticks.
        tick += 1
        next_at = start + tick * CADENCE_S
        delay = next_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            # Fell behind (suspend/stall) — realign instead of burst-firing.
            tick = int((time.monotonic() - start) / CADENCE_S)

    log("palworld-fps-sampler: stopping (signal)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
