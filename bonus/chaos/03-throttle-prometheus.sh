#!/usr/bin/env bash
# Chaos Script 03 — Dependency: Network-disconnect Prometheus khỏi app
# Usage: bash bonus/chaos/03-throttle-prometheus.sh [--restore]
set -euo pipefail

PROMETHEUS_CONTAINER="day23-prometheus"
PROMETHEUS_SERVICE="prometheus"
APP_CONTAINER="day23-app"
LOG_FILE="bonus/postmortems/incident-03-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

detect_network() {
  docker inspect "$APP_CONTAINER" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
    2>/dev/null | head -1
}

NETWORK=$(detect_network)
[[ -z "$NETWORK" ]] && { log "ERROR Cannot detect network of $APP_CONTAINER"; exit 1; }

if [[ "${1:-}" == "--restore" ]]; then
  log "ACTION  Reconnecting $PROMETHEUS_CONTAINER to $NETWORK"
  docker network connect "$NETWORK" "$PROMETHEUS_CONTAINER" 2>/dev/null || docker compose start "$PROMETHEUS_SERVICE" 2>/dev/null || true
  log "ACTION  Restored. up{job=day23-app} sẽ về 1 trong ~30s"
  exit 0
fi

log "CHAOS   === Incident 03 START ==="
log "CHAOS   Failure mode: network partition Prometheus <-> app"
log "CHAOS   Network: $NETWORK"
docker network disconnect "$NETWORK" "$PROMETHEUS_CONTAINER"
log "CHAOS   Disconnected. up{job=day23-app} == 0 sau scrape interval tiếp theo"
log "CHAOS   Nếu alert patch đã deploy: TargetDown fires trong ~80s"
log "CHAOS   Nếu chưa patch: ServiceDown fires nhưng tên alert misleading"
log "CHAOS   Restore: bash bonus/chaos/03-throttle-prometheus.sh --restore"
