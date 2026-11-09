# Lab 11: Observability and FinOps: cost per tenant on a shared cell

**Time:** about 45 minutes · **Level:** beginner-friendly · **Needs:** Lab 5 (tenants, guardrails)

Several tenants share cell-1. Who uses how much, and what does it cost? You'll install
**Prometheus** (metrics) and **OpenCost** (metrics × price = cost) and get a cost report
**per tenant**, using the same namespace labels the platform already uses.

---

## Part A: The ideas in plain words

### A1. A shared flat's electricity bill

| Shared flat | Shared cell |
|---|---|
| One bill for the whole flat | One bill for the cluster's nodes |
| A meter per room | Prometheus metrics per pod and namespace |
| "Room 2 is Priya's" | The namespace label `tenant.lab/id=acme` |
| Splitting the bill fairly | **OpenCost** splits node cost by what each pod **requested** (and used) |
| The hallway light nobody owns | `__unallocated__` and **idle**: capacity nobody requested |

### A2. The pieces

```text
kube-state-metrics ──► "pod X in namespace Y requests 200m CPU; namespace Y has label tenant.lab/id=globex"
node/cAdvisor      ──► "pod X actually uses 50m CPU"
        │
   Prometheus (stores the metrics)
        │
   OpenCost  ──► price per CPU-hour and GB-hour × requests/usage ──► cost per namespace, per label
```

**The trap (found while testing):** kube-state-metrics exports **no** labels by default. Without
`metricLabelsAllowlist`, Prometheus never learns `tenant.lab/id`, and "cost per tenant" is
impossible. That's why the ApplicationSet sets it.

### A3. Showback before chargeback

- **Showback:** show each team its cost. No money moves.
- **Chargeback:** actually bill the team's budget.

Start with showback, so teams trust the numbers before they're billed.

---

## Part B: Files in this folder

| File | What it is |
|---|---|
| `observability-appset.yaml` | Two ApplicationSets that select **only cell-1**: Prometheus (chart 29.43.0, no Alertmanager or Pushgateway) and OpenCost (chart 2.5.33) |
| `tenant-globex.yaml` | A second tenant namespace with labels, and a small workload |
| `tenant-acme-worker.yaml` | A smaller workload in `tenant-acme` (from Lab 5) |

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/platform-labs/lab-11-cost-per-tenant
```

---

## Step 1: Install Prometheus and OpenCost on cell-1 only

```bash
kubectl --context hub apply -f observability-appset.yaml
kubectl --context hub -n argocd get app -l 'fleet.lab/addon in (observability,finops)'
kubectl --context cell-1 -n monitoring get pods
kubectl --context cell-1 -n opencost get pods
```

**You should see:** only `prometheus-cell-1` and `opencost-cell-1` (no cell-2 apps: the selector is
`fleet.lab/cell: cell-1`), Synced / Healthy after 2–3 minutes.

Look at what the values do:
- `server.fullnameOverride: prometheus-server` gives a stable Service name, which OpenCost points
  at.
- `podLabels: {app.kubernetes.io/part-of: opencost}`: your own **Lab 5 guardrail** (Enforce: pods
  need `part-of`) blocked OpenCost's pods until they had this label. **Platform add-ons follow
  the same rules as tenants.** You fix the add-on; you don't weaken the policy.

> **Think:** why not install it on cell-2? Cost (Prometheus on every cell is expensive), or
> start on ring 0 first. In production you'd also send metrics to a central store (Thanos,
> Mimir, a managed service).

---

## Step 2: Two tenants with labels and workloads

```bash
kubectl --context cell-1 apply -f tenant-globex.yaml
kubectl --context cell-1 label namespace tenant-acme team=team-identity cost-center=cc-100 --overwrite
kubectl --context cell-1 apply -f tenant-acme-worker.yaml

