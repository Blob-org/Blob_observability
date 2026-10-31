#!/usr/bin/env bash
# Static checks, no running stack needed: compose file, Alloy config, Loki
# config, dashboard JSON. CI runs this; run it before pushing.
set -euo pipefail
cd "$(dirname "$0")/.."

alloy_image=$(sed -n 's/^ *image: \(grafana\/alloy:.*\)/\1/p' compose.yaml)
loki_image=$(sed -n 's/^ *image: \(grafana\/loki:.*\)/\1/p' compose.yaml)

echo "compose.yaml"
docker compose config --quiet

echo "alloy/config.alloy"
docker run --rm -v "$PWD/alloy:/cfg:ro" "$alloy_image" fmt /cfg/config.alloy >/dev/null

echo "loki/config.yaml"
docker run --rm -v "$PWD/loki:/cfg:ro" "$loki_image" \
    -config.file=/cfg/config.yaml -verify-config >/dev/null

for f in grafana/dashboards/*.json; do
    echo "$f"
    jq -e '.uid and .title and (.panels | length > 0)' "$f" >/dev/null
    # Every query must use the provisioned Loki data source.
    jq -e '[.panels[].targets[].datasource.uid] | all(. == "loki")' "$f" >/dev/null
done

echo "ok"
