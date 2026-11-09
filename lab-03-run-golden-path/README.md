# Lab 3: Run the golden path as a developer

**Time:** about 20 minutes · **Needs:** Lab 2

Goal: use the paved road end to end and **measure it**.

## Step 1: Create the service

1. Open http://localhost:3000/create → **Golden path - HTTP microservice** → **Choose**.
2. Name `tenant-api`, Description `Tenant management API`, Owner `team-identity`, Tier `tier-2`, Replicas `2`.
3. **Start a timer**, then click **Create**. All three steps should turn green.

The repo `golden/tenant-api` must **not** exist beforehand: the scaffolder creates it.

## Step 2: Watch it deploy

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
watch -n 5 kubectl --context hub -n argocd get app -l fleet.lab/service=tenant-api
```

Stop the timer when `tenant-api-cell-1` and `tenant-api-cell-2` are both Synced / Healthy.

## Step 3: Check everything

```bash
curl -s "http://localhost:3300/api/v1/repos/search?q=tenant" | jq -r '.data[].full_name'
for c in cell-1 cell-2; do kubectl --context $c -n tenant-api get deploy,pods,svc; done
kubectl --context cell-2 -n tenant-api run curl --rm -i --restart=Never \
  --labels=app.kubernetes.io/part-of=debug \
  --image=curlimages/curl:8.10.1 -- curl -s tenant-api/version
```

**You should see:** the repo, 2 pods in each cell, and JSON with `"version": "6.7.1"`.

## Read the timing from the real timestamps

```bash
kubectl --context hub -n argocd get app -l fleet.lab/service=tenant-api \
  -o jsonpath='{range .items[*]}{.metadata.name} created={.metadata.creationTimestamp} healthy={.status.health.lastTransitionTime}{"\n"}{end}'
```

A sample run:

```text
13:18:25  Create clicked; repo created and registered within ~1 s
13:18:41  ApplicationSet discovers the repo (waits for its 30 s rescan)
13:18:42  both cells synced
13:18:46  both Healthy                       total ≈ 21 s
```

Most of the time is **waiting for the rescan**. A Gitea → Argo CD webhook would cut it to a few seconds.

## If a step fails

Open **Create → ⋯ → Task List**, click the run, and read the red step's log.

## Questions to think through

1. Which numbers prove a developer platform is working six months in? (deploy frequency, lead
   time, change failure rate, time to restore, time to first deploy, % of services on the golden path)
2. A team says the golden path is too slow for them. What do you do?
