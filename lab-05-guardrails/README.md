# Lab 5: Guardrails and tenant onboarding as code (Kyverno, fleet-wide)

**Time:** about 60 minutes · **Level:** beginner-friendly · **Needs:** Labs 1–4 done

You will install a policy engine on every cell **through Argo CD**, deliver rules from Git,
block unsafe workloads, and make new tenants get their safety settings automatically.

---

## Part A: The ideas in plain words

### A1. What is a guardrail?

Think of a **housing society**:

| In a society | In Kubernetes |
|---|---|
| Society rules ("no parking in the fire lane") | **Policies** ("no `:latest` images") |
| A security guard checks people **at the gate** | An **admission controller** checks every object **before** it is saved |
| A new family gets a parking slot, key card and water quota automatically | A new **tenant namespace** gets network rules, a quota and limits automatically |
| The rule book everyone can read | **Policy as code**: the rules are YAML files in Git |

### A2. The guard at the gate

```text
kubectl apply ──► API server ──► "Kyverno, is this OK?" ──► Kyverno checks the rules
                                         │
                      yes → saved to the cluster      no → rejected with a message
```

**Kyverno** is an *admission webhook*: the API server asks it about every new or changed
object. You write the rules in YAML; Kyverno does the checking.

### A3. Kyverno can do three things

| Type | What it does | In this lab |
|---|---|---|
| **validate** | Say yes or no | Block `:latest` images; require the `app.kubernetes.io/part-of` label |
| **mutate** | Change an object on the way in | (not used here) |
| **generate** | Create extra objects automatically | A tenant namespace gets a NetworkPolicy, ResourceQuota and LimitRange |

### A4. Audit first, then Enforce

A new rule can break teams who don't know about it yet. So:

1. **Audit**: Kyverno *allows* everything but writes down what would have been blocked, in a
   **PolicyReport** (a report card per resource).
2. Read the reports, fix the problems (and the golden-path template).
3. **Enforce**: now it really blocks.

Like a society: first a month of warnings, then fines.

### A5. Tenant onboarding as code

A **tenant** is a customer or team with its own namespace on a shared cluster. Each tenant needs:

| Object | Plain meaning |
|---|---|
| **NetworkPolicy** (default deny) | Only pods in the same namespace (and DNS) can talk to each other. Other tenants are locked out |
| **ResourceQuota** | A total cap for the namespace (CPU, memory, number of pods), so one tenant can't starve others |
| **LimitRange** | Default and maximum CPU/memory **per container**, filled in when a pod doesn't say |

One **generate** rule says: *"any namespace labelled `tenant.lab/id` gets these three objects"*.
Labelling a namespace is now the whole onboarding.

### A6. Fleet-wide

Exactly like Lab 1: an **ApplicationSet** with a clusters generator installs Kyverno on every
cell, and a second one delivers the policies from Git. A new cell gets both automatically.

```text
Hub (Argo CD)
 ├─ ApplicationSet addon-kyverno   ──► kyverno-cell-1, kyverno-cell-2   (Helm chart)
 └─ ApplicationSet fleet-policies  ──► policies-cell-1, policies-cell-2 (Git: platform/policies)
                                            │
                       cell-1, cell-2: Kyverno checks every Pod, creates tenant defaults
```

---

## Part B: Files in this folder

| File | What it is |
|---|---|
| `addon-kyverno-appset.yaml` | Installs Kyverno (Helm chart 3.9.2 = Kyverno v1.19.2) on every cell |
| `policies-appset.yaml` | Syncs the Git repo `platform/policies` to every cell |
| `policies/00-kyverno-generate-rbac.yaml` | Lets Kyverno create NetworkPolicies, quotas and LimitRanges |
| `policies/10-disallow-latest-tag.yaml` | validate, two rules: images must have a tag, and it must not be `:latest` (starts in **Audit**) |
| `policies/11-require-part-of-label.yaml` | validate: Pods need `app.kubernetes.io/part-of` (starts in **Audit**) |
| `policies/20-tenant-onboarding.yaml` | generate: the three tenant objects |

