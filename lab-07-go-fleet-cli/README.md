# Lab 7: A fleet audit CLI in Go (client-go)

**Time:** about 60 minutes · **Level:** some Go helps · **Needs:** the fleet from Setup

Platform teams write small tools that look at **every** cluster at once. You'll write one:
`fleetcheck` lists, for every context in your kubeconfig, the namespaces that are missing a
label (for example `cost-center`, needed for cost reports in Lab 11).

The point isn't just making it work. It's the structure reviewers look for: **contexts with
timeouts, concurrency, error handling, exit codes and a unit test**.

---

## Part A: The ideas in plain words

| Idea | Plain meaning |
|---|---|
| **client-go** | The official Go library that `kubectl` itself uses to talk to the API server |
| **kubeconfig loading rules** | The same rules kubectl uses: read `$KUBECONFIG` (it can be a `:`-separated list), else `~/.kube/config` |
| **clientset** | A typed client: `cs.CoreV1().Namespaces().List(...)` |
| **`kubernetes.Interface`** | The interface a clientset implements. Code that takes the interface can be tested with a **fake** clientset, no cluster needed |
| **`context.WithTimeout`** | A deadline. One dead cluster must not hang the whole run |
| **fan-out** | One goroutine per cluster, all at the same time, wait for all (`sync.WaitGroup`) |
| **exit codes** | Scripts and CI read them: 0 = all good, 1 = findings, 2 = couldn't check a cluster |

```text
$KUBECONFIG ─► load all contexts ─► for each context, in parallel (each with a timeout):
                                       build a clientset ─► list namespaces (paginated) ─► missing label?
                                    ─► collect results in order ─► print ─► exit 0 / 1 / 2
```

---

## The task

1. Install Go (1.22 or newer): `brew install go`, then `go version`.
2. Create the module:
   ```bash
   mkdir -p ~/idp-lab/go/fleetcheck && cd ~/idp-lab/go/fleetcheck
   go mod init fleetcheck
   go get k8s.io/client-go@v0.31.0 k8s.io/apimachinery@v0.31.0 k8s.io/api@v0.31.0
   ```
3. The CLI must:
   - load `$KUBECONFIG` and check **every context** (hub, cell-1, cell-2);
   - take `--label` (default `cost-center`) and `--timeout` (default `10s`);
   - query the contexts **concurrently**, each with its own timeout;
   - keep going when one cluster is unreachable: report it, then continue;
   - print results **grouped by context and sorted**;
   - exit **1** if any namespace is missing the label, **2** if a cluster couldn't be checked, **0** otherwise.
4. Stretch goals:
   - `--output json`;
   - a unit test with `k8s.io/client-go/kubernetes/fake`;
   - a `--fix` flag that adds a default label, with a dry run first.

### Hints (open one at a time)

<details><summary>Hint 1: load every context</summary>

```go
rules := clientcmd.NewDefaultClientConfigLoadingRules()   // honours $KUBECONFIG
cfg, err := rules.Load()                                   // *clientcmdapi.Config
for name := range cfg.Contexts { ... }                     // map: sort the names yourself
```
</details>

<details><summary>Hint 2: a clientset for one context</summary>

```go
rest, err := clientcmd.NewNonInteractiveClientConfig(*cfg, name, &clientcmd.ConfigOverrides{}, rules).ClientConfig()
rest.Timeout = timeout          // also bounds the TCP dial and TLS handshake
cs, err := kubernetes.NewForConfig(rest)
```
</details>

<details><summary>Hint 3: make it testable</summary>

Keep "ask the cluster" apart from "print the report":

```go
func Missing(ctx context.Context, cs kubernetes.Interface, label string) ([]string, error)
```

In the test: `cs := fake.NewSimpleClientset(&corev1.Namespace{...}, ...)`.
</details>

<details><summary>Hint 4: concurrency without a mutex</summary>

Make `results := make([]result, len(names))` and let goroutine `i` write only `results[i]`.
Nothing is shared, so there's no lock, and the output order is stable.
</details>

<details><summary>Hint 5: big clusters</summary>

`List` with `Limit: 500` and follow `Continue` until it's empty (pagination). A cluster with
5,000 namespaces shouldn't be one giant response.
</details>

---

## Check your work

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/go/fleetcheck
go vet ./... && go test ./... && go build -o fleetcheck .

./fleetcheck --label cost-center;                 echo "exit=$?"   # expect 1
./fleetcheck --label kubernetes.io/metadata.name; echo "exit=$?"   # every namespace has it: expect 0
```

Prove that one dead cluster doesn't hang or crash the run. Add a fake context that points at
a closed port:

```bash
cat > /tmp/gone.kubeconfig <<'EOF'
apiVersion: v1
kind: Config
clusters: [{name: gone, cluster: {server: "https://127.0.0.1:6599", insecure-skip-tls-verify: true}}]
users: [{name: gone, user: {token: x}}]
contexts: [{name: gone, context: {cluster: gone, user: gone}}]
EOF
KUBECONFIG=~/idp-lab/fleet.kubeconfig:/tmp/gone.kubeconfig ./fleetcheck --label kubernetes.io/metadata.name --timeout 3s; echo "exit=$?"
```

**You should see** (from the reference solution):

```text
cell-1   ok: every namespace has "kubernetes.io/metadata.name"
cell-2   ok: every namespace has "kubernetes.io/metadata.name"
gone     ERROR Get "https://127.0.0.1:6599/api/v1/namespaces?limit=500": dial tcp 127.0.0.1:6599: connect: connection refused
hub      ok: every namespace has "kubernetes.io/metadata.name"
exit=2
```

---

## Reference solution

[`solution/`](solution/): `main.go` (flags, fan-out, output, exit codes), `audit.go` (the
testable `Missing` function with pagination), `audit_test.go` (fake clientset). Try it yourself
first, then compare.

```bash
cd ~/idp-lab/platform-labs/lab-07-go-fleet-cli/solution && go test ./... && go run . --label cost-center
```

---

## Questions to think through

1. **Turn this into a controller: what changes?** Informers and a work queue instead of `List`;
   level-triggered reconcile; idempotency; rate limiting; leader election; status conditions;
   owner references.
2. **Sketch a tenant operator.** A `Tenant` custom resource gives a namespace, quota,
   NetworkPolicy, RBAC and a cost label. What goes in `spec` and what in `status`? How does a
   **finalizer** handle offboarding (delete in the right order, keep an audit trail)?
3. **When would you *not* write an operator?** When Kyverno `generate` (Lab 5) or a Crossplane
   composition (Lab 9) already does it. Every operator is code you maintain and keep on call.
4. **Why is the per-cluster timeout needed when you already have a context?** `rest.Timeout`
   also limits the dial and TLS handshake; the context limits the whole request. With 100 cells,
   one hung cluster must not set the speed of the run.
