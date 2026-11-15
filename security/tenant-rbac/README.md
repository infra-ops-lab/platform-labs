# Tenant RBAC lab: onboard a tenant with RBAC, quota, limits, Pod Security and NetworkPolicy

**Time:** about 90 minutes · **Level:** intermediate · **Needs:** Docker, kind, kubectl, openssl · **Theory:** [Security interview guide](../README.md)

One kind cluster called `ops-lab`. Tenant: **acme**, two namespaces: `acme-dev`, `acme-prod`. A second namespace,
`other-team`, plays a different tenant so you can test isolation.

The labels follow the **tenant-insights** operator's convention (`insights.pkbehera.co.in/tenant`), so a per-tenant
report operator has real data to read in steps 10 to 12. You don't need the operator for steps 1 to 10.

---

## 0. The plan: what this runbook does and why

| # | Step | What you build | Interview topic it covers | What tenant-insights reads from it |
|---|------|----------------|---------------------------|-------------------------------------|
| 1 | Preflight | nothing, only checks | authn vs authz, `auth whoami`, admission plugins | — |
| 2 | Namespaces | `acme-dev`, `acme-prod` with tenant + PSA labels | namespace as the tenancy boundary, label conventions | **tenant label** `insights.pkbehera.co.in/tenant=acme` groups both namespaces into one tenant |
| 3 | Identities | real x509 users `alice` (admin) and `bob` (dev) through the CSR API; `carol` and a CI ServiceAccount through impersonation | Kubernetes has no User object; CN = user, O = group; SA tokens | — |
| 4 | RBAC | ClusterRole `admin` → group `acme-admins`; custom ClusterRole `tenant-developer` → group `acme-devs`; extra exec Role in dev only; `view` → carol; least-privilege Role for CI | Role vs ClusterRole, RoleBinding to a ClusterRole, groups, least privilege, `resourceNames`, aggregation | **RoleBindings**: owners = unique User and Group subjects |
| 5 | Verify RBAC | `can-i` matrix and escalation tests | privilege escalation prevention, `bind`/`escalate`, "pod create = secret read" | — |
| 6 | ResourceQuota | compute + object-count quota per namespace | why quota needs requests, quota scopes, LB/NodePort = 0 | **ResourceQuotas**: CPU/memory used vs hard, near-limit |
| 7 | LimitRange | defaults, min/max, ratio | why LimitRange goes with quota, admission order | the "LimitRange" blocked reason |
| 8 | NetworkPolicy | default deny ingress + allow same tenant | namespaces are not a network boundary on their own | — |
| 9 | Workloads | bob deploys with his own cert | end-to-end check of the whole setup | **pods** (requests), **ReplicaSets → Deployment** |
| 10 | Break it | over quota, over LimitRange max, PodSecurity violation | reading `FailedCreate` events, debugging | **FailedCreate events** → blocked workloads + fix hints |
| 11 | Operator view | the `kubectl` queries the operator does for you | why build an operator at all | everything above |
| 12 | Report access | read access to the `acme` TenantReport only | cluster-scoped objects need ClusterRoleBinding; `resourceNames` does not limit `list` | TenantReport RBAC |
| 13 | Cleanup | remove everything | — | operator should delete the `acme` report |

**How to practise (mentor mode):** before each command block, say out loud what you expect: *allowed or forbidden, and why*. Then run it.
If you guessed wrong, that is the thing to learn before the interview.

Work folder: this lab's folder in your clone of the repo. **Set the path once in every terminal you use for this lab**; all commands below use it, so you can run them from any directory:

```bash
cd platform-labs/security/tenant-rbac && export LAB=$PWD      # adjust to where you cloned the repo
ls $LAB/manifests/platform $LAB/manifests/tenant $LAB/scripts   # sanity check: files are there
```

```
$LAB/manifests/platform/   applied as cluster admin (namespaced objects carry their namespace)
$LAB/manifests/tenant/     applied as bob with -n <ns> (no namespace in the files)
$LAB/scripts/make-user.sh  step 3a: x509 user through the CSR API (certs go to $LAB/certs)
$LAB/scripts/check-rbac.sh step 5b: can-i matrix with expected answers
```

If a command says `no such file or directory`, `$LAB` is not set in that terminal: run the `export` again.

Fast path (everything a platform team applies, steps 2–8 and 12):
`$LAB/scripts/make-user.sh alice acme-admins && $LAB/scripts/make-user.sh bob acme-devs && kubectl apply -f $LAB/manifests/platform/`

