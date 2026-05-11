#!/usr/bin/env bash
## Trigger an alert by killing the app, wait for it to fire, then restore.
## Used in: deck §10 demo, lab Track 02 grading checkpoint.

set -euo pipefail

echo "Step 1: kill app container"
docker stop day23-app >/dev/null

echo "Step 2: wait 90s for ServiceDown alert to fire"
for i in {1..18}; do
  sleep 5
  alerts=$(curl -fsS http://localhost:9093/api/v2/alerts 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); print(sum(1 for x in a if x.get('status',{}).get('state')=='active'))" 2>/dev/null || echo 0)
  if [ "$alerts" -gt 0 ]; then
    echo "  alert fired (after ${i}*5s) — $alerts active"
    # Also check Prometheus-level
    curl -fsS http://localhost:9090/api/v1/alerts 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); [print('  FIRING:',a['labels'].get('alertname')) for a in d.get('data',{}).get('alerts',[]) if a['state']=='firing']" 2>/dev/null || true
    break
  fi
  # Also show Prometheus pending/firing state
  prom_state=$(curl -fsS http://localhost:9090/api/v1/alerts 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); alerts=d.get('data',{}).get('alerts',[]); sd=[a for a in alerts if a['labels'].get('alertname')=='ServiceDown']; print(sd[0]['state'] if sd else 'not_found')" 2>/dev/null || echo "unknown")
  echo "  no alert yet (${i}*5s) — prometheus: $prom_state"
done

echo "Step 3: restart app"
docker start day23-app >/dev/null

echo "Step 4: wait 60s for alert to resolve"
for i in {1..12}; do
  sleep 5
  alerts=$(curl -fsS http://localhost:9093/api/v2/alerts 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); print(sum(1 for x in a if x.get('status',{}).get('state')=='active'))" 2>/dev/null || echo 1)
  if [ "$alerts" -eq 0 ]; then
    echo "  alert resolved"
    exit 0
  fi
done

echo "alert did not resolve within 60s" >&2
exit 1
