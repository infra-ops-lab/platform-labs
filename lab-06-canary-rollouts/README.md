# Lab 6: Canary releases with automatic analysis and rollback (Argo Rollouts)

**Time:** about 60 minutes · **Level:** beginner-friendly · **Needs:** Labs 1–5 done

Lab 4's rings protect the **fleet**: cell-1 first, then cell-2. This lab protects each **cell**:
a new version first gets a small share of the pods, is tested automatically, and is rolled back
by itself if the test fails. Nobody has to watch a dashboard.

### What you will prove

| # | Test | What you do | What you should see | What it proves |
|---|---|---|---|---|
| 1 | Adopt | Replace the Deployment with a Rollout, in Git | 4 pods, Rollout **Healthy** | Canaries can be adopted through Git, with no change for developers |
| 2 | Good release | Change the message `v1` → `v2` | 25% → analysis ✔ → 50% → 100%, then cell-2 follows | A healthy change ships with nobody watching |
| 3 | Bad release | Start podinfo with `--random-error=true` | Analysis ✖ → **RolloutAborted**, stable stays 4/4, cell-2 untouched | The test catches what health checks miss; blast radius = 1 pod in 1 cell |
| 4 | Recover | `git revert` | Healthy at once, no new canary | Git stays the source of truth |

---

## Part A: The ideas in plain words

### A0. Why bother?

With a plain Deployment, a push replaces all 4 pods. If the new version is broken in a way
Kubernetes can't see (pods are Ready, users get errors), **everyone** gets the errors,
**nobody** notices until someone complains, and **a person** has to roll back. Lab 4's rings
make cell-2 wait for cell-1, but inside cell-1 everyone is still hit at once.

> Rings limit the blast radius across the **fleet**; canaries with automatic analysis limit it
> inside each **cluster**, so a bad release is caught and rolled back by software, not by a
> person watching dashboards.

### A1. Canary

The name comes from the canary that miners took underground: if the bird got sick, the miners
left. In software, a **canary** is a small slice of the new version running beside the old one.

```text
            4 pods of tenant-api
before:     [v1] [v1] [v1] [v1]           stable
25%:        [v1] [v1] [v1] [v2]           1 canary pod, then the analysis runs
50%:        [v1] [v1] [v2] [v2]
100%:       [v2] [v2] [v2] [v2]           v2 is the new stable
```

### A2. Rollout instead of Deployment

A normal **Deployment** can only do "replace pods a few at a time". It can't stop halfway,
run a test, or go back by itself. **Argo Rollouts** adds a new kind, `Rollout`. It's a
Deployment spec plus a `strategy.canary` with **steps**:

| Step | Meaning |
|---|---|
| `setWeight: 25` | Make 25% of the pods the new version |
| `analysis` | Run a test (an **AnalysisTemplate**). Fail → abort and go back |
| `pause: {duration: 20s}` | Wait (without a duration: wait for a human to promote) |

### A3. Two Services: stable and canary

```text
tenant-api         ──► only the stable pods  (users)
tenant-api-canary  ──► only the canary pods  (the analysis tests these)
```

Rollouts edits the selectors of both Services and adds a `rollouts-pod-template-hash`, so the
test checks **only** the new version.

### A4. Weight without a traffic router

There's no service mesh or ingress here, so "25%" means **1 of 4 pods**. Real per-request
weights (exactly 5% of requests) need a traffic router: Istio, NGINX, AWS ALB or the Gateway
API plugin.

### A5. Analysis: the automatic judge

In production the judge is a metrics query: "is the canary's error rate or p99 latency worse
than stable?". There's no Prometheus yet (that's Lab 11), so this lab uses the `web` provider:
call the canary 30 times, once a second, and any non-2xx answer fails it.

### A6. What gets installed: a new kind, a controller, a CLI

