# Lab 1: Fleet GitOps (one ApplicationSet, every service, every cell)

**Time:** about 45 minutes · **Needs:** Lab 0

Goal: **zero-ticket onboarding**. Any repo in the Gitea org `golden` that has a `deploy/`
folder is deployed automatically to every cell. Nobody registers anything in Argo CD.

```text
Gitea org "golden"                         Argo CD (hub)
 ├─ hello/deploy/        ─┐  scmProvider   ┌─ hello-cell-1       ──► cell-1
 └─ tenant-api/deploy/   ─┼──────────────► ├─ hello-cell-2       ──► cell-2
                          │   x clusters   ├─ tenant-api-cell-1  ──► cell-1
 cells (label fleet.lab/cell) ─────────────┘ └─ tenant-api-cell-2 ──► cell-2
```

The ApplicationSet uses a **matrix** generator: *(repos with `deploy/`) × (clusters that are cells)*.
Each combination becomes one Application named `<repo>-<cell>`.

## Step 1: A repo to discover

In Gitea, create the org `golden` (if missing) and a **public** repo `hello`, then push a
`deploy/` folder. An empty repo makes Gitea return an error that breaks the whole generator,
so push content right away.

```bash
mkdir -p /tmp/hello/deploy && cd /tmp/hello
kubectl create deployment hello --image=nginx:1.27 --dry-run=client -o yaml > deploy/deployment.yaml
git init -b main && git add . && git commit -m "seed"
git remote add origin http://localhost:3300/golden/hello.git
git push -u origin main
```

## Step 2: Apply the ApplicationSet

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
kubectl --context hub apply -f ~/idp-lab/platform-labs/lab-01-fleet-gitops/fleet-appset.yaml
```

Read [`fleet-appset.yaml`](fleet-appset.yaml): every line has a comment. Key points:

- `api` and `repoURL` use the **in-cluster** Gitea address `http://gitea-http.gitea.svc:3000`,
  because Argo CD runs inside the hub. Gitea reports `localhost:3300` clone URLs, which only
  work from your Mac, so the template builds the URL itself.
- The clusters generator selects `fleet.lab/cell Exists`, so the hub never gets apps.
- The ring label is copied from the cluster onto each Application (needed in Lab 4).

## Step 3: Check

```bash
kubectl --context hub -n argocd get appset fleet-services -o jsonpath='{.status.conditions}' | jq
kubectl --context hub -n argocd get app -L fleet.lab/cell,fleet.lab/ring
kubectl --context cell-1 -n hello get pods
```

**You should see:** `hello-cell-1` and `hello-cell-2`, Synced / Healthy, and pods in both cells.
Push a second repo with `deploy/` and two more Applications appear within about 60 seconds.

## If something goes wrong

| Symptom | Look at |
|---|---|
| No Applications | `status.conditions` on the ApplicationSet, then `kubectl --context hub -n argocd logs deploy/argocd-applicationset-controller --tail=50` |
| `401` | A private repo or org: add a Gitea token Secret and `tokenRef` |
| HTTP `500` from Gitea | An empty repo in the org |
| App shows `repository not found` | Wrong `repoURL`, or a private repo without clone credentials |

## Questions to think through

1. Discovering services from the Git server vs a central list of services: trade-offs?
2. What stops a team from deploying to a cell it shouldn't? (AppProjects, label-based placement, policies on the cell)
3. 200 cells × 300 services = 60,000 Applications. What fails first, and how do you scale?
