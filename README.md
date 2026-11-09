# Platform engineering labs

Hands-on labs for a small **internal developer platform** that runs on one laptop:
a **hub** cluster (Argo CD, Gitea, with Backstage beside it) and two workload **cells**.
Each lab has a step-by-step `README.md` with copy-paste commands, what you should see,
and questions to think through.

```text
              Backstage ──creates repos──► Gitea (Git)
                  │                          ▲   │
                  └── catalog reads ─────────┘   │ Argo CD on the hub pulls
                                                 ▼
          ┌──────────────────── hub ────────────────────┐
          │ Argo CD: ApplicationSets (services, add-ons) │
          └───────────────┬────────────────┬────────────┘
                          ▼                ▼
                  cell-1 (ring 0)    cell-2 (ring 1)
```

## Labs

| # | Lab | You learn |
|---|---|---|
| — | [Setup](setup/README.md) | Build the hub, the cells, Argo CD, Gitea and Backstage |
| 0 | [Fleet tour](lab-00-fleet-tour/README.md) | Hub vs cells, contexts, how Argo CD knows its clusters |
| 1 | [Fleet GitOps](lab-01-fleet-gitops/README.md) | One ApplicationSet: every service repo × every cell |
| 2 | [Golden path](lab-02-golden-path/README.md) | A Backstage software template with guardrails built in |
| 3 | [Run the golden path](lab-03-run-golden-path/README.md) | Create a service end to end and measure time to first deploy |
| 4 | [Progressive delivery](lab-04-progressive-delivery/README.md) | Ring-by-ring rollout (RollingSync), drift, rollback with git revert |
| 5 | [Guardrails](lab-05-guardrails/README.md) | Kyverno on every cell via Argo CD, Audit → Enforce, tenant onboarding as code |
| 6 | [Canary releases](lab-06-canary-rollouts/README.md) | Argo Rollouts: canary steps, automatic analysis, abort and rollback |
| 7 | [Fleet CLI in Go](lab-07-go-fleet-cli/README.md) | client-go across every context: timeouts, concurrency, exit codes, tests |
| 8 | [Design RFC](lab-08-design-rfc/README.md) | Write the design doc for cells, rings and tenant placement |
| 9 | [Self-service database](lab-09-crossplane-database/README.md) | Crossplane: a `Database` API that hides the backend |
| 10 | [Supply chain](lab-10-supply-chain/README.md) | SBOM, cosign signatures and attestations, verification at admission |
| 11 | [Cost per tenant](lab-11-cost-per-tenant/README.md) | Prometheus and OpenCost on a shared cell, showback by tenant label |
| 12 | [Kafka topics as code](lab-12-kafka-topics/README.md) | Strimzi: mTLS identities, prefix ACLs, quotas, topic guardrails |

Labs 6–12 build on Labs 1–5; 7, 8 and 9 can be done in any order.

## Conventions used in every lab

| Thing | Convention |
|---|---|
| Contexts | `export KUBECONFIG=~/idp-lab/fleet.kubeconfig` → `hub`, `cell-1`, `cell-2` |
| A cell | An Argo CD cluster Secret labelled `fleet.lab/cell`, `fleet.lab/ring`, `fleet.lab/region`, `fleet.lab/tenancy`, `fleet.lab/compliance` |
| A service | A repo in the Gitea org `golden` with a `deploy/` folder (Kustomize) |
| Generated Applications | `<repo>-<cell>`, labelled `fleet.lab/service`, `fleet.lab/cell`, `fleet.lab/ring` |
| A tenant | A namespace labelled `tenant.lab/id=<tenant>` |
| Git address inside the hub | `http://gitea-http.gitea.svc:3000` (from your machine: `http://localhost:3300`) |

`cell`, `ring` and `tenant` are just label names. They mean something only because the
ApplicationSets and policies select on them; you can rename them if you change every place
that uses them.

## Reading the guides

- VS Code: open a `README.md` and press `Cmd+Shift+V` (macOS) or `Ctrl+Shift+V` for the preview.
- On GitHub or Gitea the README renders automatically.

## Useful one-liners

```bash
# skip the ~3 minute Git polling after a push
kubectl --context hub -n argocd annotate app <app> argocd.argoproj.io/refresh=normal --overwrite

# why did an ApplicationSet not generate apps?
kubectl --context hub -n argocd get appset <name> -o jsonpath='{.status.conditions}' | jq
```
