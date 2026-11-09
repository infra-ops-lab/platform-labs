# Lab 4: Ring-based progressive delivery across cells

**Time:** about 45 minutes · **Needs:** Labs 1–3 done

Goal: a Git change reaches ring 0 (cell-1) first, and ring 1 (cell-2) only after
ring 0 is Healthy. Then practise drift and a GitOps rollback.

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig     # contexts: hub, cell-1, cell-2
cd ~/idp-lab/platform-labs
```

## 1. Enable progressive syncs on the ApplicationSet controller

```bash
kubectl --context hub -n argocd patch cm argocd-cmd-params-cm --type merge \
  -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'

# the controller reads this flag only at startup
kubectl --context hub -n argocd rollout restart deploy/argocd-applicationset-controller
kubectl --context hub -n argocd rollout status  deploy/argocd-applicationset-controller

# check: should print "true"
kubectl --context hub -n argocd get cm argocd-cmd-params-cm \
  -o jsonpath='{.data.applicationsetcontroller\.enable\.progressive\.syncs}{"\n"}'
```

If Argo CD is installed with Helm, set this in the chart values
(`configs.params`) so the next upgrade keeps it.

## 2. Label the cells (ring = rollout order)

The cluster Secrets carry the labels that the ApplicationSet selects on.

```bash
kubectl --context hub -n argocd label secret cluster-cell-1 --overwrite \
  fleet.lab/cell=cell-1 fleet.lab/ring=0 fleet.lab/region=us-east-1 \
  fleet.lab/tenancy=shared fleet.lab/compliance=commercial

kubectl --context hub -n argocd label secret cluster-cell-2 --overwrite \
  fleet.lab/cell=cell-2 fleet.lab/ring=1 fleet.lab/region=us-gov-west-1 \
  fleet.lab/tenancy=dedicated fleet.lab/compliance=fedramp

kubectl --context hub -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -L fleet.lab/cell,fleet.lab/ring
```

## 3. Apply the ApplicationSet with the RollingSync strategy

```bash
kubectl --context hub apply -f lab-04-progressive-delivery/fleet-appset-rollingsync.yaml

# errors show up here first
kubectl --context hub -n argocd get appset fleet-services -o jsonpath='{.status.conditions}' | jq

# Applications and their ring label
kubectl --context hub -n argocd get app -L fleet.lab/ring

# per-Application rollout status (Waiting -> Pending -> Progressing -> Healthy)
kubectl --context hub -n argocd get appset fleet-services \
  -o jsonpath='{range .status.applicationStatus[*]}{.application}: {.status} (step {.step}){"\n"}{end}'

# what the controller did to each app's sync policy
kubectl --context hub -n argocd get app tenant-api-cell-1 -o jsonpath='{.spec.syncPolicy}{"\n"}'
```

## 4. Make a change through Git and watch it go ring by ring

Terminal A (watch):

```bash
watch -n 2 "kubectl --context hub -n argocd get appset fleet-services \
  -o jsonpath='{range .status.applicationStatus[*]}{.application}: {.status} (step {.step}){\"\\n\"}{end}'; \
  echo; for c in cell-1 cell-2; do echo \$c; kubectl --context \$c -n tenant-api get deploy tenant-api --no-headers; done"
```

Terminal B (change):

```bash
rm -rf /tmp/tenant-api && git clone http://localhost:3300/golden/tenant-api.git /tmp/tenant-api
cd /tmp/tenant-api
sed -i '' 's/replicas: 2/replicas: 3/' deploy/deployment.yaml
git diff
git commit -am "Scale tenant-api to 3 replicas"
git push                       # asks for your Gitea user and password/token
```

Expected: `tenant-api-cell-1` goes Progressing -> Healthy first; only then does
`tenant-api-cell-2` start. Both end with 3/3 pods.

## 5. Drift

Predict first: will Argo CD put cell-2 back to 3 replicas? When? (Look at the
sync policy you printed in step 3.)

```bash
kubectl --context cell-2 -n tenant-api scale deploy tenant-api --replicas=5
kubectl --context cell-2 -n tenant-api get deploy tenant-api -w        # Ctrl+C to stop
kubectl --context hub -n argocd get app tenant-api-cell-2              # sync status
```

## 6. Roll back with git revert (not argocd app rollback)

```bash
cd /tmp/tenant-api
git revert --no-edit HEAD
git push
```

Watch Terminal A again: the revert also goes ring 0 first, then ring 1, and both
cells end at 2 replicas.

Use a real revert (the CLI above, or Gitea: open the commit -> Operations -> Revert), not a
manual edit back to the old value. A revert commit is titled `Revert "..."` and names the
commit it undoes, so the history shows exactly which change was rolled back.

Tip: after any push, skip the ~3 minute Git polling with:

```bash
kubectl --context hub -n argocd annotate app tenant-api-cell-1 tenant-api-cell-2 \
  argocd.argoproj.io/refresh=normal --overwrite
```

## 7. If a ring gets stuck

If ring 0's sync is stuck (for example a bad manifest retrying), ring 1 never
starts. Fix Git first, then clear the running operation:

```bash
argocd app terminate-op tenant-api-cell-1      # or the stuck app
kubectl --context hub -n argocd get app tenant-api-cell-1 -o jsonpath='{.status.operationState.message}{"\n"}'
```

## Done when

- [ ] Progressive syncs enabled, ApplicationSet has the RollingSync strategy
- [ ] replicas: 3 reached cell-1 before cell-2 started
- [ ] You can explain what happened to the manual scale to 5 in cell-2
- [ ] git revert brought both cells back to 2, ring by ring

## Questions to think through

1. RollingSync promotes on Healthy. Is that enough of a gate? What else would you add
   (soak time, SLO checks, in-cluster canary analysis, a manual gate for regulated rings)?
2. Why roll back with `git revert` instead of `argocd app rollback`?
3. A bad change is in ring 1 of 4 and ring 3 needs an urgent fix now. How do you ship it?
