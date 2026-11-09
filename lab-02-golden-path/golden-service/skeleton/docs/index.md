# ${{ values.name }}

${{ values.description }}

- Owner: `${{ values.owner }}`
- Tier: `${{ values.tier }}`
- Deployed by Argo CD from `deploy/` into namespace `${{ values.name }}`.

## Runbook
- Health: `GET /healthz` and `GET /readyz` on port 9898
- Metrics: `GET /metrics` (Prometheus format)