`Rollout` is a **kind**, like `Deployment`, but it doesn't ship with Kubernetes. Kubernetes can
be extended with a **CustomResourceDefinition (CRD)**, which teaches the API server a new kind,
and a **controller**, which watches objects of that kind and acts on them. A CRD alone only
stores objects; nothing happens until a controller reconciles them (the *operator pattern*).

| Part | Where it runs | What it does |
|---|---|---|
| CRDs: `Rollout`, `AnalysisTemplate`, `AnalysisRun`, … (`argoproj.io/v1alpha1`) | API server of each cell | Make the new kinds valid YAML |
| **Controller** (pod `argo-rollouts-<cell>-…`) | Each cell | Runs the steps, the analysis and the abort |
| **kubectl plugin** `kubectl-argo-rollouts` (optional) | Your machine | A readable tree view, plus `promote` / `abort` / `retry` / `dashboard` |

```bash
kubectl --context cell-1 get crd | grep argoproj.io
kubectl --context cell-1 explain rollout.spec.strategy.canary
```

**Two version numbers.** The Helm **chart** `argo-rollouts` **2.43.9** is the installer; it
ships the **app** (controller) **v1.10.2**. You pin the chart version in the ApplicationSet, and
you keep the kubectl plugin on the app version. (Same idea as Kyverno in Lab 5: chart 3.9.2 →
Kyverno v1.19.2.)

You've met this pattern before: Argo CD adds `Application` and `ApplicationSet`, Kyverno adds
`ClusterPolicy`, and in Lab 9 you define your own kind (`Database`) with Crossplane.

**Argo CD vs Argo Rollouts:**

| | Argo CD | Argo Rollouts |
|---|---|---|
| Question it answers | "Does the cluster match Git?" | "How do I replace v1 with v2 safely?" |
| Runs on | The hub | Every cell |
| Works on | Applications | Rollouts inside one app |

They work together: Argo CD applies the new Rollout spec from Git; Argo Rollouts moves it step
by step; Argo CD shows the Rollout's health (Progressing / Healthy / Degraded).

---

## Part B: Files in this folder

| File | What it is |
|---|---|
| `addon-argo-rollouts-appset.yaml` | Installs the Argo Rollouts controller (chart 2.43.9) on every cell |
| `tenant-api-deploy/` | The new `deploy/` folder for `golden/tenant-api` |
| `tenant-api-deploy/rollout.yaml` | The Rollout: 25% → analysis → pause → 50% → pause → 100% |
| `tenant-api-deploy/service.yaml`, `service-canary.yaml` | Stable and canary Services |
| `tenant-api-deploy/analysis-template.yaml` | The test: 30 calls to the canary, one per second, no errors allowed |
| `tenant-api-deploy/kustomization.yaml` | Same labels as the golden path |

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/platform-labs/lab-06-canary-rollouts
```

---

## Step 1: Install Argo Rollouts on every cell (through Argo CD)

```bash
kubectl --context hub apply -f addon-argo-rollouts-appset.yaml
kubectl --context hub -n argocd get app -l fleet.lab/addon=argo-rollouts
kubectl --context cell-1 -n argo-rollouts get pods
```

**You should see:** `argo-rollouts-cell-1` and `argo-rollouts-cell-2` Synced / Healthy, with one
controller pod Running per cell.

Optional: install the kubectl plugin. A kubectl plugin is just an executable named
`kubectl-<name>` on your `PATH`, so `kubectl argo rollouts …` runs `kubectl-argo-rollouts …`.
Use the same version as the controller (v1.10.2):

```bash
# with Homebrew
brew install argoproj/tap/kubectl-argo-rollouts

# or without Homebrew: download the single file (macOS Intel shown; use -darwin-arm64 on Apple silicon)
mkdir -p ~/bin
curl -fL -o ~/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/kubectl-argo-rollouts-darwin-amd64
chmod +x ~/bin/kubectl-argo-rollouts      # ~/bin must be on your PATH

