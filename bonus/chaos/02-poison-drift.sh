#!/usr/bin/env bash
# Chaos Script 02 — Data: Poison drift reference dataset
# Usage: bash bonus/chaos/02-poison-drift.sh [--restore]
set -euo pipefail

DRIFT_DIR="04-drift-detection"
REF_FILE="$DRIFT_DIR/data/reference.parquet"
BACKUP_FILE="$DRIFT_DIR/data/reference.parquet.backup"
LOG_FILE="bonus/postmortems/incident-02-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

if [[ "${1:-}" == "--restore" ]]; then
  [[ ! -f "$BACKUP_FILE" ]] && { log "ERROR Backup not found"; exit 1; }
  log "ACTION  Restoring reference dataset"
  cp "$BACKUP_FILE" "$REF_FILE"
  uv run --with evidently==0.4.40 --with scikit-learn python3 "04-drift-detection/scripts/drift_detect.py" 2>&1 | tail -5 | while read -r l; do log "OUTPUT $l"; done
  log "ACTION  Restore complete"
  exit 0
fi

log "CHAOS   === Incident 02 START ==="
log "CHAOS   Failure mode: reference dataset replaced with +3sigma shifted distribution"

[[ ! -f "$BACKUP_FILE" ]] && cp "$REF_FILE" "$BACKUP_FILE" && log "CHAOS   Backup created"

python3 - <<'PYEOF'
import random
import pandas as pd
import numpy as np

random.seed(42)
np.random.seed(42)
ref_path = "04-drift-detection/data/reference.parquet"

df = pd.read_parquet(ref_path)

for col in df.columns:
    if pd.api.types.is_numeric_dtype(df[col]):
        df[col] = df[col] + 3.0 + np.random.normal(0, 0.3, size=len(df))
    else:
        # For non-numeric, maybe just append suffix to simulate shift
        df[col] = df[col].astype(str) + "_shifted"

df.to_parquet(ref_path)
print(f"[poison] Done — {len(df)} rows shifted +3sigma")
PYEOF

log "CHAOS   Poisoned. Running drift detect script..."
uv run --with evidently==0.4.40 --with scikit-learn python3 "04-drift-detection/scripts/drift_detect.py" 2>&1 | tail -5 | while read -r l; do log "OUTPUT $l"; done
log "CHAOS   Restore: bash bonus/chaos/02-poison-drift.sh --restore"