---

## 1. Preflight

Create the cluster and the "other tenant" namespace (skip if you already have `kind-ops-lab`):

```bash
kind create cluster --name ops-lab
kubectl create namespace other-team
```

```bash
kubectl config current-context            # expect kind-ops-lab
kubectl get nodes -o wide
kubectl auth whoami                       # who am I to the API server? (kind admin = cert, group kubeadm:cluster-admins)
kubectl auth can-i '*' '*'                # expect yes
kubectl api-resources --api-group=rbac.authorization.k8s.io
kubectl get pods -n kube-system -l app=kindnet   # kindnet enforces NetworkPolicy in recent kind
kubectl get ns --show-labels              # other-team has no tenant label: it is a different tenant
```

**Interview point:** *authentication* answers "who are you" (cert, OIDC token, SA token). *Authorization* answers "may you do this" (RBAC, Node, webhook).
*Admission* (quota, LimitRange, PSA, webhooks) runs after both and can still reject or change the request.

---

## 2. Namespaces with tenant and Pod Security labels

```bash
kubectl apply -f $LAB/manifests/platform/02-namespaces.yaml

kubectl get ns -l insights.pkbehera.co.in/tenant=acme --show-labels
```

**Interview point:** namespaces are cluster-scoped. A tenant admin with `admin` in the namespace **cannot** change these labels,
so they cannot turn off PSA for themselves. That is why the platform team owns the Namespace object.

---

## 3. Identities

Kubernetes has **no User object**. A user is whatever the authenticator says. With x509: `CN` = username, `O` = group.

### 3a. Real users through the CSR API (alice = admin, bob = developer)

Read [scripts/make-user.sh](scripts/make-user.sh) first: key → CSR with `/CN=<user>/O=<group>` → CertificateSigningRequest → approve → kubeconfig context `<user>@ops-lab`.

```bash
$LAB/scripts/make-user.sh alice acme-admins
$LAB/scripts/make-user.sh bob   acme-devs

openssl x509 -in $LAB/certs/alice.crt -noout -subject -enddate
kubectl --context alice@ops-lab auth whoami       # Username alice, Groups [acme-admins system:authenticated]
kubectl --context bob@ops-lab   get pods          # expect Forbidden: no RBAC yet
```

`set-context` does **not** switch your current context, so the other terminal (operator work) is not affected.

### 3b. CI ServiceAccount

```bash
kubectl apply -f $LAB/manifests/platform/03-ci-serviceaccount.yaml
```

carol (viewer) is tested only with impersonation: `--as=carol`.

**Interview points**
- A client cert cannot be revoked before it expires. You remove access by deleting the **RoleBinding**, not the cert. That is why short `expirationSeconds` and binding to **groups** (not users) matter.
- With impersonation, pass the groups yourself: `--as=bob --as-group=acme-devs`. `--as=bob` alone has no groups.

---

## 4. RBAC

### 4a. Tenant admins: built-in ClusterRole `admin`, bound per namespace to a group

```bash
kubectl apply -f $LAB/manifests/platform/04a-rbac-admins.yaml
```

ClusterRole + **RoleBinding** = the ClusterRole's rules, but only inside that namespace. Write the rules once, use them in many namespaces.

### 4b. Developers: a custom reusable ClusterRole

```bash
kubectl apply -f $LAB/manifests/platform/04b-rbac-tenant-developer.yaml   # ClusterRole (no secrets on purpose) + RoleBinding per namespace
```

### 4c. Exec and port-forward only in dev (a namespaced Role)

```bash
kubectl apply -f $LAB/manifests/platform/04c-rbac-dev-debug.yaml
```

In 1.31+ exec over websockets needs `create` on `pods/exec` (before it was enough to have `get`).

### 4d. Viewer and CI

```bash
# carol = view in both namespaces; CI may only roll out existing Deployments in prod (no create, no delete)
kubectl apply -f $LAB/manifests/platform/04d-rbac-viewer-ci.yaml
```

```bash
kubectl get rolebindings -n acme-dev -o wide
kubectl get rolebindings -n acme-prod -o wide
```

**Interview points**
- RBAC is **additive only**. There is no "deny" rule. To take a right away, remove a binding.
- `roleRef` cannot be changed on a RoleBinding. Delete and create again (or `kubectl auth reconcile`).
- `view` does **not** include Secrets. `edit` and `admin` do.

---

## 5. Verify RBAC (the most asked part)

### 5a. Full list for one identity

