# Lab 9: A self-service Database API with Crossplane

**Time:** about 60 minutes · **Level:** beginner-friendly · **Needs:** Setup (the hub with Argo CD)

A developer should be able to say **"I need a small Postgres"** without knowing whether it
becomes AWS RDS, Azure Flexible Server or a pod. In this lab you build that **platform API**
with Crossplane. Here the backend is a Postgres StatefulSet on the hub; in a real company the
same API would create a cloud database.

---

## Part A: The ideas in plain words

### A1. A menu, not a kitchen

| Restaurant | Platform |
|---|---|
| The menu: "small pizza, medium pizza" | The **API**: `Database` with `size: small | medium` |
| The kitchen decides oven, dough, timing | The **Composition** decides StatefulSet, Service, Secret (or RDS on AWS) |
| You get a receipt with a table number | `status.endpoint` and `status.connectionSecret` |

Developers order from the menu. They never walk into the kitchen.

### A2. The Crossplane pieces

| Piece | Plain meaning | File |
|---|---|---|
| **Crossplane** | A controller that turns a custom resource into real things, and keeps them in sync | `01-crossplane-app.yaml` |
| **XRD** (CompositeResourceDefinition) | Defines the new kind `Database`: which fields a developer may set | `04-xrd.yaml` |
| **Composition** | The recipe: "for a `Database`, create these objects" | `05-composition-local.yaml` |
| **Function** | A step in the recipe. `function-go-templating` writes objects with Go templates; `function-auto-ready` marks the Database Ready when its parts are | `02-functions.yaml` |
| **RBAC** | Crossplane v2 can create any Kubernetes kind, but only those it has permission for | `03-rbac.yaml` |
| **DeploymentRuntimeConfig** (optional) | Settings for the pods that run functions, here an extra label | `02b-runtime-config.yaml` |
| **The claim** | What a developer writes: `kind: Database`, `size: small` | `06-example-claim.yaml` |

```text
developer:  Database "orders" (size: small) ──► Crossplane on the hub
                                                     │ Composition "database-local"
                                                     ▼
                       Secret orders-conn   Service orders-db   StatefulSet orders-db (Postgres)
                                                     │
                       status.endpoint = orders-db.team-identity.svc:5432
                       status.connectionSecret = orders-conn
```

### A3. One API, many backends

You can have several Compositions for the same `Database` kind: `provider: local` here,
`provider: aws` (RDS) on EKS, `provider: azure` on AKS. The claim picks one with
`compositionSelector`, or the platform sets a default. **The developer's YAML doesn't change.**

---