The policies were tested on Kyverno v1.19.2 / Kubernetes 1.31 (Audit reports, Enforce
denials, generation, and self-repair of a deleted NetworkPolicy).

Set up your terminal once:

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig     # contexts: hub, cell-1, cell-2
cd ~/idp-lab/platform-labs/lab-05-guardrails
```

---

## Step 1: Install Kyverno on every cell (through Argo CD)

**Why:** you never `helm install` on each cluster by hand. Git + Argo CD do it, the same way
on every cell, and a new cell gets it automatically.

```bash
kubectl --context hub apply -f addon-kyverno-appset.yaml
```

Watch it (takes 1–3 minutes, images are downloaded):

```bash
kubectl --context hub -n argocd get app -l fleet.lab/addon=kyverno
kubectl --context cell-1 -n kyverno get pods
kubectl --context cell-2 -n kyverno get pods
```

**You should see:** `kyverno-cell-1` and `kyverno-cell-2` **Synced / Healthy**, and four pods
Running in each cell: `admission-controller`, `background-controller`, `cleanup-controller`,
`reports-controller`.

```bash
kubectl --context cell-1 get crd | grep kyverno.io | head -5    # the new resource types
```

> **Think:** Kyverno is a webhook. What happens to a cell if Kyverno is down?
> (See the webhooks page: `failurePolicy`. Kyverno excludes system namespaces so the cluster
> can still repair itself.)

---

## Step 2: Put the policies in Git and sync them to every cell

### 2a. Create the repo in Gitea (browser)

1. Open http://localhost:3300 and sign in.
2. **+ → New Organization** → name `platform` → Create.
3. In `platform`: **New Repository** → name `policies` → **Visibility: public** → Create.
   (Public, so Argo CD can read it without a token, like the `golden` repos.)

### 2b. Push the policy files

```bash
rm -rf /tmp/policies && mkdir /tmp/policies && cd /tmp/policies
cp ~/idp-lab/platform-labs/lab-05-guardrails/policies/*.yaml .
git init -b main
git add . && git commit -m "Add fleet policies (Audit mode)"
git remote add origin http://localhost:3300/platform/policies.git
git push -u origin main
```

### 2c. Apply the policies ApplicationSet

```bash
cd ~/idp-lab/platform-labs/lab-05-guardrails
kubectl --context hub apply -f policies-appset.yaml

kubectl --context hub -n argocd get app -l fleet.lab/addon=policies
kubectl --context cell-1 get clusterpolicy
kubectl --context cell-2 get clusterpolicy
```

**You should see:** in each cell, three policies with `READY True`:

```text
NAME                    ADMISSION   BACKGROUND   READY
disallow-latest-tag     true        true         True
require-part-of-label   true        true         True
tenant-onboarding       true        true         True
```

You will also see a warning that `ClusterPolicy` is deprecated in favour of the newer CEL-based
`ValidatingPolicy` / `GeneratingPolicy`. It still works; the newer kinds are worth reading about.

---

## Step 3: Audit, read the reports, then Enforce

### 3a. Read the report cards

The rules are in **Audit** mode: nothing is blocked, but every Pod gets a report.

```bash
kubectl --context cell-1 get policyreport -A
```

Show only the failures, with the reason:

```bash
kubectl --context cell-1 get policyreport -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.scope.name}{": "}{range .results[?(@.result=="fail")]}{.policy}{" "}{end}{"\n"}{end}' | grep -v ': $'
```

**Expect:** `tenant-api` pods **pass** (the golden-path template already sets
`app.kubernetes.io/part-of`). The `hello` pods from Lab 1 **fail** `require-part-of-label`,
because that Deployment was written by hand without the label.

**This is exactly why Audit comes first.** If you switched to Enforce now, `hello` could not
start new pods.

### 3b. Fix `hello` through Git (not kubectl)

```bash
rm -rf /tmp/hello && git clone http://localhost:3300/golden/hello.git /tmp/hello && cd /tmp/hello
```

Edit `deploy/deployment.yaml` and add the label under **both** `metadata.labels` and
`spec.template.metadata.labels`:

```yaml
    app.kubernetes.io/part-of: hello
```

```bash
git commit -am "Add app.kubernetes.io/part-of label" && git push
kubectl --context hub -n argocd annotate app hello-cell-1 hello-cell-2 argocd.argoproj.io/refresh=normal --overwrite
```

(Your fleet ApplicationSet uses RollingSync from Lab 4, so cell-1 updates before cell-2.)
Check the reports again after a minute: `hello` should now pass.

### 3c. Switch to Enforce (through Git)

```bash
cd /tmp
[ -d policies ] || git clone http://localhost:3300/platform/policies.git
cd policies && git pull
sed -i '' 's/failureAction: Audit.*/failureAction: Enforce/' 10-disallow-latest-tag.yaml 11-require-part-of-label.yaml
grep -n failureAction *.yaml
git commit -am "Enforce latest-tag and part-of policies" && git push
kubectl --context hub -n argocd annotate app policies-cell-1 policies-cell-2 argocd.argoproj.io/refresh=normal --overwrite
```

Check:

```bash
kubectl --context cell-1 get clusterpolicy disallow-latest-tag -o jsonpath='{.spec.rules[*].validate.failureAction}{"\n"}'
```

**You should see:** `Enforce Enforce` (one per rule).

---

## Step 4: Onboard a tenant by adding one label

```bash
kubectl --context cell-1 create namespace tenant-acme
kubectl --context cell-1 label namespace tenant-acme tenant.lab/id=acme
sleep 10
kubectl --context cell-1 -n tenant-acme get networkpolicy,resourcequota,limitrange
```

**You should see:**

```text
networkpolicy.networking.k8s.io/tenant-default-deny
resourcequota/tenant-quota     pods: 0/20, requests.cpu: 0/2, requests.memory: 0/2Gi   limits.cpu: 0/4, limits.memory: 0/4Gi
limitrange/tenant-limits
```

Try to remove the isolation, and watch Kyverno put it back (`synchronize: true`):

```bash
kubectl --context cell-1 -n tenant-acme delete networkpolicy tenant-default-deny
sleep 15
kubectl --context cell-1 -n tenant-acme get networkpolicy
```

> In real life the namespace itself would also come from Git (a tenant repo or a Backstage
> "new tenant" template). Here we use kubectl to keep the step short.

---

## Step 5: Prove the guardrails

**A `:latest` image is denied:**

```bash
kubectl --context cell-1 -n tenant-acme run bad --image=nginx:latest \
  --labels=app.kubernetes.io/part-of=demo
