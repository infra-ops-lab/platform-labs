# Kubernetes security: interview guide

**Time:** read in about 90 minutes, practise for longer · **Level:** intermediate to senior · **Hands-on lab:** [Tenant RBAC lab](tenant-rbac/README.md)

23 topics, grouped the way a request flows through a cluster: **who is calling → what may they do → how are tenants kept apart →
what are we running → how do we notice trouble → how do we prove it to an auditor**.

Every topic has:

- **Say it in 30 seconds**: the answer you give first. Stop there and let the interviewer pick what to dig into.
- **Go deeper**: what a senior answer adds.
- **Try it**: commands for a kind cluster (most come from the [Tenant RBAC lab](tenant-rbac/README.md)).
- **Follow-up**: a question they often ask next, with the answer folded away. Answer it out loud before you open it.

```text
 request ──► authentication ──► authorization ──► admission ──► etcd ──► kubelet runs the pod
             "who are you?"     "may you?"         "is it OK?"            "inside what limits?"
             certs, OIDC,       RBAC, Node,        PSA, quota,            seccomp, caps,
             SA tokens          webhook            LimitRange, webhooks   NetworkPolicy (CNI)
             Part 1             Part 2             Part 3                 Part 3
```

---

## Part 1: Identity: who is calling?

### 1. How the API server decides who you are

> **Say it in 30 seconds:** Every request is authenticated first. The API server tries its authenticators in turn:
> x509 client certificates, bearer tokens (ServiceAccount tokens, OIDC tokens from an identity provider), an
> authenticating proxy, or a webhook. The first one that succeeds sets the **username, groups and extra** fields.
> Kubernetes has **no User object**: identities live outside the cluster. Humans should come in through **OIDC**,
> workloads through **ServiceAccount tokens**.

**Go deeper**

- Authentication only answers *who*. Authorization (Part 2) answers *may you*, and admission (Part 3) can still reject or change the request.
- If nothing matches and anonymous access is on, the request runs as `system:anonymous` / group `system:unauthenticated`. Keep that to health endpoints only.
- Avoid static token files and shared admin certificates: they never expire and you can't tell people apart in audit logs.
- In production use OIDC (Okta, Entra ID, Keycloak, Google). Group membership and leavers are handled in one place, and tokens are short-lived.

**Try it**

```bash
kubectl auth whoami          # Username, Groups, Extra for your current credentials
kubectl --context alice@ops-lab auth whoami
```

<details markdown="1"><summary>Follow-up: what is the difference between authentication and authorization failures?</summary>

`401 Unauthorized` = the API server doesn't know who you are (bad or expired credential).
`403 Forbidden` = it knows who you are, and RBAC (or another authorizer) said no. The 403 message names the user, verb and resource, which is the first thing to read when debugging.

</details>

### 2. What a kubeconfig file holds

> **Say it in 30 seconds:** Three lists and a pointer. **clusters** (API server URL + the CA used to trust it),
> **users** (credentials: client cert + key, a token, or an exec plugin), and **contexts** (cluster + user +
> default namespace). `current-context` picks the default. A kubeconfig with embedded credentials **is a password**.

**Go deeper**

- The `users[].name` is just a local nickname. The real identity comes from inside the credential (the certificate's CN, the token's subject).
- `certificate-authority-data` makes kubectl check the **server**. `insecure-skip-tls-verify: true` turns that off: never in production.
- **Exec plugins** (`kubelogin`, `aws eks get-token`, `gke-gcloud-auth-plugin`) fetch a fresh short-lived token each time, so the file holds no long-lived secret.
- Pods don't use a kubeconfig. client-go's *in-cluster config* reads `KUBERNETES_SERVICE_HOST` plus the token and CA mounted at `/var/run/secrets/kubernetes.io/serviceaccount/`.

**Try it**

```bash
kubectl config view            # secrets shown as DATA+OMITTED
kubectl config view --minify   # only the current context
kubectl config get-contexts
```

<details markdown="1"><summary>Follow-up: a laptop with an admin kubeconfig is stolen. What do you do?</summary>

If it held an **OIDC exec plugin**: disable the user in the identity provider. Access ends when the current token expires (minutes to an hour).
If it held a **client certificate**: you can't revoke it. Remove every binding for that user and their groups. If the cert is in `system:masters` (which RBAC can't restrict), the only full fix is rotating the cluster CA. That's why nobody should carry `system:masters` certificates day to day.

</details>

### 3. Client certificates, the CSR flow and the cluster CA

> **Say it in 30 seconds:** The user makes a **private key** and a **CSR** with `CN=<user>` and `O=<group>`.
> They submit it as a `CertificateSigningRequest`, an admin **approves** it, and the controller-manager signs it with
> the **cluster CA key**. The user keeps key + cert + the public CA cert. The **CA private key never leaves the
> control plane**: whoever has it can create any identity offline.

**Go deeper**

```text
user's machine                                    control plane
openssl genrsa  ──► alice.key (never leaves)
openssl req     ──► alice.csr (public key + CN/O) ──► CertificateSigningRequest (Pending)
                                                   kubectl certificate approve ──► signed with ca.key
alice.crt  ◄──────────────── .status.certificate ◄─┘
kubeconfig: client-certificate-data + client-key-data + certificate-authority-data
```