kubectl --context cell-1 get ns -l tenant.lab/id -L tenant.lab/id,team,cost-center
kubectl --context cell-1 -n tenant-globex get networkpolicy,resourcequota,limitrange   # Lab 5 did this
```

**You should see:** two tenant namespaces with all three labels, a `worker` running in each, and
Kyverno's three objects already in `tenant-globex`.

In real life these labels come from the tenant onboarding (a Backstage form or a `Tenant`
resource), never from a hand-typed command.

---

## Step 3: Check that the labels reached Prometheus

```bash
kubectl --context cell-1 -n monitoring port-forward svc/prometheus-server 19090:80 &
sleep 3
curl -s 'localhost:19090/api/v1/query' --data-urlencode 'query=kube_namespace_labels{label_tenant_lab_id!=""}' \
  | jq -r '.data.result[].metric | "\(.namespace)  tenant=\(.label_tenant_lab_id)  cost-center=\(.label_cost_center)"'
```

**You should see:** `tenant-acme tenant=acme …` and `tenant-globex tenant=globex …`. Prometheus
changes `.` and `/` in label names to `_`, so `tenant.lab/id` becomes `label_tenant_lab_id`.

CPU requested per tenant, in plain PromQL:

```bash
curl -s 'localhost:19090/api/v1/query' --data-urlencode \
  'query=sum by (label_tenant_lab_id) (kube_pod_container_resource_requests{resource="cpu"} * on(namespace) group_left(label_tenant_lab_id) kube_namespace_labels{label_tenant_lab_id!=""})' \
  | jq -r '.data.result[] | "\(.metric.label_tenant_lab_id): \(.value[1]) CPU"'
kill %1
```

---

## Step 4: Cost per tenant from OpenCost

Wait about **5 minutes** after Step 2, because OpenCost needs some history.

```bash
SVC=$(kubectl --context cell-1 -n opencost get svc -o jsonpath='{.items[0].metadata.name}')
kubectl --context cell-1 -n opencost port-forward svc/$SVC 19003:9003 &
sleep 3

# by tenant label
curl -s 'localhost:19003/allocation/compute?window=1h&aggregate=label:tenant.lab/id&accumulate=true' \
  | jq '.data[0] | map_values({cpuCost, ramCost, totalCost})'

# by namespace
curl -s 'localhost:19003/allocation/compute?window=1h&aggregate=namespace&accumulate=true' \
  | jq '.data[0] | map_values(.totalCost)'
kill %1
```

**You should see:** `acme` and `globex` with their own cost (globex about twice as much, since it
requests 2 × 200m against acme's 100m), and a large `__unallocated__`.

### What is `__unallocated__`?

All the cost from pods whose namespace has **no** `tenant.lab/id` label: `kube-system`, `kyverno`,
`monitoring`, `opencost`, `tenant-api`… That's **shared platform cost**. You decide how to split
it (see question 1).

---

## Stretch

1. **A real bug in the golden path:** the skeleton puts `prometheus.io/scrape: "true"` on the
   **Deployment**, but Prometheus discovers **pods**, so `tenant-api` is never scraped. Move the
   annotations to `spec.template.metadata.annotations` in the Lab 2 template, create a service
   from it, and check it in the Prometheus targets (`/api/v1/targets`).
2. **Metrics-based canary (not pre-tested):** add a Prometheus AnalysisTemplate to the Lab 6
   Rollout that fails if the canary's 5xx rate is over 1%.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| OpenCost pods missing, ReplicaSet `FailedCreate` | Your Lab 5 guardrail: check `podLabels` in the ApplicationSet |
| `label_tenant_lab_id` empty in Prometheus | `metricLabelsAllowlist` missing, or kube-state-metrics hasn't restarted |
| OpenCost returns only `__unallocated__` | Too soon (wait 5 minutes), or the namespace labels aren't there |
| OpenCost can't reach Prometheus | The Service must be `prometheus-server` in `monitoring`, port 80 |

---

## Questions to think through

1. **How do you split shared costs (control plane, observability, idle capacity) fairly?**
   A written allocation key, usually in proportion to requests; show idle on its own line;
   showback before chargeback.
2. **Design a cost anomaly guardrail.** Daily cost per tenant and service against a baseline;
   alert the owner (from the Backstage catalog); budgets checked when resources are created;
   preview environments that expire on their own.
3. **Requests or usage for the bill?** Requests reserve the node, so bill on requests and teams
   right-size. Show usage next to it, so they see the waste (VPA or Goldilocks recommendations).