```

**You should see:**

```text
admission webhook "validate.kyverno.svc-fail" denied the request:
disallow-latest-tag:
  no-latest-tag: 'validation error: Image ''nginx:latest'' uses '':latest''. Pin a version tag. ...'
```

**An image with no tag at all is denied too.** `nginx` silently means `nginx:latest`, but the
string doesn't end in `:latest`, so a single `!*:latest` pattern would let it through. That's
why the policy has a second rule, `require-image-tag` (pattern `*:*`):

```bash
kubectl --context cell-1 -n tenant-acme run notag --image=nginx \
  --labels=app.kubernetes.io/part-of=demo
```

> **Lesson:** a guardrail is only as good as its pattern. Test it with the ways people really
> write things: no tag, `:latest`, a digest, a registry with a port (`localhost:5000/nginx`
> has a `:` but no tag, so it still passes `*:*`; how would you close that gap?).

**A Deployment without the label is denied** (Kyverno also checks the Pod template inside
Deployments; that is the `autogen-` rule in the message):

```bash
kubectl --context cell-1 -n tenant-acme create deployment nolabel --image=nginx:1.27
```

**A correct workload is allowed, and gets default limits from the LimitRange:**

```bash
kubectl --context cell-1 -n tenant-acme run good --image=nginx:1.27 \
  --labels=app.kubernetes.io/part-of=demo
