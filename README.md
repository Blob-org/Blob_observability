# Blob_observability

Local log stack for the Blob_storage system. Collects the JSON logs of auth_service, Blob_storage, Blob_api_gateway (and Blob_frontend's output) from Docker and shows them in Grafana, with a ready-made dashboard.

```
auth / blob / gateway / frontend containers ──stdout──▶ Docker
                                                          │  (read-only socket)
                                                          ▼
                                                   Grafana Alloy  ── parses JSON, adds labels
                                                          │
                                                          ▼
                                                        Loki (:3100, 7 days)
                                                          │
                                                          ▼
                                                      Grafana (:3001)
```

Nothing changes in the services: they keep logging to stdout, and Alloy picks up their containers by their Docker Compose labels. Start or restart this stack in any order.

## Requirements

- Docker with Compose
- The shared `blob-storage` network, which auth_service's stack creates. To run this stack on its own: `docker network create blob-storage`.

## Getting started

```bash
docker compose up -d
```

Open http://localhost:3001. The **Blob storage system** dashboard is the home page. There's no login: this is for local development only, so don't expose port 3001 on a shared or public machine.

Then start the other stacks as usual (see Blob_frontend's README) and use the app. Logs appear within a few seconds.

## The dashboard

| Panel | Shows |
| --- | --- |
| Gateway 502s | The gateway couldn't reach auth or blob, e.g. a stack isn't running. |
| Failed logins | Wrong password or unknown email. A spike can mean password guessing. |
| Failed MFA codes | Wrong or reused two-factor codes, and sign-ins that expired or ran out of tries at the code step. Many for one user can mean a lost phone, or someone with their password guessing codes. |
| Refresh token reuse | A rotated refresh token was used again, so auth_service revoked all that user's sessions. Can mean a stolen token. Should be 0. |
| Rate limited | Requests refused by the gateway's or auth_service's rate limit (login and the MFA code step). |
| Requests per second, Server errors (5xx), Latency p95 | Per service, from each service's `request` log line (`status`, `ms`). |
| Warnings and errors | Count per service and message. |
| Logs | The raw lines. Type a request id in **Request id** at the top to see only that request, across every service. |

**Following one request:** every response carries an `X-Request-Id` header. Copy it from the browser's DevTools (Network tab, response headers), paste it into **Request id**, and the logs panel shows that request's path through gateway, auth and blob.

The dashboard is provisioned from `grafana/dashboards/blob-system.json`. Changes made in the UI aren't saved. To keep a change, export the dashboard JSON (Share → Export) into that file.

## Querying logs yourself

In Grafana, open **Explore** and pick Loki. Each line has these labels:

| Label | Values |
| --- | --- |
| `project` | `auth-service`, `blob-service`, `api-gateway`, `blob-frontend` (the compose project) |
| `container` | `auth`, `blob`, `gateway`, `frontend` (the compose service) |
| `level` | `debug`, `info`, `warn`, `error` (JSON lines only) |

`requestId` is stored as structured metadata rather than a label, because a label per request would make Loki slow. You can still filter on it.

```logql
# Everything for one request, across services
{project=~".+"} | requestId="3f2c…"

# Errors in blob in the last hour, with fields parsed
{container="blob", level="error"} | json

# Slow requests (over 500 ms)
{container=~"auth|blob|gateway"} | json | message="request" | ms > 500

# Failed logins per minute
sum(count_over_time({container="auth"} | json | message="login failed" [1m]))

# Failed MFA codes per reason
sum by (reason) (count_over_time({container="auth"} | json | message="mfa failed" [1h]))
```

Without Grafana: `curl -G localhost:3100/loki/api/v1/query_range --data-urlencode 'query={container="auth"}' | jq`.

## Configuration

| File | What it does |
| --- | --- |
| `compose.yaml` | Loki, Alloy and Grafana. Image versions are pinned. |
| `alloy/config.alloy` | Which containers to read (by compose project), labels, JSON parsing. To include another stack, add its compose project name to the `keep` regex. |
| `loki/config.yaml` | Single-process Loki on local disk, 7-day retention (`retention_period`). |
| `grafana/provisioning/` | The Loki data source and the dashboard folder. |
| `grafana/dashboards/blob-system.json` | The dashboard. |

Alloy's own UI, at http://localhost:12345, shows the pipeline and which containers it's reading. It's useful when logs don't show up.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `network blob-storage declared as external, but could not be found` | Start auth_service's stack first, or `docker network create blob-storage`. |
| No logs from a service | Is it running under its usual compose project name (`docker compose ls`)? Alloy only reads `auth-service`, `blob-service`, `api-gateway` and `blob-frontend`. |
| Logs show, but there's no `level` label | The line isn't JSON. Older service versions log plain text, and so does the frontend. |
| Docker Desktop on Windows | The socket path differs. Mount `//var/run/docker.sock` instead. |

## Production

This stack is for development: no login, one Loki process on local disk. In production, keep the services the same (JSON to stdout) and send the logs to a managed backend:
- **AWS:** CloudWatch Logs, through the `awslogs` driver or ECS. Query with Logs Insights.
- **Elsewhere:** Grafana Cloud. The Alloy config here works with a `loki.write` endpoint and credentials, and the dashboard imports unchanged.

## Checks

| Command | What it does |
| --- | --- |
| `./scripts/validate.sh` | Checks compose, Alloy, Loki and the dashboard JSON. No running stack needed. |
| `./scripts/smoke.sh` | Starts the stack, runs a fake auth container that prints a JSON log line, and checks the line reaches Loki with the right labels, Grafana has the data source and dashboard, and every dashboard query runs. Add `--down` to stop the stack afterwards. |

CI runs both on every push.

**Security** (`.github/workflows/security.yml`, on every PR, on push to `main` and weekly): gitleaks checks the whole git history for secrets, and CodeQL analyses the scripts and the workflow files. Findings appear under the repo's **Security → Code scanning**. Dependabot (`.github/dependabot.yml`) opens weekly update PRs for the images in `compose.yaml` and the GitHub Actions. It skips releases younger than 14 days.

## PR rules

Same as Blob_auth: branches are named `<feat|fix|docs|chore>/<issue number>-short-slug`, and a PR needs a type label (`feature`, `enhancement`, `bug`, `documentation`) and a reference to an open issue. With Claude Code, "ship this" uses the `ship-pr` skill in `.claude/skills/`.