```bash
kubectl auth can-i --list -n acme-dev --as=bob --as-group=acme-devs
kubectl auth can-i --list -n acme-prod --as=system:serviceaccount:acme-prod:acme-ci
```

### 5b. Matrix

```bash
$LAB/scripts/check-rbac.sh     # prints each check, the answer, and the expected answer
```

Cover the "expect" column and predict first. For a single ad-hoc check: `kubectl auth can-i <verb> <resource> -n <ns> --as=<user> --as-group=<group>`.

### 5c. Escalation tests, as alice with her real cert

```bash
# alice tries to give herself cluster-admin inside her namespace -> Forbidden (escalation prevention)
kubectl --context alice@ops-lab -n acme-dev create rolebinding oops --clusterrole=cluster-admin --user=alice

# alice gives "edit" to a new teammate -> allowed, because she already has every right in "edit"
kubectl --context alice@ops-lab -n acme-dev create rolebinding dave-edit --clusterrole=edit --user=dave
kubectl --context alice@ops-lab -n acme-dev delete rolebinding dave-edit

# alice tries to bind a role in another tenant -> Forbidden
kubectl --context alice@ops-lab -n other-team create rolebinding x --clusterrole=view --user=alice
```

### 5d. CI with a real short-lived token

```bash
TOKEN=$(kubectl create token acme-ci -n acme-prod --duration=10m)
kubectl --token="$TOKEN" auth whoami
kubectl --token="$TOKEN" -n acme-prod get deployments     # allowed (empty list)
kubectl --token="$TOKEN" -n acme-prod get pods            # Forbidden
```

**Interview points**
- You can only create a binding for a role if you already have all its rights, **or** you have the `bind` verb on that role. You can only create or edit a Role with rights you have, **or** you have `escalate`.
- **Hidden escalation:** anyone who can create pods in a namespace can mount any Secret and any ServiceAccount there. bob has no `get secrets`, but he can still read secrets by creating a pod. Tell the interviewer this: it shows you think like an attacker.
- `kubectl create token` gives a bound, short-lived token (TokenRequest API). Old long-lived Secret tokens are no longer created on their own.

---

## 6. ResourceQuota

```bash
kubectl apply -f $LAB/manifests/platform/06-resourcequota.yaml   # dev: 1 CPU / 1Gi requests, 10 pods; prod: 2 CPU / 2Gi, 20 pods

kubectl describe resourcequota acme-quota -n acme-dev
```

**Predict first:** bob now runs `kubectl run t --image=busybox:1.37` in acme-dev *without* any resources. What happens?

```bash
kubectl --context bob@ops-lab -n acme-dev run t --image=busybox:1.37 -- sleep 3600
```

Rejected: `must specify limits.cpu, limits.memory, requests.cpu, requests.memory`. (You may also see a PSA warning.)
Once a quota limits `requests.cpu`, every pod must say how much it requests. Step 7 fixes this with defaults.

**Interview points**
- Quota is checked at **admission** time (create), not at run time. Pods already running are not killed when you lower the quota.
- Quota counts **requests/limits**, not real use. Real use is a metrics question (metrics-server, Prometheus).
- `services.loadbalancers: 0` and `nodeports: 0` stop a tenant from opening the cluster to the outside.
- Quota scopes (`BestEffort`, `NotTerminating`, `PriorityClass`) let you quota different pod classes differently.

---

## 7. LimitRange

```bash
kubectl apply -f $LAB/manifests/platform/07-limitrange.yaml

kubectl describe limitrange acme-limits -n acme-dev
```

Now the same command works, but only if the pod also follows PSA `restricted`. [manifests/tenant/07-test-pod.yaml](manifests/tenant/07-test-pod.yaml) is PSA-compliant and has **no resources**:

```bash
kubectl --context bob@ops-lab -n acme-dev apply -f $LAB/manifests/tenant/07-test-pod.yaml

kubectl -n acme-dev get pod t -o jsonpath='{.spec.containers[0].resources}{"\n"}'   # defaults were added by LimitRange
kubectl describe resourcequota acme-quota -n acme-dev                              # used went up
kubectl --context bob@ops-lab -n acme-dev delete pod t
```

**Interview point:** admission order is *mutating* (LimitRanger adds defaults) → *validating* (LimitRanger max/min, PodSecurity, ResourceQuota last).
So quota sees the values after defaults were added.

---

## 8. NetworkPolicy