kubectl argo rollouts version
```

Without the plugin everything still works with plain kubectl:
`kubectl -n tenant-api get rollout tenant-api -w` and `kubectl -n tenant-api get rs,analysisrun`.

---

## Step 2: Turn tenant-api into a Rollout (through Git)

```bash
rm -rf /tmp/tenant-api && git clone http://localhost:3300/golden/tenant-api.git /tmp/tenant-api
cd /tmp/tenant-api
git rm -q deploy/deployment.yaml
cp ~/idp-lab/platform-labs/lab-06-canary-rollouts/tenant-api-deploy/* deploy/
kubectl kustomize deploy | grep -E '^kind|name: tenant-api'     # check it renders
git add -A && git commit -m "Deliver tenant-api as a canary Rollout" && git push
kubectl --context hub -n argocd annotate app tenant-api-cell-1 tenant-api-cell-2 argocd.argoproj.io/refresh=normal --overwrite
```

Argo CD prunes the old Deployment and creates the Rollout. The **first** Rollout revision has
nothing to compare with, so it goes straight to 100% without running the steps.

> **Think:** the Deployment is deleted and the Rollout created in the same sync, so for a few
> seconds there may be no pods. In production you migrate with zero downtime using
> `spec.workloadRef` (the Rollout adopts the Deployment's pods), then remove the Deployment.

```bash
kubectl argo rollouts --context cell-1 -n tenant-api get rollout tenant-api
```

**You should see:** `Status: ✔ Healthy`, 4 pods, one ReplicaSet marked `stable`.

---

## Step 3: Ship a good change and watch it promote

In two terminals:

```bash
# terminal 1: live view
kubectl argo rollouts --context cell-1 -n tenant-api get rollout tenant-api --watch
```

```bash
# terminal 2: the change
cd /tmp/tenant-api
sed -i '' 's/tenant-api v1/tenant-api v2/' deploy/rollout.yaml
git commit -am "tenant-api v2 message" && git push
kubectl --context hub -n argocd annotate app tenant-api-cell-1 tenant-api-cell-2 argocd.argoproj.io/refresh=normal --overwrite
```

**You should see**, in terminal 1:

```text
Step: 1/5  SetWeight: 25   → a new ReplicaSet "canary" with 1 pod
Step: 2/5  analysis        → an AnalysisRun, ✔ Successful after ~30s (30 calls)
Step: 3/5  pause 20s
Step: 4/5  SetWeight: 50
Step: 5/5  pause 20s       → then 100%, the new ReplicaSet becomes "stable"
```

```bash
kubectl --context cell-1 -n tenant-api get analysisrun
```

> Your Lab 4 rings still apply: cell-2 starts only after cell-1 is Healthy, and a Rollout is
> Healthy only when it's fully promoted. **Rings protect the fleet; canaries protect the cell.**

---

## Step 4: Ship a bad change and watch it roll back by itself

The bad version starts podinfo with `--random-error=true`. Then `/` (the URL the analysis calls)
returns an error (500, 400 or 409) in about one second out of three, but the pods stay Ready.
(podinfo picks "error or not" once per second, which is why the analysis makes 30 calls a
second apart rather than 10 quick ones.) **Kubernetes
thinks the pods are fine; only the analysis notices.**

Edit `deploy/rollout.yaml` and add one line under `image:`:

```yaml
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          command: ["./podinfo", "--port=9898", "--random-error=true"]
```

```bash
git commit -am "tenant-api: bad release" && git push
kubectl --context hub -n argocd annotate app tenant-api-cell-1 argocd.argoproj.io/refresh=normal --overwrite
```

**You should see:**

```text
Step: 2/5  analysis ✖ Error
Status: ✖ Degraded
Message: RolloutAborted: ... Metric "canary-http-ok" assessed Error ... received non 2xx response code: 409
canary ReplicaSet scaled to 0, stable ReplicaSet (v2) still 4/4
```

```bash
kubectl --context cell-1 -n tenant-api get analysisrun
kubectl --context hub -n argocd get app tenant-api-cell-1 -o jsonpath='{.status.health.status}{"\n"}'
```

Argo CD shows **Degraded** (it has a built-in health check for Rollouts). Because of the Lab 4
RollingSync, **cell-2 never gets the bad version**.

> Note: in podinfo 6.7.1 the environment variable `PODINFO_RANDOM_ERROR` does nothing; only the
> `--random-error` flag works.

---

## Step 5: Recover with git revert

Git still says "bad version". If you only retried, Rollouts would try the same bad version
again. Put Git back:

```bash
cd /tmp/tenant-api
git revert --no-edit HEAD && git push
kubectl --context hub -n argocd annotate app tenant-api-cell-1 tenant-api-cell-2 argocd.argoproj.io/refresh=normal --overwrite
kubectl argo rollouts --context cell-1 -n tenant-api get rollout tenant-api
```

**You should see:** Healthy again, stable = v2. Because the reverted spec is the same as the
stable ReplicaSet, Rollouts goes straight back without a new canary.

---

## What happens at abort (be able to explain this)

| Thing | At abort |
|---|---|
| Stable ReplicaSet | Untouched. It kept serving the whole time, scaled back to 4/4 |
| Canary ReplicaSet | Scaled to 0, kept in history |
| `tenant-api` Service | Never pointed at the canary |
| Rollout status | `Degraded`, `RolloutAborted` |
| Argo CD | App **Degraded** (still "Synced": the cluster matches Git, Git is just wrong) |
| Next ring | Never starts |

---

## A trap found while testing: the canary test that tested stable

The first version of this lab had no `headers:` in the AnalysisTemplate, and a bad release
**passed**. All the measurements had been answered by a **stable** pod. Why:

1. Before the rollout, both Services point at the stable pods.
2. The Rollouts controller's HTTP client keeps **keep-alive** connections open between calls.
3. Rollouts switches `tenant-api-canary` to the canary pods, but kube-proxy only routes **new**
   connections with the new selector. An open connection stays on the pod it started on.
4. So the "canary" analysis kept talking to stable, and stable is fine.

The fix is `Connection: close` on every call, which forces a new connection each time. The
lesson goes beyond this lab: **check that your test really hits what you think it does**
(here, the `hostname` in the measurements). Mesh-based or metrics-based analysis (Prometheus,
labelled by the canary's pod-template-hash) doesn't have this problem.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "Rollout"` | Step 1 not finished on that cell; check `argo-rollouts-<cell>` |
| Canary pods never become Ready / Service has no endpoints | The pod template labels must include **every** label in the Service selector (`name`, `instance`, `part-of`) |
| AnalysisRun `Error` on a good release | The URL is wrong (`<service>.<namespace>.svc`), or the canary isn't Ready yet |
| A bad release **passes** the analysis | Check which pod answered: `kubectl get analysisrun <name> -o yaml`, field `hostname` in the measurements. If it's a stable pod, the `Connection: close` header is missing (see below) |
| Rollout pods denied by Kyverno | Your Lab 5 guardrails: tag pinned and `app.kubernetes.io/part-of` present? |
| `selector` change rejected | A Rollout's selector is immutable, like a Deployment's |

---

## Questions to think through

1. **Which metrics gate a canary for an identity API?** Error rate and p99 latency **compared with
   stable** (not fixed thresholds), authentication failure rate, saturation. Enough traffic to
   be statistically meaningful.
2. **Canary vs blue/green vs feature flags.** Blue/green needs double capacity but switches all at
   once (good for things that can't run side by side). Feature flags separate *deploy* from
   *release*.
3. **Database migrations with canaries and rings.** Expand/contract: the schema must work for
   version N and N-1 at the same time. Migrations are their own step, before the canary.