- `ca.crt` is used **both ways**: the API server checks client certs against it (`--client-ca-file`), and kubectl/pods check the server against it.
- Kubernetes has **several CAs**: the main CA, the etcd CA and the front-proxy CA, so one leak doesn't open everything.
- **Approving a CSR means trusting whatever names it claims.** Approving `O=system:masters` creates a full admin that RBAC can't stop. Treat the `approve` permission on signers as admin-level.
- The private key is generated on the user's side. The cluster only ever sees the public key.

**Try it**

```bash
openssl x509 -in certs/alice.crt -noout -subject -issuer -enddate
docker exec ops-lab-control-plane ls -l /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.key
kubectl get csr
```

<details markdown="1"><summary>Follow-up: why are client certificates a poor choice for people?</summary>

They can't be revoked (Kubernetes doesn't check CRLs or OCSP), groups are fixed inside the cert until it expires, and nothing renews them automatically. Use them for break-glass admin access and for components. Use OIDC for people.

</details>

### 4. What renews itself: certificate and token lifetimes

> **Say it in 30 seconds:** Control-plane certs are renewed by **kubeadm** (`kubeadm certs renew`, and automatically on
> every `kubeadm upgrade`). The **kubelet rotates its own client cert**. **ServiceAccount tokens** in pods are
> short-lived and refreshed by the kubelet. **Human client certs renew themselves never**: you repeat the CSR flow
> and update the same kubeconfig entry.

**Go deeper**

| Identity | Lifetime (typical) | Who renews it |
|---|---|---|
| API server, etcd, front-proxy certs, `admin.conf` | 1 year | kubeadm (`certs renew` or on upgrade), then restart the static pods |
| Cluster CA | 10 years | You, with a planned CA rotation (painful: every client and node changes) |
| Kubelet client cert | about 1 year | Kubelet, automatically, via an auto-approved CSR |
| Kubelet serving cert | about 1 year | Off by default (`serverTLSBootstrap`); when on, someone must approve its CSRs |
| Pod ServiceAccount token | 1 hour (bound to the pod) | Kubelet refreshes the projected file; client-go re-reads it |
| `kubectl create token` | what you ask for | Nobody: ask again (perfect for CI) |
| Human client cert | what the CSR asks for, capped by `--cluster-signing-duration` | Nobody: new CSR → approve → `kubectl config set-credentials` |
| OIDC token | minutes to 1 hour | The exec plugin, silently; the kubeconfig never changes |

- A renewed certificate does **not** cancel the old one. The old one works until its own expiry date.
- After `kubeadm certs renew`, copy `admin.conf` again if you use a copy of it as your kubeconfig.

**Try it**

```bash
docker exec ops-lab-control-plane kubeadm certs check-expiration
```

<details markdown="1"><summary>Follow-up: a cluster's certs expired over the weekend. What breaks and how do you fix it?</summary>

kubectl gets TLS errors and the control-plane components can't talk to each other or to etcd. On each control-plane node: `kubeadm certs renew all`, restart the kube-apiserver, controller-manager, scheduler and etcd static pods (move their manifests out and back, or restart the kubelet), then distribute the new `admin.conf`. Prevent it with an alert on certificate expiry and at least one upgrade a year.

</details>

### 5. Where users and groups come from

> **Say it in 30 seconds:** Nowhere inside Kubernetes. A group is a **string the authenticator attaches** to the
> request: the `O=` fields of a client cert, the `groups` claim of an OIDC token, or the automatic
> `system:serviceaccounts:<ns>` groups for ServiceAccounts. RBAC just compares names. Bind to **groups**, and manage
> membership in the identity provider.

**Go deeper**

- A typo is silent: a cert with `O=acme-dev` and a binding for `acme-devs` gives nothing, and nothing warns you.
- Everyone authenticated also gets `system:authenticated`. Never bind anything powerful to it.
- The **Extra** field carries other facts. Since recent releases it includes `authentication.kubernetes.io/credential-id` (the cert's SHA-256 fingerprint or the token's ID), so **audit logs can link a request to one exact credential**. RBAC ignores Extra, but webhooks and ValidatingAdmissionPolicy (`request.userInfo.extra`) can use it.

**Try it**

```bash
openssl req -new -key bob.key -subj "/CN=bob/O=acme-devs/O=oncall" -out bob.csr   # two groups
kubectl auth can-i --list -n acme-dev --as=bob --as-group=acme-devs              # impersonation: you pass groups yourself
```

<details markdown="1"><summary>Follow-up: how do you list the members of a group with kubectl?</summary>

You can't, because Kubernetes doesn't store membership. Ask the identity provider. With kubectl you can only list who the **group** is bound to: `kubectl get rolebindings,clusterrolebindings -A -o wide | grep <group>`.

</details>

---

## Part 2: Authorization: what may they do?

### 6. RBAC building blocks and a least-privilege design

> **Say it in 30 seconds:** Four objects. A **Role** lists allowed verbs on resources in one namespace; a
> **ClusterRole** does the same without a namespace. A **RoleBinding** grants a role to subjects in one namespace; a
> **ClusterRoleBinding** grants it cluster-wide. The common pattern is **ClusterRole + RoleBinding**: write the rules
> once, grant them per namespace. RBAC is **allow-only**: no deny rules, and access is the union of all bindings.

**Go deeper**

| Combination | Result |
|---|---|
| Role + RoleBinding | Rules and grant in one namespace |
| ClusterRole + RoleBinding | Shared rules, granted in **one** namespace (the tenant pattern) |
| ClusterRole + ClusterRoleBinding | Every namespace **and** cluster-scoped objects (nodes, namespaces, CRDs, cluster-scoped custom objects) |
| Role + ClusterRoleBinding | Not possible |