```bash
kubectl apply -f $LAB/manifests/platform/08-networkpolicy.yaml   # default-deny-ingress + allow-same-tenant, both namespaces
```

Test after step 9 (web is running in acme-dev):

```bash
# from other-team (other tenant): expect timeout
kubectl -n other-team run probe --rm -it --restart=Never --image=busybox:1.37 -- wget -qO- -T 3 http://web.acme-dev:8080 ; echo "exit=$?"
```

Then run the same probe from a pod in `acme-prod` (same tenant): it should answer `hello-acme`.
The probe pod must follow PSA `restricted` there, so this is a good exercise: write its `--overrides` yourself.

**Interview points:** NetworkPolicy is **allow-list** and additive. No policy = all traffic allowed. It only works if the CNI enforces it.
The tenant label on the namespace is what lets one policy cover all namespaces of a tenant, and only the platform team can set that label.

---

## 9. Workloads (as bob, with his own cert)

```bash
kubectl --context bob@ops-lab -n acme-dev apply -f $LAB/manifests/tenant/09-workload-web.yaml

kubectl --context bob@ops-lab -n acme-dev rollout status deploy/web
kubectl --context bob@ops-lab -n acme-dev get pods,svc
kubectl --context bob@ops-lab -n acme-dev exec deploy/web -- wget -qO- localhost:8080   # exec allowed in dev
```

Apply the same file into prod (`kubectl --context bob@ops-lab -n acme-prod apply -f $LAB/manifests/tenant/09-workload-web.yaml`) and try exec there: Forbidden.

Now test the NetworkPolicy from step 8.

---

## 10. Break it: make the three blocked reasons tenant-insights classifies

Run each, then look at the events. These `FailedCreate` events on ReplicaSets are exactly what the operator turns into "blocked workloads".

### 10a. Over quota

```bash
kubectl --context bob@ops-lab -n acme-dev scale deploy/web --replicas=12
sleep 5
kubectl -n acme-dev get deploy web                       # READY stops below 12
kubectl -n acme-dev get events --field-selector reason=FailedCreate
# ... exceeded quota: acme-quota, requested: requests.cpu=100m, used: requests.cpu=1, limited: requests.cpu=1
```

### 10b. Over LimitRange max

```bash
kubectl --context bob@ops-lab -n acme-dev scale deploy/web --replicas=2
# PSA-compliant on purpose, so the ONLY problem is the 2-CPU limit (LimitRange max is 1)
kubectl --context bob@ops-lab -n acme-dev apply -f $LAB/manifests/tenant/10b-break-limitrange.yaml
sleep 5
kubectl -n acme-dev get events --field-selector reason=FailedCreate | tail -5
# ... maximum cpu usage per Container is 1, but limit is 2
```

### 10c. PodSecurity violation

```bash
kubectl --context bob@ops-lab -n acme-dev apply -f $LAB/manifests/tenant/10c-break-podsecurity.yaml
# you get a Warning at apply time (warn label), the Deployment is created, the pods are not
kubectl -n acme-dev get events --field-selector reason=FailedCreate | grep -i podsecurity
```

### 10d. See all blocked workloads in the tenant (what the operator does for you)

```bash
kubectl get events -A --field-selector reason=FailedCreate \
  -o custom-columns=NS:.involvedObject.namespace,KIND:.involvedObject.kind,NAME:.involvedObject.name,MSG:.message \
  | grep -E '^(NS|acme-)'
```

Leave these broken for now if you want the operator to show them. Fix later with `kubectl -n acme-dev delete deploy big rooty`.

---

## 11. What tenant-insights joins together (by hand)

```bash
T=acme
NS=$(kubectl get ns -l insights.pkbehera.co.in/tenant=$T -o jsonpath='{.items[*].metadata.name}'); echo "namespaces: $NS"

for ns in $NS; do
  echo "== $ns quota"
  kubectl get resourcequota -n $ns -o jsonpath='{range .items[*]}{.metadata.name}: cpu {.status.used.requests\.cpu}/{.status.hard.requests\.cpu}, mem {.status.used.requests\.memory}/{.status.hard.requests\.memory}{"\n"}{end}'
  echo "== $ns access"
  kubectl get rolebindings -n $ns -o jsonpath='{range .items[*]}{.roleRef.kind}/{.roleRef.name} -> {range .subjects[*]}{.kind}:{.name} {end}{"\n"}{end}'
done
```

Owners for acme (Users and Groups, not ServiceAccounts): `acme-admins`, `acme-devs`, `carol` → **3**. Check the operator says 3.

