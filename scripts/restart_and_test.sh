# Rebuild and restart the app container to apply the child span fix
docker compose build app
docker compose up -d app
echo "Waiting for app to be healthy..."
for i in {1..30}; do
  status=$(docker inspect --format='{{.State.Health.Status}}' day23-app 2>/dev/null || echo "none")
  if [ "$status" = "healthy" ]; then
    echo "App is healthy!"
    break
  fi
  echo "  attempt $i: status=$status"
  sleep 2
done

# Trigger a test request
echo ""
echo "Triggering test request..."
response=$(curl -s -X POST http://localhost:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"prompt":"hello world test trace","model":"llama3-mock"}' 2>/dev/null)
echo "Response: $response"

# Extract trace_id
trace_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('trace_id','N/A'))" 2>/dev/null)
echo "Trace ID: $trace_id"

# Wait for trace to propagate
echo ""
echo "Waiting 5s for trace to propagate to Jaeger..."
sleep 5

# Check Jaeger for the trace
echo ""
echo "Checking Jaeger..."
trace_json=$(curl -s "http://localhost:16686/api/traces?service=inference-api&limit=5" 2>/dev/null)
total=$(echo "$trace_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
complete=$(echo "$trace_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for t in d.get('data',[]) if any('predict' == s.get('operationName','') for s in t.get('spans',[]))))" 2>/dev/null)
echo "Total traces: $total"
echo "Traces with predict span: $complete"

if [ "$trace_id" != "N/A" ]; then
  echo ""
  echo "Checking specific trace $trace_id..."
  specific=$(curl -s "http://localhost:16686/api/traces/$trace_id" 2>/dev/null)
  spans=$(echo "$specific" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('data',[{}])[0]; print(len(t.get('spans',[])))" 2>/dev/null)
  ops=$(echo "$specific" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('data',[{}])[0]; print([s.get('operationName','') for s in t.get('spans',[])])" 2>/dev/null)
  echo "Spans in trace: $spans"
  echo "Operations: $ops"
fi