- Built-in roles: `view` (no Secrets), `edit` (includes Secrets, no RBAC), `admin` (adds RoleBindings in the namespace, but **can't** change ResourceQuota, LimitRange or the Namespace), `cluster-admin`.
- A design that works: **tenant humans get RoleBindings only**, to groups. **ClusterRoleBindings are for platform components**, preferably read-only.
- `roleRef` can't be changed after creation: delete and recreate, or use `kubectl auth reconcile`.
- **Aggregation:** a ClusterRole labelled `rbac.authorization.k8s.io/aggregate-to-view: "true"` adds its rules to `view`. Operators use it so everyone with `view` can read their CRDs.
- `resourceNames` can restrict get/update/delete/watch to named objects, but **not list or create**: the name isn't in the request.
- Other authorizers in the chain: **Node** (kubelets can only read what their pods need, with the NodeRestriction admission plugin) and optional **Webhook**.

**Try it:** [Tenant RBAC lab, step 4](tenant-rbac/README.md#4-rbac) (admin, developer, viewer and CI roles for one tenant).

<details markdown="1"><summary>Follow-up: a developer needs exec in dev but not in prod. How?</summary>

Give the shared `tenant-developer` ClusterRole in both namespaces through RoleBindings, and add a small `Role` with `create` on `pods/exec` (and `pods/portforward`) **only in dev**, bound to the same group. Since 1.31, exec over websockets needs `create` on `pods/exec`, not `get`.

</details>

### 7. Escalation guards and hidden escalation paths

> **Say it in 30 seconds:** You can't grant what you don't have. Creating a binding needs either every permission in
> the role, or the **`bind`** verb on it. Creating or editing a role needs either its permissions, or **`escalate`**.
> The paths that still lead to escalation are permissions that *look* harmless: **creating pods** (mount any Secret or
> ServiceAccount in the namespace), `impersonate`, approving CSRs, `nodes/proxy`, and editing webhook configurations.

**Go deeper:** permissions to treat as admin-level when you review RBAC:

| Permission | Why it is dangerous |
|---|---|
| `create pods` / `create deployments` | The pod can mount every Secret and use every ServiceAccount in the namespace |
| `get/list/watch secrets` | `list` returns the **contents** of every Secret, not just names |
| `impersonate` users/groups/serviceaccounts | Become anyone, including `system:masters` |
| `bind`, `escalate` on roles | Skip the escalation check |
| `create serviceaccounts/token` | Mint tokens for any ServiceAccount in the namespace |
| CSR `approve` on `kubernetes.io/kube-apiserver-client` | Issue a cert for any user or group |
| `nodes/proxy` | Talk to the kubelet API directly (exec into any pod on the node) |
| `patch namespaces` | Remove Pod Security labels |
| Writing `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` | Intercept or change every request |
| `*` on `*` | Includes everything above, and everything added in the future |

**Try it**

```bash
# as alice (tenant admin, real cert)
kubectl --context alice@ops-lab -n acme-dev create rolebinding oops --clusterrole=cluster-admin --user=alice   # Forbidden
kubectl --context alice@ops-lab -n acme-dev create rolebinding ok   --clusterrole=edit          --user=dave    # allowed
```

<details markdown="1"><summary>Follow-up: bob has no access to Secrets but can create pods. Is the Secret safe?</summary>

No. bob creates a pod that mounts the Secret as a volume (or uses a more powerful ServiceAccount in that namespace) and reads it. In a namespace, "can create pods" is equal to "can read every Secret and act as every ServiceAccount". Split sensitive workloads into their own namespace, and use Pod Security plus policy (Kyverno / ValidatingAdmissionPolicy) to restrict what pods may mount.

</details>

### 8. Proving who can do what

> **Say it in 30 seconds:** `kubectl auth can-i` answers one question. `can-i --list` shows everything an identity
> can do in a namespace. **Impersonation** (`--as`, `--as-group`) lets an admin test as someone else. To go the other
> way ("who can delete secrets?"), use a tool like `kubectl who-can` or `rbac-tool`. Do this as a regular **access
> review**, not only when something breaks.

**Go deeper**

- `can-i` uses the `SelfSubjectAccessReview` API. `SubjectAccessReview` (asking about someone else) is what webhooks and admission tools call.
- With impersonation you must pass groups yourself: `--as=bob` alone has none.
- Impersonating needs the `impersonate` verb, which is powerful, so audit who has it.
- `kubectl auth whoami` uses `SelfSubjectReview` and shows what the API server thinks you are, including groups from OIDC.

**Try it**

```bash
kubectl auth can-i --list -n acme-dev --as=bob --as-group=acme-devs
./tenant-rbac/scripts/check-rbac.sh                     # a full matrix with expected answers
kubectl get rolebindings,clusterrolebindings -A -o wide | grep -v system:
```

<details markdown="1"><summary>Follow-up: how would you find every subject that is effectively cluster-admin?</summary>

List ClusterRoleBindings to `cluster-admin`, plus any ClusterRole with `*` verbs on `*` resources, plus members of `system:masters` (only visible from certificates and audit logs, not RBAC). Also count anyone with `impersonate`, `escalate`/`bind` cluster-wide, or `create pods` in `kube-system`. Tools: `kubectl who-can '*' '*'`, `rbac-tool analysis`, Kubescape RBAC controls.

</details>

### 9. ServiceAccounts done safely

> **Say it in 30 seconds:** A ServiceAccount is the identity for workloads. Give **one ServiceAccount per app**, grant
> it only what the app calls, and set `automountServiceAccountToken: false` for apps that never talk to the API.
> Tokens are **short-lived and bound to the pod** (TokenRequest API). Avoid the old long-lived Secret tokens. For
> cloud access, use **workload identity** (EKS Pod Identity / IRSA, GKE Workload Identity, Azure Workload Identity)
> rather than cloud keys in Secrets.

**Go deeper**

- Every namespace has a `default` ServiceAccount. Don't bind roles to it: every pod that doesn't set a ServiceAccount gets it.
- Since 1.24, no Secret token is created automatically. Recent releases also clean up unused legacy tokens. Look for any `type: kubernetes.io/service-account-token` Secrets left in the cluster.
- A projected token has an **audience** and an **expiry**, and stops working when its pod is deleted.
- For CI outside the cluster, use `kubectl create token <sa> --duration=10m` per run, or better, the CI system's OIDC federated with the cluster.
- ServiceAccount usernames look like `system:serviceaccount:<ns>:<name>`. Their groups are `system:serviceaccounts` and `system:serviceaccounts:<ns>`.

**Try it**

```bash
TOKEN=$(kubectl create token acme-ci -n acme-prod --duration=10m)
kubectl --token="$TOKEN" auth whoami
kubectl --token="$TOKEN" -n acme-prod get pods      # Forbidden: the CI role only touches Deployments
```

<details markdown="1"><summary>Follow-up: a pod's token was stolen. How long does the attacker have?</summary>

Longer than you'd think. The token is bound to the pod, so **deleting the pod** invalidates it. Until then it is valid until it expires, and many clusters accept old tokens for up to a year for compatibility (`--service-account-extend-token-expiration`), even though the kubelet refreshes the file hourly. So first remove the ServiceAccount's RoleBindings, then delete the pod after you've collected evidence.

</details>

### 10. Locking down web consoles like the Kubernetes Dashboard

> **Say it in 30 seconds:** Treat any cluster UI as a front door to the API. Don't expose it to the internet: reach
> it through `kubectl port-forward`, a VPN, or an SSO proxy. Make users **log in as themselves** (OIDC through an
> auth proxy, or their own short token) so RBAC and audit logs see the real person. **Never** give the UI's own
> ServiceAccount cluster-admin.

**Go deeper**

- The classic failure is a Dashboard on a public IP whose ServiceAccount was cluster-admin. Attackers used it to run crypto miners.
- Deploy the UI with a minimal ServiceAccount (it needs almost nothing if users bring their own tokens), in its own namespace, with a NetworkPolicy allowing only the ingress proxy.
- Turn off any "skip login" option, use TLS, and set short session timeouts.
- Many teams now use **Headlamp**, Lens or the cloud console instead of the old Dashboard. Check each project's current status and security notes.

**Try it**

```bash
kubectl -n <ui-namespace> get sa,clusterrolebindings -o wide | grep -i dashboard
kubectl auth can-i --list --as=system:serviceaccount:<ui-namespace>:<ui-sa>
```

<details markdown="1"><summary>Follow-up: how do you give read-only UI access to a support team?</summary>

SSO login through an auth proxy → the support group gets the built-in `view` ClusterRole through RoleBindings in the namespaces they support (not cluster-wide, and `view` excludes Secrets). Their actions show under their own names in the audit log.

</details>

---

## Part 3: Isolation: keeping tenants apart

### 11. Building a secure tenant namespace

> **Say it in 30 seconds:** A tenant gets: namespaces labelled with the **tenant ID** and **Pod Security**; RoleBindings
> to **groups** (admin, developer, viewer, CI); a **ResourceQuota** (CPU, memory, object counts, no
> LoadBalancers/NodePorts); a **LimitRange** for defaults; and a **default-deny NetworkPolicy** that allows only the same
> tenant. The platform team owns the Namespace object, so tenants can't remove their own guardrails.

**Go deeper**

- Quota on `requests.cpu` makes every pod declare requests. Add a LimitRange with `defaultRequest`, or pods without resources are rejected.
- Quota is checked when an object is **created**. Lowering it doesn't kill running pods.
- `services.loadbalancers: "0"` and `services.nodeports: "0"` stop a tenant from opening the cluster to the outside.
- Make onboarding repeatable: a GitOps folder per tenant (Kustomize/Helm), a policy that generates the defaults (Kyverno generate rules), or a tenant CRD with a controller. Off-the-shelf: **Capsule**. For stronger isolation: **vCluster** (a virtual control plane per tenant) or separate clusters.
- **Soft vs hard multi-tenancy:** namespaces are fine for teams in one company. Untrusted tenants (customers running code) need separate nodes, sandboxed runtimes (gVisor, Kata) or separate clusters.

**Try it:** the whole [Tenant RBAC lab](tenant-rbac/README.md) builds this, then breaks it on purpose.

<details markdown="1"><summary>Follow-up: a team says "our deploy shows 0/3 ready and there are no pod events". Where do you look?</summary>

There are no pods, so there are no pod events. Look **one level up**: `kubectl describe rs` / `kubectl get events --field-selector reason=FailedCreate`. The ReplicaSet couldn't create the pods because of quota (`exceeded quota`), LimitRange (`maximum cpu usage per Container`), Pod Security (`violates PodSecurity`) or a webhook.

</details>

### 12. Pod Security Admission

> **Say it in 30 seconds:** A built-in admission controller that checks pods against the **Pod Security Standards**:
> `privileged`, `baseline` or `restricted`. You turn it on per namespace with labels, in three modes: **enforce**
> (reject), **warn** (message to the user) and **audit** (note in the audit log). It replaced PodSecurityPolicy,
> removed in 1.25.

**Go deeper**

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest   # or pin, e.g. v1.36, for predictable upgrades
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

- `restricted` needs: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault` (or Localhost), and no host namespaces, hostPath or privileged containers.
- **enforce applies to pods only.** A bad Deployment is accepted (you see a warning), and its ReplicaSet then fails with `FailedCreate`.
- Roll out safely: start with `warn` + `audit`, fix the workloads, then turn on `enforce`. `kubectl label --dry-run=server ns X pod-security.kubernetes.io/enforce=restricted` lists what would break.
- Exemptions (usernames, runtime classes, namespaces) are set in the API server's AdmissionConfiguration, not by tenants.
- PSA is all-or-nothing per level. For finer rules ("only images from our registry", "must have a team label"), add **Kyverno**, **Gatekeeper** or the built-in **ValidatingAdmissionPolicy** (CEL).

**Try it:** [Tenant RBAC lab, step 10c](tenant-rbac/README.md#10c-podsecurity-violation).

<details markdown="1"><summary>Follow-up: why can't a tenant admin just remove the PSA label?</summary>

Namespaces are cluster-scoped. The `admin` role is granted through a RoleBinding **inside** the namespace, so it gives no `patch` on the Namespace object itself. Only the platform team can change the labels.

</details>

### 13. Network isolation: NetworkPolicy and the CNI

> **Say it in 30 seconds:** By default every pod can reach every other pod. A NetworkPolicy selects pods and lists the
> allowed ingress and egress (by pod labels, namespace labels or IP blocks). Once a pod is selected by any policy, all
> other traffic in that direction is denied. Policies are **additive allow-lists**, and they only work if the **CNI
> enforces them** (Calico, Cilium, recent kindnet; not every CNI does).

**Go deeper**

- Standard pattern: `default-deny` per namespace, then allow same-tenant, ingress controller, monitoring and DNS.
- A default-deny **egress** breaks DNS until you allow UDP/TCP 53 to kube-dns.
- The **AND vs OR trap:** `namespaceSelector` and `podSelector` in the **same** `from` item means AND; as **two** items, it means OR.
- Kubernetes NetworkPolicy has **no deny rule and no cluster-wide scope**. Platform-wide rules that tenants can't override (for example "never reach 169.254.169.254, the cloud metadata service") come from CNI policies: Calico `GlobalNetworkPolicy`, `CiliumClusterwideNetworkPolicy`, or SIG Network's admin-level policy APIs where your CNI supports them.
- Cilium adds **L7** (HTTP paths, gRPC methods) and **FQDN** egress rules, plus Hubble to see which policy dropped a packet.
- NetworkPolicy doesn't encrypt traffic. For that, use a service mesh (mTLS) or CNI encryption (WireGuard/IPsec).

**Try it:** [Tenant RBAC lab, step 8](tenant-rbac/README.md#8-networkpolicy). Check that your CNI enforces policies: `kubectl get clusterrole kindnet -o yaml | grep -A2 networkpolicies`.

<details markdown="1"><summary>Follow-up: you applied a NetworkPolicy and traffic still flows. Why?</summary>

In order: (1) the CNI doesn't enforce NetworkPolicy; (2) the `podSelector` doesn't match the pods (label typo); (3) `policyTypes` doesn't include the direction you meant; (4) another policy allows it (policies add up); (5) the traffic is host-network or node-to-pod, which many CNIs treat differently.

</details>

### 14. CRDs, operators and the rights they need

> **Say it in 30 seconds:** A **CRD** teaches the API server a new type: it adds a REST endpoint, validates objects
> against its schema and stores them in etcd. An **operator** is an ordinary client: a pod with a ServiceAccount
> that **watches** that endpoint and acts. The CRD knows nothing about the operator. They only meet through the API
> server, and **RBAC decides what the operator may touch**.

**Go deeper**

```text
kubectl apply crd.yaml  ──► API server: new endpoint /apis/<group>/<version>/<plural>  (NamesAccepted, Established)
operator pod (SA token) ──► WATCH that endpoint + pods/quotas/... ──► writes status back ──► etcd
```

- Installing a CRD is cluster-admin work: it changes the API for everyone. **Deleting a CRD deletes every object of that type.**
- Give the operator `get/list/watch` on what it reads, and write access **only to its own CRDs and their `/status`**. The `status` subresource lets you split "users write spec, the operator writes status".
- The API server calls an operator only when you register a **webhook** (conversion or admission) or an **APIService**, and then through a Service. Admission webhooks are high-risk: they see or change every matching request, and a down webhook with `failurePolicy: Fail` blocks the cluster.
- A schema with `x-kubernetes-preserve-unknown-fields: true` skips validation and pruning. Fine for an early version, but a typed schema gives you validation and `kubectl explain`.

**Try it**

```bash
kubectl get crd <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
kubectl get --raw /apis/<group>/<version> | python3 -m json.tool
kubectl get <kind> <name> -o yaml --show-managed-fields | grep manager    # which client wrote it
```

<details markdown="1"><summary>Follow-up: the operator starts before its CRD is installed. What happens?</summary>

Its watch gets a 404 and it crash-loops (or logs errors) until the CRD is `Established`. Install CRDs first (Helm's `crds/` folder, a separate Argo CD sync wave), and wait: `kubectl wait --for=condition=Established crd/<name>`.

</details>

---

## Part 4: Supply chain and data

### 15. Trusting what you run: image security

> **Say it in 30 seconds:** Build from **small, trusted base images**, **scan** them in CI and in the registry,
> produce an **SBOM**, **sign** them (cosign/Sigstore), and **verify the signature at admission** so only signed
> images from approved registries run. Deploy by **digest**, not by tag. Run as non-root with a read-only root
> filesystem.

**Go deeper**

- Tags can be moved. A digest (`image@sha256:...`) is a promise about the exact bytes.
- Distroless or minimal images reduce what a scanner finds and what an attacker can use (no shell, no package manager).
- Verify at admission with Kyverno `verifyImages`, Sigstore policy-controller or Gatekeeper/Ratify. Restrict registries with policy.
- Attestations (SLSA provenance, SBOM, scan results) prove *how* the image was built, not just *who* signed it.
- Rebuild regularly: an unchanged image collects new CVEs over time.

**Try it:** [Lab 10: Supply chain](../lab-10-supply-chain/README.md) signs an image, attaches an SBOM and blocks unsigned images at admission.

<details markdown="1"><summary>Follow-up: what does a signature prove, and what doesn't it?</summary>

It proves the image hasn't changed since a trusted identity (a key, or a CI workflow's OIDC identity for keyless signing) signed it. It does **not** prove the image is free of vulnerabilities or was built from reviewed code. That's what scans, provenance attestations and branch protection are for.

</details>

### 16. Protecting Secrets

> **Say it in 30 seconds:** A Kubernetes Secret is only **base64**, not encrypted. Turn on **encryption at rest**
> for etcd (ideally with a KMS v2 provider), restrict `get/list/watch secrets` hard (`list` returns the contents), mount
> secrets as **files**, not environment variables, and keep the source of truth in a **secret manager** (Vault,
> cloud secret managers) synced in by External Secrets Operator or the Secrets Store CSI driver. Never put plain
> secrets in Git: use Sealed Secrets or SOPS if they must live there.

**Go deeper**

- Who can read a Secret: anyone with `get/list` on secrets, anyone who can **create pods** in that namespace (topic 7), and anyone with etcd or backup access.
- Environment variables leak into crash dumps, `/proc`, child processes and debug output. Files can be rotated without a restart.
- Rotation: short-lived dynamic credentials (Vault database secrets, cloud workload identity) beat rotating static ones.
- `immutable: true` protects against accidental changes and reduces API server watch load.
- Log secrets at `Metadata` level in audit logs: who touched them, never the content.

**Try it**

```bash
kubectl auth can-i get secrets -n acme-prod --as=bob --as-group=acme-devs     # no
kubectl get secrets -A -o json | jq -r '.items[] | select(.type=="kubernetes.io/service-account-token") | "\(.metadata.namespace)/\(.metadata.name)"'
```

<details markdown="1"><summary>Follow-up: how do you check that encryption at rest really works?</summary>

Create a test Secret, then read the raw value from etcd (`etcdctl get /registry/secrets/<ns>/<name>`). It must start with `k8s:enc:` (for example `k8s:enc:kms:v2:`), not readable text. After enabling encryption, rewrite existing Secrets (`kubectl get secrets -A -o json | kubectl replace -f -`) so old ones get encrypted too.

</details>

### 17. Finding and fixing vulnerabilities

> **Say it in 30 seconds:** Cover four layers: **images** (scan in CI, registry and running cluster), **cluster
> configuration** (CIS checks with kube-bench, Kubescape), **Kubernetes and node versions** (stay on supported
> minors, patch nodes), and **runtime** (detect exploitation with Falco or Tetragon). Prioritise by **real risk**
> (exploited in the wild, reachable, internet-facing), not by CVSS alone. Fix by rebuilding and rolling out through
> GitOps, with an SLA per severity.

**Go deeper**

- Kubernetes supports the newest three minor releases, about 14 months each. Falling behind means no security patches.
- Use KEV (known exploited) and EPSS (exploit likelihood) to rank. Use VEX to record "not affected" with a reason, so the same CVE isn't triaged again.
- An SBOM inventory answers "where do we run library X?" in minutes when the next big CVE drops.
- Patch the **base image** in one place and let rebuilds flow to every service (golden base images).
- Measure: open criticals by age, time-to-fix per severity, percentage of images rebuilt in the last 30 days.

**Try it**

```bash
trivy image busybox:1.37
trivy k8s --report summary cluster         # images and misconfigurations in the running cluster
docker run --rm --pid=host -v /etc:/etc:ro -v /var:/var:ro aquasec/kube-bench run --targets node   # on a node
```

<details markdown="1"><summary>Follow-up: a critical CVE hits a library in 200 images. What is your plan?</summary>

1) Find where it runs: SBOM search, plus scanner results for the running cluster. 2) Rank: internet-facing and reachable first; check for exploits and KEV. 3) Mitigate now where possible: WAF rule, NetworkPolicy, feature flag. 4) Fix the base image or dependency once, rebuild, roll out ring by ring. 5) Track until every affected image is gone, and record VEX for the ones that aren't affected.

</details>

---

## Part 5: Detect and respond

### 18. Audit logging

> **Say it in 30 seconds:** The API server can log **every request**: who (user, groups, credential ID), what (verb,
> resource, namespace, name), from where (source IP, user agent), and the result. An **audit policy** decides the
> detail level per request type: `None`, `Metadata`, `Request` or `RequestResponse`. Ship the logs to a SIEM. It's
> how you answer "who deleted that?" and how you prove access controls to an auditor.

**Go deeper**

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
- level: None                       # noisy and harmless
  resources: [{ group: "", resources: ["events"] }]
- level: Metadata                   # who touched secrets, never the content
  resources: [{ group: "", resources: ["secrets", "configmaps"] }]
- level: RequestResponse            # full detail for RBAC changes
  resources: [{ group: "rbac.authorization.k8s.io" }]
- level: Metadata                   # everything else
```

- Stages: `RequestReceived`, `ResponseStarted` (long watches), `ResponseComplete`, `Panic`. Backends: a log file or a webhook.
- `RequestResponse` on everything is huge and can leak secrets. Be selective.
- Managed clusters: enable control-plane audit logs in the cloud console (they're often off by default) and set retention.
- Good alerts: new ClusterRoleBinding to cluster-admin, exec into pods in prod, `impersonate` used, Secrets listed cluster-wide, requests from `system:anonymous`, a ServiceAccount used from an unexpected IP.

**Try it:** on kind, pass `--audit-policy-file` and `--audit-log-path` through `kubeadmConfigPatches` and mount the policy with `extraMounts`, then `docker exec ops-lab-control-plane tail -f /var/log/kubernetes/audit.log | jq`.

<details markdown="1"><summary>Follow-up: audit logs show a ServiceAccount listing Secrets in every namespace. What next?</summary>

Find which bindings give it that right and remove them now. Check the `credential-id` and source IP to see whether it's the real pod or a stolen token. Look at everything else that identity did (and rotate the Secrets it could have read). Then find out how the permission got there: a Helm chart? a manual change? Fix that process.

</details>

### 19. A container is compromised: the first hour

> **Say it in 30 seconds:** **Contain, preserve, investigate, eradicate, recover, learn.** Isolate the pod with a
> deny-all NetworkPolicy and take it out of its Service. Remove its ServiceAccount's permissions. Keep the pod and node
> for evidence (don't just delete it). Use audit logs to see what its identity did, rotate every secret it could
> reach, then redeploy from a clean, patched image and write the post-mortem.

**Go deeper**

```bash
# 1. Contain: take it out of the ReplicaSet and Service (the RS starts a clean replacement), then cut its network
kubectl -n prod label pod web-abc app- quarantine=true
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: quarantine }
spec:
  podSelector: { matchLabels: { quarantine: "true" } }
  policyTypes: ["Ingress", "Egress"]          # no rules = nothing in, nothing out
EOF
kubectl cordon <node>                          # no new pods on that node

# 2. Cut its identity: remove the ServiceAccount's bindings (a stolen token may be valid for a long time)
kubectl -n prod get rolebindings -o wide | grep <sa>

# 3. Preserve: spec, logs, events, and optionally a forensic checkpoint of the container (kubelet checkpoint API)
kubectl -n prod get pod web-abc -o yaml > evidence/pod.yaml
kubectl -n prod logs web-abc --all-containers --timestamps > evidence/logs.txt
kubectl -n prod get events --field-selector involvedObject.name=web-abc > evidence/events.txt
```

- Investigate: audit logs for the ServiceAccount's username and the node, runtime alerts (Falco), image scan results, how the attacker got in (vulnerable app? leaked credential?).
- Eradicate and recover: patch the cause, rebuild, roll out; rotate secrets and tokens; drain and rebuild the node if there's any sign of escape.
- Learn: add the detection rule that would have caught it sooner, and the policy that would have stopped it (read-only root filesystem, no shell in the image, tighter egress).

<details markdown="1"><summary>Follow-up: why not just delete the pod?</summary>

Deleting it destroys evidence (memory, files the attacker dropped, process list) and you learn nothing about how they got in, so they come back. It also doesn't end the threat: secrets and tokens they copied still work elsewhere. Isolate first, collect, then delete.

</details>

---

## Part 6: Running a security program

### 20. Proving compliance

> **Say it in 30 seconds:** Map the framework (CIS Kubernetes Benchmark, NSA/CISA hardening, PCI DSS, SOC 2, ISO 27001)
> to **controls**, enforce the controls as **policy as code**, and collect **evidence automatically**: CIS scan
> reports, policy reports, audit logs, Git history for every change, and regular access reviews. Compliance should be
> continuous, not a yearly scramble.

**Go deeper**

| Auditor asks | Evidence you show |
|---|---|
| Who has admin access, and who approved it? | RoleBindings in Git, pull request approvals, quarterly access review export |
| How are changes controlled? | GitOps history (Argo CD), branch protection, signed commits |
| Are workloads hardened? | PSA labels, Kyverno/Gatekeeper PolicyReports, Kubescape framework score |
| Is data encrypted? | etcd encryption config, TLS everywhere, KMS key policy |
| Can you trace actions to people? | Audit logs with retention, SSO identities (no shared accounts) |
| Is the software trusted? | Image signatures, SBOMs, scan reports per release |

<details markdown="1"><summary>Follow-up: a policy would block 40 existing workloads. How do you roll it out?</summary>

Audit mode first (Kyverno `Audit`, Gatekeeper `dryrun`, PSA `warn` + `audit`), publish the report to the owning teams with a deadline and a fix guide, allow time-boxed exceptions with an owner and expiry, then switch to enforce ring by ring. See [Lab 5: Guardrails](../lab-05-guardrails/README.md).

</details>

### 21. Toolbox by layer

> **Say it in 30 seconds:** Pick one tool per layer and wire it into the platform, not a long list. Identity: OIDC
> provider. Policy: Kyverno or Gatekeeper (or built-in ValidatingAdmissionPolicy). Supply chain: Trivy or Grype,
> Syft, cosign. Config posture: kube-bench, Kubescape. Runtime: Falco or Tetragon. Network: Cilium or Calico. Secrets:
> Vault or cloud secret managers with External Secrets.

| Layer | Tools |
|---|---|
| Identity and access | OIDC (Okta, Entra ID, Keycloak) + kubelogin; `kubectl who-can`, rbac-tool for reviews |
| Admission and policy | Pod Security Admission, ValidatingAdmissionPolicy (CEL), Kyverno, OPA Gatekeeper |
| Images and supply chain | Trivy, Grype, Syft (SBOM), cosign / Sigstore, Kyverno `verifyImages`, Harbor |
| Configuration posture | kube-bench (CIS), Kubescape, Polaris, Trivy `k8s` |
| Runtime detection | Falco, Tetragon, cloud runtime security (Defender, GuardDuty EKS, GKE Security Posture) |
| Network | Cilium (with Hubble), Calico, a service mesh for mTLS (Istio, Linkerd) |
| Secrets | Vault, cloud secret managers, External Secrets Operator, Secrets Store CSI, Sealed Secrets, SOPS |
| Logging and SIEM | API server audit logs → Loki / Elastic / Splunk / cloud SIEM |

<details markdown="1"><summary>Follow-up: Kyverno or Gatekeeper?</summary>

Kyverno: policies are YAML, it can **mutate** and **generate** resources (useful for tenant defaults) and verify images. Easy for platform teams. Gatekeeper: Rego (OPA), powerful and shared with non-Kubernetes OPA use. For simple validation, the built-in ValidatingAdmissionPolicy needs no extra component at all. Choose by what the team can maintain.

</details>

### 22. Hardening checklist

> **Say it in 30 seconds:** Lock the control plane (private endpoint, no anonymous access, audit on, etcd encrypted
> and backed up), harden nodes (minimal OS, patched, no SSH, kubelet authz on), use SSO and least-privilege RBAC to
> groups, enforce Pod Security `restricted`, default-deny networking, signed and scanned images, external secrets, and
> runtime detection. Then **test it**: try to break your own rules, like the lab does.

- [ ] API server not public, or behind an allow-list. Anonymous auth limited to health checks.
- [ ] Audit logging on, shipped off-cluster, alerts on RBAC changes and exec in prod.
- [ ] etcd: encryption at rest, TLS, encrypted backups, access only from the API server.
- [ ] Nodes: minimal image, automatic patching, kubelet `--anonymous-auth=false`, authorization `Webhook`, read-only port off.
- [ ] People log in through OIDC. No shared admin certs. Break-glass access is logged and reviewed.
- [ ] RBAC: groups only, no `*`, no cluster-admin for daily work, regular access reviews.
- [ ] Every namespace: PSA labels, quota, LimitRange, default-deny NetworkPolicy, tenant owner label.
- [ ] Egress control, including blocking the cloud metadata IP from pods.
- [ ] Images: approved registries, signed, scanned, deployed by digest, non-root, read-only root filesystem.
- [ ] Secrets: encrypted, from a secret manager, mounted as files, rotated.
- [ ] Runtime detection running and someone on call for its alerts.
- [ ] Kubernetes on a supported minor version, upgraded at least yearly (which also renews kubeadm certs).

<details markdown="1"><summary>Follow-up: you have one week on a new cluster. What do you fix first?</summary>

The things that turn one mistake into a full compromise: public API server and Dashboard exposure, cluster-admin bindings to people and to default ServiceAccounts, privileged pods (turn on PSA `baseline` enforce plus `restricted` warn), audit logging, and etcd encryption. Then default-deny networking and image policy.

</details>

### 23. Staying current

> **Say it in 30 seconds:** I follow the official sources (the **kubernetes-security-announce** mailing list, the
> **official Kubernetes CVE feed**, and release notes with their deprecations), the advisories of the CNIs, operators
> and the managed service we run, and CNCF TAG Security and KubeCon talks. Then I **practise** in a lab: reading about
> an attack isn't the same as having tried it.

- Subscribe the team channel to the CVE feed and to vendor advisories, and review them weekly.
- Read the "Urgent upgrade notes" and deprecations of every Kubernetes release before you upgrade.
- Certification path: CKA, then **CKS** (Certified Kubernetes Security Specialist).
- Rebuild a lab cluster regularly and rerun kube-bench, Kubescape and this guide's "Try it" commands.

---

## Quick self-test

Answer each in one sentence, then check against the topic.

1. Which four RBAC combinations exist, and which one gives shared rules in only one namespace? (6)
2. Why can't a tenant admin remove Pod Security from their namespace? (12)
3. What does `--as=bob` without `--as-group` test? (5, 8)
4. Name three permissions that are admin-level even though they don't say "admin". (7)
5. What happens to running pods when you lower a quota? (11)
6. Why do humans get OIDC rather than client certificates? (3, 4)
7. Where does the cluster CA private key live, and why does it matter? (3)
8. What makes a NetworkPolicy do nothing at all? (13)
9. Why isolate a compromised pod before deleting it? (19)
10. What does an image signature *not* prove? (15)