## Part B: Steps

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/platform-labs/lab-09-crossplane-database
```

### Step 1: Install Crossplane on the hub (through Argo CD)

```bash
kubectl --context hub apply -f 01-crossplane-app.yaml
kubectl --context hub -n argocd get app crossplane
kubectl --context hub -n crossplane-system get pods
```

**You should see:** the app Synced / Healthy, and `crossplane` plus `crossplane-rbac-manager`
Running (chart 2.4.3).

> **Why on the hub?** The hub is the management plane: platform APIs live there, close to
> Argo CD and Backstage. Cells stay small and only run workloads.

### Step 2: Functions and permissions

```bash
kubectl --context hub apply -f 02-functions.yaml -f 03-rbac.yaml
kubectl --context hub get functions
```

**You should see:** both functions `INSTALLED True` and `HEALTHY True`. This takes a minute,
because the function images are downloaded.

> **If your hub also runs the Lab 5 guardrails:** Crossplane runs each function as a
> Deployment, and Kyverno denies it ("Pods must have the label app.kubernetes.io/part-of";
> `kubectl describe functionrevision` shows it). Fix the platform component, not the policy:
> apply `02b-runtime-config.yaml` and add `runtimeConfigRef: { name: platform-labels }` to each
> Function. The Composition already labels the Postgres pods for the same reason.

### Step 3: The API (XRD) and the recipe (Composition)

```bash
kubectl --context hub apply -f 04-xrd.yaml
kubectl --context hub get xrd                          # ESTABLISHED True
kubectl --context hub apply -f 05-composition-local.yaml
kubectl --context hub get composition
kubectl --context hub api-resources | grep platform.lab   # your new kind
```

Read `05-composition-local.yaml` and find:
- how `size` picks CPU and memory (`if $small`);
- the password: `sha256sum` of the Database's uid. It's **stable**, so it doesn't change on
  every reconcile, unlike `randAlphaNum`;
- the last object, `kind: Database` with only `status`: that's how the recipe writes the
  "receipt" back.

### Step 4: Be the developer: order a database

```bash
kubectl --context hub apply -f 06-example-claim.yaml
kubectl --context hub -n team-identity get database orders -w     # wait for SYNCED True, READY True
```

```bash
kubectl --context hub -n team-identity get database orders -o jsonpath='{.status}' | jq
kubectl --context hub -n team-identity get statefulset,svc,secret
```

**You should see:** `endpoint: orders-db.team-identity.svc:5432` and
`connectionSecret: orders-conn`.

Connect with the credentials from the Secret, the way an app would:

```bash
kubectl --context hub -n team-identity run psql --rm -it --restart=Never --image=postgres:16.4-alpine \
  --env="PGPASSWORD=$(kubectl --context hub -n team-identity get secret orders-conn -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h orders-db -U app -d app -c 'select version();'
```

(The password goes from the Secret into the pod without being shown in your terminal. A real
app mounts the Secret instead of copying it into an environment variable on the command line.)

### Step 5: Day 2: resize to medium

```bash
kubectl --context hub -n team-identity patch database orders --type merge -p '{"spec":{"size":"medium"}}'
kubectl --context hub -n team-identity get database orders
kubectl --context hub -n team-identity get statefulset orders-db -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

**You should see:** the Database still **Synced True**, and the StatefulSet now requests
`500m` CPU and `512Mi` memory.

> **A trap found while testing:** if disk size also depended on `size`, the resize would fail.
> `volumeClaimTemplates` in a StatefulSet **can't be changed**, so the whole update is rejected
> and the Database goes `Synced False`. That's why storage is fixed at 1Gi here; grow it with
> PVC expansion. On real clouds the same kind of problem shows up as "this change forces
> replacement" fields.

In real life the developer doesn't `kubectl patch`. They change `size` in their repo and Argo CD
applies it, or a Backstage template creates the claim.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Function not Healthy | Image still downloading, or no internet from the kind node |
| Database `Synced False`, "cannot create statefulsets" | `03-rbac.yaml` missing: Crossplane needs permission for every kind it composes |
| Ready stays False | The Postgres pod isn't Ready yet: `kubectl -n team-identity get pods` |
| `no matches for kind "Database"` | The XRD isn't Established yet |
| Resize gives `Synced False` | Something immutable changed (see the trap above) |

```bash
kubectl --context hub -n team-identity describe database orders | tail -20    # events and conditions
```

---

## Questions to think through

1. **Crossplane or a Terraform module registry for self-service?** Crossplane: a Kubernetes API,
   reconciled all the time, fits GitOps. Terraform: a mature provider ecosystem, plan/apply
   review. Many companies use both: Terraform for the cells themselves, Crossplane for what
   teams order.
2. **The same `Database` API on EKS and AKS: where does it leak?** High availability, backups, IAM
   vs Entra ID authentication, Postgres extensions, maintenance windows. Choose the Composition
   by the cell's cloud label.
3. **Who is on call for a composed RDS instance?** Decide upgrades, backups, restore tests and
   deletion protection up front. A `deletionPolicy: Orphan` and a `PreventDeletion` guard are
   common.
4. **What should the API *not* let developers choose?** Instance class, network, encryption key.
   The platform decides those; the developer chooses intent (`size`).