Then, when the operator runs:

```bash
kubectl get tenantreports
kubectl get tenantreport acme -o yaml
kubectl get tenantreports -l insights.pkbehera.co.in/phase=Blocked
```

**Interview story:** "Answering *why is my team's deploy stuck* needed 4 kubectl commands across N namespaces and reading raw event text.
The operator joins namespace labels + quotas + RoleBindings + FailedCreate events into one row per tenant with a fix hint."

---

## 12. Let acme admins read only their own TenantReport

TenantReport is **cluster-scoped**, so a RoleBinding cannot grant it. You need a ClusterRole + **ClusterRoleBinding**.

```bash
kubectl apply -f $LAB/manifests/platform/12-tenantreport-reader.yaml   # ClusterRole with resourceNames: [acme] + ClusterRoleBinding to acme-admins

kubectl auth can-i get  tenantreports.insights.pkbehera.co.in/acme     --as=alice --as-group=acme-admins   # yes
kubectl auth can-i get  tenantreports.insights.pkbehera.co.in/payments --as=alice --as-group=acme-admins   # no
kubectl auth can-i list tenantreports.insights.pkbehera.co.in          --as=alice --as-group=acme-admins   # no
```

(RBAC rules for a CRD that is not installed yet are allowed; they start working when the CRD exists.)

**Interview points**
- `resourceNames` works for get/update/delete/watch on a named object. It **cannot** limit `list` or `create`, because the name is not known in the request path. So "list only my reports" needs a different design (one namespaced report per tenant namespace, or an API that filters).
- This is a design trade-off to bring up for the operator: cluster-scoped reports are simple, but per-tenant read access only works by name.
- Aggregation: a ClusterRole labelled `rbac.authorization.k8s.io/aggregate-to-view: "true"` adds its rules to the built-in `view`. Good for "everyone with view can read our CRD", **not** good for cluster-scoped data with other tenants' info in it.

---

## 13. Cleanup

```bash
kubectl delete ns acme-dev acme-prod other-team
kubectl delete -f $LAB/manifests/platform/04b-rbac-tenant-developer.yaml -f $LAB/manifests/platform/12-tenantreport-reader.yaml --ignore-not-found
kubectl delete csr alice bob
for u in alice bob; do kubectl config delete-context $u@ops-lab; kubectl config delete-user $u; done
rm -rf $LAB/certs
kubectl get tenantreports            # if operator runs: the acme report should be gone (spec: delete reports for gone tenants)
```

---

## Interview question bank (answer each in 30 seconds)

Longer answers for all of these are in the [Security interview guide](../README.md).

1. Role vs ClusterRole vs RoleBinding vs ClusterRoleBinding: which four combinations exist, and which one gives namespace-only access using shared rules?
2. Where are users stored in Kubernetes? (Nowhere. Authenticator decides. x509 CN/O, OIDC claims.)
3. How do you remove a user's access when they used a client cert? (Delete bindings; you cannot revoke the cert. Use groups and short expiry.)
4. A tenant admin wants to create a RoleBinding to `cluster-admin`. What stops them? (Escalation check; `bind`/`escalate` verbs.)
5. Developer has no secret access but can create pods. Is that safe? (No: pod mounts secret / uses SA token.)
6. Pod is pending with no events about scheduling, Deployment shows 0/3. Where do you look? (ReplicaSet events, `FailedCreate`: quota, LimitRange, PSA, webhook.)
7. Why does a ResourceQuota on `requests.cpu` usually need a LimitRange?
8. You lower a quota below current use. What happens to running pods? (Nothing; only new creates are blocked.)
9. How do you stop a tenant from making a LoadBalancer or NodePort service?
10. How do you stop a tenant from disabling Pod Security? (Namespace is cluster-scoped; tenant has no patch on namespaces.)
11. Can `resourceNames` limit `list`? Why not?
12. How do you audit who can do X? (`kubectl auth can-i --list --as`, `kubectl get rolebindings -A -o wide`, tools like rbac-lookup / kubectl-who-can, audit logs.)
13. How would you make tenant onboarding repeatable? (TeamSpace-style CRD + controller, or GitOps with Kustomize/Helm; Capsule/HNC as off-the-shelf.)
14. How does your tenant-insights operator get its rights? (ClusterRole get/list/watch on namespaces, quotas, limitranges, rolebindings, nodes, pods, replicasets, events; write only on its own CRDs: least privilege, read-only on tenant data.)