kubectl --context cell-1 -n tenant-acme get pod good -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl --context cell-1 -n tenant-acme get resourcequota tenant-quota
```

**You should see:** the pod has `requests cpu 100m / memory 128Mi` and `limits cpu 500m /
memory 256Mi` that you never wrote, and the quota now counts 1 pod.

**The golden path still works:**

```bash
kubectl --context hub -n argocd get app -l fleet.lab/service=tenant-api
# delete one pod; its ReplicaSet creates a new one, which must pass the Enforce rules
POD=$(kubectl --context cell-1 -n tenant-api get pod -l app.kubernetes.io/name=tenant-api -o name | head -1)
kubectl --context cell-1 -n tenant-api delete $POD
sleep 15
kubectl --context cell-1 -n tenant-api get pods
```

**You should see:** both apps Synced / Healthy, and 2 pods Running again (one of them a few
seconds old), created under Enforce.

(Don't use `kubectl rollout restart` here: it changes the pod template, which Argo CD would see
as drift from Git.)

> The `curl` test pod from Lab 3 (`kubectl run curl ...`) is now denied, because it has no
> `part-of` label. Add `--labels=app.kubernetes.io/part-of=debug` to use it.

---

## Done when

- [ ] `kyverno-cell-1` and `kyverno-cell-2` are Synced / Healthy (installed by Argo CD, not by hand)
- [ ] `platform/policies` exists in Gitea and `policies-cell-*` are Synced
- [ ] You read a PolicyReport in Audit mode and fixed `hello` through Git
- [ ] Both validate rules are in **Enforce**
- [ ] `tenant-acme` got its NetworkPolicy, ResourceQuota and LimitRange from one label
- [ ] A `:latest` pod was denied; `tenant-api` still runs

---

## If something goes wrong

| Symptom | Likely cause and fix |
|---|---|
| `kyverno-cell-*` stuck OutOfSync on ClusterRoles | Kyverno fills in aggregated roles at runtime. The ApplicationSet already ignores `/rules`; check that `RespectIgnoreDifferences=true` is there |
| `policies-cell-*` error: `could not find the requested resource` / no matches for kind ClusterPolicy | Kyverno isn't installed yet. Finish step 1 first; `SkipDryRunOnMissingResource=true` lets it retry |
| `policies-cell-*` shows `repository not found` | The repo isn't public, or it's named differently. It must be `platform/policies` on branch `main` |
| Tenant namespace gets no objects | Missing RBAC: `00-kyverno-generate-rbac.yaml` must be synced. Check with `kubectl --context cell-1 get clusterrole -l rbac.kyverno.io/aggregate-to-background-controller` and look at `kubectl --context cell-1 get updaterequests -A` |
| Your own pod is denied unexpectedly | Read the message: it names the policy and rule. Add the label or pin the tag |
| Policy still `Audit` after the push | Argo CD hasn't polled yet: run the `refresh` annotate command from step 3c |

---

## Questions to think through

1. **Kyverno vs Gatekeeper vs ValidatingAdmissionPolicy.** Kyverno: YAML rules plus mutate,
   generate and image verification. Gatekeeper: Rego. ValidatingAdmissionPolicy: CEL, built
   into Kubernetes, nothing extra to run, but validate only. When would you pick each?
2. **Rolling a new rule out to 300 teams.** Audit → reports and a dashboard per team → fix it in
   the golden path → announce a date → Enforce ring by ring → time-boxed `PolicyException` for
   stragglers → run `kyverno apply` in CI so problems are caught before merge.
3. **What does namespace-per-tenant really isolate?** Network (with NetworkPolicy), quota, RBAC.
   What it does *not* isolate: the kernel, noisy neighbours on a node, cluster-wide objects like
   CRDs. Stronger options: sandboxed runtimes (gVisor, Kata), dedicated node pools, a dedicated
   cell for regulated tenants.
4. **Kyverno is a webhook. What if it's down?** `failurePolicy` decides between "block
   everything" and "allow everything". Run it highly available, exclude system namespaces,
   alert on it. The guardrail must not become the outage.
