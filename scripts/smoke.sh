#!/usr/bin/env bash
# End-to-end check: start the stack, run a container that looks like
# auth_service's and prints a JSON log line, then confirm Loki has it with the
# right labels and that Grafana loaded the data source and dashboard.
#
# Leaves the stack running (it's what you'd start anyway); pass --down to stop
# it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

request_id="smoke-$(date +%s)"
fake=blob-observability-smoke

cleanup() {
    docker rm -f "$fake" >/dev/null 2>&1 || true
    if [[ "${1:-}" == "--down" ]]; then docker compose down; fi
}
trap 'cleanup "${1:-}"' EXIT

docker network inspect blob-storage >/dev/null 2>&1 || docker network create blob-storage >/dev/null
docker compose up -d --quiet-pull

wait_for() {
    local what=$1 cmd=$2
    for _ in $(seq 1 60); do
        if eval "$cmd" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    echo "FAIL: $what"
    docker compose logs --tail 30
    exit 1
}

wait_for "Loki ready" "curl -fsS localhost:3100/ready"

# Labelled like auth_service's compose container, so Alloy picks it up.
docker rm -f "$fake" >/dev/null 2>&1 || true
docker run -d --name "$fake" \
    --label com.docker.compose.project=auth-service \
    --label com.docker.compose.service=auth \
    busybox sh -c "while true; do
        echo \"{\\\"time\\\":\\\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\\\",\\\"level\\\":\\\"warn\\\",\\\"service\\\":\\\"auth\\\",\\\"message\\\":\\\"login failed\\\",\\\"requestId\\\":\\\"$request_id\\\"}\";
        sleep 1; done" >/dev/null

query="{container=\"auth\", project=\"auth-service\", level=\"warn\"} | requestId=\"$request_id\""
wait_for "log line with labels in Loki" \
    "curl -fsS -G localhost:3100/loki/api/v1/query_range --data-urlencode 'query=$query' --data-urlencode 'since=5m' | jq -e '.data.result | length > 0'"
echo "Loki has the line: $query"

wait_for "Grafana up" "curl -fsS localhost:3001/api/health"
curl -fsS localhost:3001/api/datasources/uid/loki | jq -e '.type == "loki"' >/dev/null
curl -fsS localhost:3001/api/dashboards/uid/blob-system | jq -e '.dashboard.title' >/dev/null
echo "Grafana has the Loki data source and the dashboard"

# The dashboard's queries must parse and run.
jq -c '.panels[].targets[].expr' grafana/dashboards/blob-system.json | while read -r expr; do
    expr=$(jq -r . <<<"$expr" | sed 's/\$service/auth|blob|gateway|frontend/g; s/\$requestId//g; s/\$__auto/1m/g; s/\$__range/5m/g')
    curl -fsS -G localhost:3100/loki/api/v1/query_range --data-urlencode "query=$expr" \
        --data-urlencode 'since=5m' --data-urlencode 'step=60' >/dev/null \
        || { echo "FAIL: dashboard query rejected by Loki: $expr"; exit 1; }
done
echo "All dashboard queries run"

echo "ok"
