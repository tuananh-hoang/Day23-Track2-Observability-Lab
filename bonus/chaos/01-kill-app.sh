#!/usr/bin/env bash
# Chaos Script 01 — Infra: Kill day23-app container
# Usage: bash bonus/chaos/01-kill-app.sh [--restore]
set -euo pipefail

SERVICE="app"
CONTAINER="day23-app"
LOG_FILE="bonus/postmortems/incident-01-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

if [[ "${1:-}" == "--restore" ]]; then
  log "ACTION  Restoring $SERVICE"
  docker compose start "$SERVICE"
  log "ACTION  Restore complete — watch Alertmanager for RESOLVED"
  exit 0
fi

log "CHAOS   === Incident 01 START ==="
log "CHAOS   Target: $CONTAINER (service=$SERVICE) | Failure mode: abrupt container stop"
log "CHAOS   Stopping container now..."
docker compose stop "$SERVICE"
log "CHAOS   Container stopped. ServiceDown alert fires trong ~60–90s"
log "CHAOS   Restore: bash bonus/chaos/01-kill-app.sh --restore"
