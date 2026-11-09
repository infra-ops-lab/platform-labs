# Quiz: test yourself

80 multiple-choice questions on every lab. Pick an answer, then open **Show answer**.

**Interactive version** (random order, filter by lab, score): [play the quiz](play.html)
(on the website; on GitHub the link shows the page source).

This page is generated from `quiz/questions.json` by `tools/quiz-to-md.py`. Edit the JSON, not this file.

## Lab 0: Fleet tour

**1.** How does Argo CD on the hub know that cell-1 exists?

- **a)** Gitea tells it
- **b)** You ran `argocd cluster add cell-1`
- **c)** It reads `~/idp-lab/fleet.kubeconfig`
- **d)** A Secret in the `argocd` namespace labelled `argocd.argoproj.io/secret-type=cluster`

<details markdown="1"><summary>Show answer</summary>

**d)** A Secret in the `argocd` namespace labelled `argocd.argoproj.io/secret-type=cluster`

Argo CD discovers clusters from Secrets labelled `argocd.argoproj.io/secret-type=cluster` holding the API address and credentials. `argocd cluster add` is only a shortcut that creates such a Secret; at fleet scale you create them with automation.

</details>

**2.** Why does the clusters generator select `fleet.lab/cell` with `operator: Exists`?

- **a)** Because Argo CD requires every generator to have a selector
- **b)** So only cells match: the hub's in-cluster entry has no `fleet.lab/cell` label
- **c)** To sort the cells by name
- **d)** To include the hub as a cell

<details markdown="1"><summary>Show answer</summary>

**b)** So only cells match: the hub's in-cluster entry has no `fleet.lab/cell` label

Without a selector the clusters generator also returns the hub (`in-cluster`). Selecting on a label that only cell Secrets carry keeps workloads off the hub.

</details>

**3.** `kubectl get pods` fails with an error about `localhost:8080` and openapi. What is the most likely cause?

- **a)** Kyverno blocked the request
- **b)** Argo CD is down
- **c)** The cell's API server is overloaded
- **d)** `KUBECONFIG` is not set, so kubectl falls back to `localhost:8080`, which on this laptop is Argo CD's port

<details markdown="1"><summary>Show answer</summary>

**d)** `KUBECONFIG` is not set, so kubectl falls back to `localhost:8080`, which on this laptop is Argo CD's port

With no kubeconfig, kubectl defaults to `http://localhost:8080`. In this lab that port is the Argo CD UI, so you get confusing errors. Fix: `export KUBECONFIG=~/idp-lab/fleet.kubeconfig`.

</details>

**4.** You must put 100 existing clusters behind one Argo CD. What is the engineering way?

- **a)** Generate the cluster Secrets (with labels) from an inventory using automation, and let ApplicationSets select on the labels
- **b)** Run `argocd cluster add` 100 times by hand
- **c)** Install a separate Argo CD in each cluster and stop there
- **d)** Share one kubeconfig with everyone

<details markdown="1"><summary>Show answer</summary>

**a)** Generate the cluster Secrets (with labels) from an inventory using automation, and let ApplicationSets select on the labels

Treat clusters as data: an inventory (like `cells.conf`) produces labelled Secrets via Terraform, Crossplane or a script. ApplicationSets then target clusters by label, so adding cluster 101 is one more inventory line.

</details>

**5.** In this lab, what are `cell` and `ring`?

- **a)** Kubernetes built-in concepts
- **b)** Argo CD resource kinds
- **c)** Kind node roles
- **d)** Label names we chose: a cell is a workload cluster, a ring is its rollout wave

<details markdown="1"><summary>Show answer</summary>

**d)** Label names we chose: a cell is a workload cluster, a ring is its rollout wave

They are conventions. They only mean something because ApplicationSets and RollingSync select on them. You could call them block and flat as long as you change every place that uses them.

</details>

## Lab 1: Fleet GitOps

**6.** The fleet ApplicationSet combines which two generators?

- **a)** list + list
- **b)** pullRequest + clusters
- **c)** scmProvider (Gitea org `golden`) × clusters (cells), in a matrix
- **d)** git + list

<details markdown="1"><summary>Show answer</summary>

**c)** scmProvider (Gitea org `golden`) × clusters (cells), in a matrix

scmProvider finds every repo in the `golden` org; clusters finds every cell. The matrix creates one Application per repo × cell.

</details>

**7.** There are 3 repos with a `deploy/` folder and 2 cells. How many Applications does the fleet ApplicationSet create?

- **a)** 6
- **b)** 3
- **c)** 2
- **d)** 5

<details markdown="1"><summary>Show answer</summary>

**a)** 6

Matrix = product: 3 repos × 2 cells = 6 Applications, named `<repo>-<cell>`.

</details>

**8.** What does `filters: [{pathsExist: [deploy]}]` do in the scmProvider generator?

- **a)** Creates a `deploy/` folder in every repo
- **b)** Deploys only the files in `deploy/` to the hub
- **c)** Deletes repos without `deploy/`
- **d)** Only repos that contain a `deploy/` folder produce Applications

<details markdown="1"><summary>Show answer</summary>

**d)** Only repos that contain a `deploy/` folder produce Applications

It's an opt-in convention: a repo becomes a deployable service by having `deploy/`. Docs repos or libraries in the same org are ignored.

</details>

**9.** Why does the template build `repoURL` from `gitea-http.gitea.svc:3000` instead of using the clone URL Gitea reports?

- **a)** The in-cluster name is faster to type
- **b)** Gitea reports a `localhost` URL that only works from your laptop, not from Argo CD inside the hub
- **c)** Argo CD cannot use HTTPS
- **d)** Gitea's API returns no clone URL

<details markdown="1"><summary>Show answer</summary>

**b)** Gitea reports a `localhost` URL that only works from your laptop, not from Argo CD inside the hub

Inside the hub, `localhost` is the Argo CD pod itself. Argo CD must use the in-cluster Service name to reach Gitea.

</details>

**10.** What does `goTemplateOptions: ["missingkey=error"]` protect you from?

- **a)** Slow template rendering
- **b)** Duplicate Application names
- **c)** A template silently rendering an empty value when a label or field is missing
- **d)** Missing Git credentials

<details markdown="1"><summary>Show answer</summary>

**c)** A template silently rendering an empty value when a label or field is missing

Without it, a missing key (for example a cluster without the ring label) renders as empty or `<no value>` and you get a broken Application instead of a clear error.

</details>

## Lab 2: Golden path

**11.** In the Backstage template, what does the `fetch:template` step do?

- **a)** Downloads the template from the internet
- **b)** Copies the skeleton and fills in the form values (`${{ values.name }}`)
- **c)** Creates the Gitea repo
- **d)** Registers the component in the catalog

<details markdown="1"><summary>Show answer</summary>

**b)** Copies the skeleton and fills in the form values (`${{ values.name }}`)

`fetch:template` renders the skeleton folder with the parameters. `publish:gitea` then creates and pushes the repo, and `catalog:register` adds `catalog-info.yaml` to the catalog.

</details>

**12.** Why do the golden-path selectors use only `name`, `instance` and `part-of`, and not the `tier` label?

- **a)** Kustomize doesn't support more than three labels
- **b)** Argo CD ignores the tier label
- **c)** A Deployment's selector is immutable, so a label that may change (like tier) must never be in it
- **d)** Kyverno requires exactly three labels

<details markdown="1"><summary>Show answer</summary>

**c)** A Deployment's selector is immutable, so a label that may change (like tier) must never be in it

Changing a selector later is rejected by the API server. Stable identity labels go in selectors; changeable labels go only on objects and pod templates (`includeSelectors: false`).

</details>

**13.** Every Backstage page showed a red 'Failed to fetch' overlay. What was the cause?

- **a)** Wrong Node.js version
- **b)** Gitea was down
- **c)** The default home page's Random Joke widget calls a public API that returned 503, and the dev overlay shows any error
- **d)** The catalog database was corrupt

<details markdown="1"><summary>Show answer</summary>

**c)** The default home page's Random Joke widget calls a public API that returned 503, and the dev overlay shows any error

The fix was to disable the widget in `app-config.yaml` (`home-page-widget:home/random-joke: false`). A good reminder: the portal should not depend on random external APIs.

</details>

**14.** How does Backstage find the golden-path template file?

- **a)** A catalog `location` in app-config points at `templates/*/template.yaml`
- **b)** Argo CD pushes it to Backstage
- **c)** You upload it in the UI each time
- **d)** It scans the whole disk

<details markdown="1"><summary>Show answer</summary>

**a)** A catalog `location` in app-config points at `templates/*/template.yaml`

Templates are catalog entities of kind `Template`, loaded from catalog locations. When the file was in the wrong folder, the template simply didn't appear.

</details>

**15.** Which guardrail is built into the golden-path template itself (not added later by a policy)?

- **a)** Image signing
- **b)** A cost-center budget
- **c)** A pinned image tag and the `app.kubernetes.io/part-of` label
- **d)** A Kafka topic

<details markdown="1"><summary>Show answer</summary>

**c)** A pinned image tag and the `app.kubernetes.io/part-of` label

The paved road makes the safe choice the default: pinned image, standard labels, probes, resources and a locked-down securityContext. That's why tenant-api passed the Lab 5 guardrails without changes.

</details>

## Lab 3: Run the golden path

**16.** Before running the template, must the `tenant-api` repo already exist in Gitea?

- **a)** Yes, the template only updates existing repos
- **b)** Yes, and it must be empty
- **c)** No, `publish:gitea` creates it
- **d)** Only if it is public

<details markdown="1"><summary>Show answer</summary>

**c)** No, `publish:gitea` creates it

The scaffolder creates the repo, pushes the rendered skeleton and registers it. If the repo already exists, publish fails.

</details>

**17.** After Backstage creates the repo, who deploys the service to the cells?

- **a)** Backstage calls `kubectl apply`
- **b)** The fleet ApplicationSet's scmProvider sees the new repo with `deploy/` and Argo CD syncs it to every cell
- **c)** The developer runs Helm
- **d)** Gitea Actions

<details markdown="1"><summary>Show answer</summary>

**b)** The fleet ApplicationSet's scmProvider sees the new repo with `deploy/` and Argo CD syncs it to every cell

Backstage only creates the repo. GitOps does the rest: the new repo matches the generator, so Applications appear for each cell automatically.

</details>

**18.** Which statement is correct?

- **a)** Argo CD is the source of truth
- **b)** The cluster is the source of truth
- **c)** Backstage is the source of truth for deployments
- **d)** Git is the source of truth; Backstage is the portal; Argo CD delivers

<details markdown="1"><summary>Show answer</summary>

**d)** Git is the source of truth; Backstage is the portal; Argo CD delivers

Backstage creates and shows things, but what runs is decided by Git. If Backstage disappeared, deployments would keep working.

</details>

**19.** How does Backstage authenticate to Gitea to create repos?

- **a)** The `integrations.gitea` config with a username and an access token from the `GITEA_TOKEN` environment variable
- **b)** Argo CD's credentials
- **c)** SSH keys stored in the catalog
- **d)** Anonymous access

<details markdown="1"><summary>Show answer</summary>

**a)** The `integrations.gitea` config with a username and an access token from the `GITEA_TOKEN` environment variable

The token comes from the environment and is never written into a file in Git. In a company this would be a bot account with minimal scope.

</details>

## Lab 4: Progressive delivery

**20.** What must be enabled before RollingSync works?

- **a)** A Kyverno policy
- **b)** Nothing, it's on by default
- **c)** Argo Rollouts
- **d)** `applicationsetcontroller.enable.progressive.syncs: "true"` in the Argo CD config

<details markdown="1"><summary>Show answer</summary>

**d)** `applicationsetcontroller.enable.progressive.syncs: "true"` in the Argo CD config

Progressive syncs are an opt-in ApplicationSet controller feature, set in `argocd-cmd-params-cm`, followed by a controller restart.

</details>

**21.** With RollingSync on, what happens to automated sync on each generated Application?

- **a)** Nothing changes
- **b)** It is doubled
- **c)** Prune is disabled forever
- **d)** It is turned off (`automated.enabled: false`), and the ApplicationSet controller triggers syncs step by step

<details markdown="1"><summary>Show answer</summary>

**d)** It is turned off (`automated.enabled: false`), and the ApplicationSet controller triggers syncs step by step

If every app auto-synced on its own, there would be no ordering. The controller takes over and syncs ring 0 first, then ring 1.

</details>

**22.** When does cell-2 (ring 1) start syncing a change?

- **a)** Only when you click Sync
- **b)** After 3 minutes, whatever happens
- **c)** At the same time as cell-1
- **d)** After every ring-0 Application is Healthy

<details markdown="1"><summary>Show answer</summary>

**d)** After every ring-0 Application is Healthy

Each RollingSync step waits for the previous step's apps to be Healthy. A Degraded ring 0 stops the rollout.

</details>

**23.** You changed a deployment in the Gitea UI and the checker didn't see a revert. Which commit message did it look for?

- **a)** One starting with `Revert`, as created by `git revert`
- **b)** A tag named `rollback`
- **c)** One starting with `Fix`
- **d)** Any commit by `labadmin`

<details markdown="1"><summary>Show answer</summary>

**a)** One starting with `Revert`, as created by `git revert`

`git revert` creates a commit like `Revert "Scale tenant-api to 3 replicas"` that records what was undone. A manual edit gives the same files but loses that history.

</details>

**24.** Someone runs `kubectl scale` on an app that has `selfHeal: true`. What happens?

- **a)** Argo CD detects drift and puts the Git value back
- **b)** The new replica count stays
- **c)** Argo CD deletes the app
- **d)** The change is pushed to Git

<details markdown="1"><summary>Show answer</summary>

**a)** Argo CD detects drift and puts the Git value back

selfHeal reconciles the cluster to Git. Changes must go through Git, or they will be undone.

</details>

**25.** Your fix makes cell-1 Healthy. In the same second, cell-2 syncs, but with the old bad commit. Why can that happen?

- **a)** Healthy is not tied to a commit: cell-2 synced the revision Argo CD had last fetched for it, before its refresh
- **b)** Gitea served the wrong commit
- **c)** RollingSync is broken
- **d)** Kyverno changed the revision

<details markdown="1"><summary>Show answer</summary>

**a)** Healthy is not tied to a commit: cell-2 synced the revision Argo CD had last fetched for it, before its refresh

A real race seen in Lab 6. Good habit: after a fix, refresh every app before the next ring starts. And keep canaries in each cell as a second line of defence.

</details>

## Lab 5: Guardrails

**26.** What is the difference between Audit and Enforce in a Kyverno validate rule?

- **a)** Audit applies only to Deployments
- **b)** Audit blocks; Enforce only reports
- **c)** There is no difference
- **d)** Audit allows the request and records the violation in a PolicyReport; Enforce rejects it

<details markdown="1"><summary>Show answer</summary>

**d)** Audit allows the request and records the violation in a PolicyReport; Enforce rejects it

Audit first lets you see who would be broken, fix them (and the golden path), then switch to Enforce.

</details>

**27.** A policy moves to Enforce. A pod already running breaks the rule. What happens?

- **a)** It is deleted immediately
- **b)** It keeps running and shows as fail in the PolicyReport; its next create or change is blocked
- **c)** It restarts with the fix
- **d)** Argo CD rolls it back

<details markdown="1"><summary>Show answer</summary>

**b)** It keeps running and shows as fail in the PolicyReport; its next create or change is blocked

Admission only runs on create and update. The trap is the next event (eviction, scale-up, new sync): the replacement is denied, as happened to `hello1`.

</details>

**28.** A namespace gets `tenant.lab/id=acme`. What does the generate policy create in it?

- **a)** NetworkPolicy (default deny), ResourceQuota, LimitRange
- **b)** PolicyReport, PolicyException, ClusterPolicy
- **c)** Role, RoleBinding, ServiceAccount
- **d)** Deployment, Service, Ingress

<details markdown="1"><summary>Show answer</summary>

**a)** NetworkPolicy (default deny), ResourceQuota, LimitRange

One label is the whole onboarding. With `synchronize: true`, Kyverno also recreates the objects if someone deletes them.

</details>

**29.** With only the rule `image: "!*:latest"`, which image gets through even though it actually runs latest?

- **a)** `docker.io/library/nginx:latest`
- **b)** `nginx:1.27`
- **c)** `nginx`
- **d)** `nginx:latest`

<details markdown="1"><summary>Show answer</summary>

**c)** `nginx`

No tag means `:latest`, but the string `nginx` doesn't end in `:latest`. That's why the policy got a second rule: `require-image-tag` (`*:*`).

</details>

**30.** A team wants an exception to `require-part-of-label`. What is the better approach?

- **a)** Delete the policy
- **b)** Add their namespace to the policy's exclude list
- **c)** Switch the policy back to Audit for everyone
- **d)** A separate, time-boxed PolicyException for that workload, reviewed and visible in reports

<details markdown="1"><summary>Show answer</summary>

**d)** A separate, time-boxed PolicyException for that workload, reviewed and visible in reports

Editing the shared policy hides the problem forever. A PolicyException is small, owned, reviewable and can expire.

</details>

**31.** The denial message said `autogen-require-part-of` for a Deployment. What is an autogen rule?

- **a)** A rule generated by Argo CD
- **b)** A Kubernetes built-in admission rule
- **c)** Kyverno automatically applies Pod rules to pod controllers (Deployment, StatefulSet, Job…) by checking their pod template
- **d)** A rule you must write by hand for each kind

<details markdown="1"><summary>Show answer</summary>

**c)** Kyverno automatically applies Pod rules to pod controllers (Deployment, StatefulSet, Job…) by checking their pod template

So a bad Deployment is rejected at apply time, not later when its pods fail to be created.

</details>

**32.** The webhook is named `validate.kyverno.svc-fail`. What does `fail` mean?

- **a)** failurePolicy Fail: if Kyverno is unreachable, matching requests are rejected (fail closed)
- **b)** Kyverno is in Audit mode
- **c)** The webhook is disabled
- **d)** The policy has failed

<details markdown="1"><summary>Show answer</summary>

**a)** failurePolicy Fail: if Kyverno is unreachable, matching requests are rejected (fail closed)

Fail closed is safer but can block deploys during a Kyverno outage. Run it highly available and exclude system namespaces so the cluster can repair itself.

</details>

**33.** Generated NetworkPolicies stayed missing until you added a ClusterRole labelled `rbac.kyverno.io/aggregate-to-background-controller`. Why?

- **a)** Argo CD needed it
- **b)** Kyverno needs RBAC permission to create the kinds it generates
- **c)** The ClusterRole enables Enforce mode
- **d)** NetworkPolicies need a special CNI

<details markdown="1"><summary>Show answer</summary>

**b)** Kyverno needs RBAC permission to create the kinds it generates

Kyverno's controllers only have the permissions in their aggregated ClusterRoles. To generate a kind, grant it.

</details>

## Lab 6: Canary releases

**34.** What is `Rollout`?

- **a)** A kind added by a CRD; the Argo Rollouts controller acts on it
- **b)** A built-in Kubernetes kind
- **c)** A Helm chart
- **d)** An Argo CD Application type

<details markdown="1"><summary>Show answer</summary>

**a)** A kind added by a CRD; the Argo Rollouts controller acts on it

CRD + controller = the operator pattern. The CRD makes the YAML valid; the controller runs the canary steps.

</details>

**35.** There is no service mesh or ingress. What does `setWeight: 25` mean with 4 replicas?

- **a)** 25 seconds of canary
- **b)** 1 of 4 pods runs the new version
- **c)** Exactly 25% of requests go to the canary
- **d)** The canary gets 25% CPU

<details markdown="1"><summary>Show answer</summary>

**b)** 1 of 4 pods runs the new version

Without a traffic router the weight is approximated by pod counts. Precise per-request weights need Istio, NGINX, ALB or the Gateway API plugin.

</details>

**36.** The bad release's pods stayed Ready. What caught the problem?

- **a)** Kyverno
- **b)** Argo CD saw OutOfSync
- **c)** The liveness probe
- **d)** The AnalysisRun got a non-2xx answer from the canary and the Rollout aborted

<details markdown="1"><summary>Show answer</summary>

**d)** The AnalysisRun got a non-2xx answer from the canary and the Rollout aborted

Health checks show the process is alive; analysis shows it behaves. With `--random-error`, `/readyz` stayed 200 but `/` returned 500.

</details>

**37.** The bad commit is aborted but still in Git. What is the correct recovery?

- **a)** `kubectl edit rollout` to remove the line
- **b)** Delete the Rollout
- **c)** `git revert` the bad commit and push
- **d)** `kubectl argo rollouts retry`

<details markdown="1"><summary>Show answer</summary>

**c)** `git revert` the bad commit and push

Retry runs the same bad version; kubectl edit is drift that selfHeal undoes; deleting causes an outage. Git is the source of truth.

</details>

**38.** Why does the AnalysisTemplate send the header `Connection: close`?

- **a)** Podinfo requires it
- **b)** To save memory
- **c)** Without it the controller reused a keep-alive connection opened when the canary Service still pointed at stable pods, so it tested stable
- **d)** To bypass Kyverno

<details markdown="1"><summary>Show answer</summary>

**c)** Without it the controller reused a keep-alive connection opened when the canary Service still pointed at stable pods, so it tested stable

Found while testing: a bad release passed because every measurement was answered by a stable pod. Always check what your test really hits (the hostname in the measurements).

</details>

**39.** Chart `argo-rollouts` 2.43.9 installs controller v1.10.2. Which version should the kubectl plugin have?

- **a)** 2.43.9
- **b)** The latest available
- **c)** It doesn't matter
- **d)** v1.10.2

<details markdown="1"><summary>Show answer</summary>

**d)** v1.10.2

The chart version is the installer; the app version is the software. Keep the CLI on the same version as the controller.

</details>

**40.** Someone changes `apiVersion: argoproj.io/v1alpha1` to `v1alpha2` to 'release a new version'. What happens?

- **a)** Argo CD can't sync: the server has no resource for that group version
- **b)** A new canary starts
- **c)** Kubernetes upgrades the CRD
- **d)** Nothing

<details markdown="1"><summary>Show answer</summary>

**a)** Argo CD can't sync: the server has no resource for that group version

`apiVersion` is the schema version of the kind, defined by the CRD. Release versions live in the image tag (or, in this lab, the message).

</details>

**41.** After an abort, a stable pod is only 90 seconds old with 0 restarts while its siblings are 9 minutes old. What happened?

- **a)** Kyverno recreated it
- **b)** It crashed and restarted
- **c)** It's a new pod: a stable pod was removed to make room for the canary, and recreated when stable scaled back to 4
- **d)** Argo CD replaced it

<details markdown="1"><summary>Show answer</summary>

**c)** It's a new pod: a stable pod was removed to make room for the canary, and recreated when stable scaled back to 4

Restarted = same name, RESTARTS > 0. New pod = new name, RESTARTS 0. Events show `Created pod` / `Deleted pod`.

</details>

**42.** After an aborted canary, how does Argo CD show the app?

- **a)** Unknown / Missing
- **b)** Synced / Degraded
- **c)** Synced / Healthy
- **d)** OutOfSync / Healthy

<details markdown="1"><summary>Show answer</summary>

**b)** Synced / Degraded

The cluster matches Git (Synced), but the Rollout reports Degraded. Git is wrong, not drifted, and the next ring will not start.

</details>

## Lab 7: Fleet CLI in Go

**43.** Why does `Missing()` take `kubernetes.Interface` instead of `*kubernetes.Clientset`?

- **a)** It's required by client-go
- **b)** To support Windows
- **c)** So tests can pass a fake clientset (`fake.NewSimpleClientset`) with no cluster
- **d)** It's faster

<details markdown="1"><summary>Show answer</summary>

**c)** So tests can pass a fake clientset (`fake.NewSimpleClientset`) with no cluster

Depend on the interface, not the concrete type. The core logic becomes unit-testable.

</details>

**44.** What exit code should `fleetcheck` return when one cluster is unreachable?

- **a)** 1
- **b)** 0
- **c)** 2
- **d)** It should hang until the cluster is back

<details markdown="1"><summary>Show answer</summary>

**c)** 2

0 = all labelled, 1 = findings, 2 = couldn't check a cluster. Scripts and CI rely on exit codes to decide what to do.

</details>

**45.** Goroutines write results with `results[i] = ...` into a slice sized up front. Why is no mutex needed?

- **a)** Go slices are thread-safe
- **b)** There is only one goroutine
- **c)** Each goroutine writes only its own index, so nothing is shared
- **d)** WaitGroup locks the slice

<details markdown="1"><summary>Show answer</summary>

**c)** Each goroutine writes only its own index, so nothing is shared

Partitioning the data avoids locks, and the output order stays stable (sorted context names).

</details>

**46.** Why set `rest.Timeout` as well as using `context.WithTimeout`?

- **a)** Context timeouts don't work in client-go
- **b)** To retry failed requests
- **c)** `rest.Timeout` also bounds the TCP dial and TLS handshake, so one dead cluster can't hang the run
- **d)** They do the same thing

<details markdown="1"><summary>Show answer</summary>

**c)** `rest.Timeout` also bounds the TCP dial and TLS handshake, so one dead cluster can't hang the run

With 100 cells, one unreachable API server must not decide how long the whole audit takes.

</details>

**47.** How should the CLI list namespaces on a cluster with 5,000 of them?

- **a)** Watch forever
- **b)** Paginate: `Limit: 500` and follow `Continue` until it's empty
- **c)** One List call with no limit
- **d)** Use `kubectl` in a loop

<details markdown="1"><summary>Show answer</summary>

**b)** Paginate: `Limit: 500` and follow `Continue` until it's empty

Pagination keeps responses and memory bounded on large clusters.

</details>

**48.** Turning this CLI into a controller, what replaces repeated `List` calls?

- **a)** Webhooks only
- **b)** Informers (watch + local cache) feeding a work queue, with level-triggered reconcile
- **c)** A cron job
- **d)** Polling every second

<details markdown="1"><summary>Show answer</summary>

**b)** Informers (watch + local cache) feeding a work queue, with level-triggered reconcile

Informers cut API load, the work queue gives retries and rate limiting, and reconcile makes the logic idempotent.

</details>

## Lab 8: Design RFC

**49.** What is the main reason to choose cells over one big cluster per region?

- **a)** Cells need no automation
- **b)** Kubernetes can't run more than one app per cluster
- **c)** A bounded blast radius: a bad deploy, upgrade or noisy tenant affects one cell, not the region
- **d)** Cells are cheaper

<details markdown="1"><summary>Show answer</summary>

**c)** A bounded blast radius: a bad deploy, upgrade or noisy tenant affects one cell, not the region

The trade-off you accept is fixed overhead per cell (control plane, add-ons, observability).

</details>

**50.** In a cell architecture, what is the placement service?

- **a)** A Kubernetes scheduler plugin
- **b)** A load balancer
- **c)** The single source of truth for which tenant lives in which cell
- **d)** A CI pipeline

<details markdown="1"><summary>Show answer</summary>

**c)** The single source of truth for which tenant lives in which cell

The router and the deployment tooling read it. The edge keeps a cached copy so the placement service is not in the request path.

</details>

**51.** Why does a good RFC have a 'Non-goals' section?

- **a)** It's optional decoration
- **b)** To list bugs
- **c)** To list rejected people
- **d)** To say clearly what the proposal will not solve, so scope doesn't creep and reviewers don't expect it

<details markdown="1"><summary>Show answer</summary>

**d)** To say clearly what the proposal will not solve, so scope doesn't creep and reviewers don't expect it

Non-goals prevent misunderstandings and keep the decision focused.

</details>

**52.** How do you move a live tenant between cells with no downtime?

- **a)** Ask the tenant to re-register
- **b)** Replicate data (dual-write or change-data-capture), switch at the router, keep a rollback plan, one tenant at a time
- **c)** Stop the tenant, copy, start it again
- **d)** Delete and recreate in the new cell

<details markdown="1"><summary>Show answer</summary>

**b)** Replicate data (dual-write or change-data-capture), switch at the router, keep a rollback plan, one tenant at a time

Data first, traffic last, and always a way back.

</details>

**53.** Which option is best for a mix of ordinary tenants and a few regulated (for example FedRAMP) tenants?

- **a)** One shared cluster for all
- **b)** Hybrid: shared cells for most, dedicated cells for regulated or very large tenants, all from the same blueprint
- **c)** No Kubernetes
- **d)** A cluster per tenant for everyone

<details markdown="1"><summary>Show answer</summary>

**b)** Hybrid: shared cells for most, dedicated cells for regulated or very large tenants, all from the same blueprint

It keeps cost low for most tenants and gives a real compliance boundary where it's required.

</details>

## Lab 9: Self-service database

**54.** In Crossplane, what does the XRD (CompositeResourceDefinition) define?

- **a)** The cloud credentials
- **b)** The Postgres pod
- **c)** The Argo CD app
- **d)** The platform API: the new kind (`Database`) and which fields a developer may set

<details markdown="1"><summary>Show answer</summary>

**d)** The platform API: the new kind (`Database`) and which fields a developer may set

The XRD is the product contract (the menu). The Composition is the recipe behind it.

</details>

**55.** How can the same `Database` API create RDS on EKS but a Postgres pod in this lab?

- **a)** Several Compositions implement the same kind; one is selected by label (for example `provider: local` or `provider: aws`)
- **b)** Developers write different YAML per cloud
- **c)** Crossplane detects the cloud automatically
- **d)** It can't

<details markdown="1"><summary>Show answer</summary>

**a)** Several Compositions implement the same kind; one is selected by label (for example `provider: local` or `provider: aws`)

The developer's claim stays the same; the platform picks the backend by composition selection.

</details>

**56.** Why is the database password derived with `sha256sum` of the uid instead of `randAlphaNum`?

- **a)** To make it readable
- **b)** randAlphaNum is not available
- **c)** The template re-renders on every reconcile; a random value would change the password each time
- **d)** sha256 is more random

<details markdown="1"><summary>Show answer</summary>

**c)** The template re-renders on every reconcile; a random value would change the password each time

Compositions must be deterministic. A changing password would break the app every reconcile.

</details>

**57.** Why is the storage size not tied to `spec.size`?

- **a)** Storage is free
- **b)** Crossplane can't set storage
- **c)** A StatefulSet's `volumeClaimTemplates` are immutable, so a resize would reject the whole update (Synced=False)
- **d)** Postgres doesn't need storage

<details markdown="1"><summary>Show answer</summary>

**c)** A StatefulSet's `volumeClaimTemplates` are immutable, so a resize would reject the whole update (Synced=False)

Grow storage with PVC expansion. On clouds the same problem appears as 'forces replacement' fields.

</details>

**58.** The Database is `Synced False` with 'cannot create statefulsets'. What is missing?

- **a)** The Postgres image
- **b)** A Kyverno policy
- **c)** The XRD
- **d)** RBAC: a ClusterRole labelled `rbac.crossplane.io/aggregate-to-crossplane` for the kinds being composed

<details markdown="1"><summary>Show answer</summary>

**d)** RBAC: a ClusterRole labelled `rbac.crossplane.io/aggregate-to-crossplane` for the kinds being composed

Crossplane v2 can compose any kind, but only with permission for it.

</details>

## Lab 10: Supply chain

**59.** Why do you sign an image by digest (`@sha256:…`) and not by tag?

- **a)** Cosign can't read tags
- **b)** Registries require it
- **c)** Digests are shorter
- **d)** A tag can be moved to a different image; a digest identifies exact bytes

<details markdown="1"><summary>Show answer</summary>

**d)** A tag can be moved to a different image; a digest identifies exact bytes

A signature on a tag would be worthless: someone could push a different image under the same tag.

</details>

**60.** What is an SBOM?

- **a)** A vulnerability scanner
- **b)** A signing key
- **c)** A list of every package and component inside the image
- **d)** A Kubernetes policy

<details markdown="1"><summary>Show answer</summary>

**c)** A list of every package and component inside the image

Like an ingredients list. When a new CVE appears, the SBOM index tells you which images contain the affected package.

</details>

**61.** What does `mutateDigest: true` do in the Kyverno verifyImages rule?

- **a)** Rewrites the pod's image reference to the verified digest, so what was verified is exactly what runs
- **b)** Deletes the tag from the registry
- **c)** Re-signs the image
- **d)** Disables verification

<details markdown="1"><summary>Show answer</summary>

**a)** Rewrites the pod's image reference to the verified digest, so what was verified is exactly what runs

Without it, the tag could be moved between verification and the image pull.

</details>

**62.** Which key goes into Git?

- **a)** Neither: keys go into image labels
- **b)** Both
- **c)** The private key `cosign.key`
- **d)** Only the public key `cosign.pub`

<details markdown="1"><summary>Show answer</summary>

**d)** Only the public key `cosign.pub`

Anyone may read the public key; only the private key can sign. `.gitignore` blocks `*.key`.

</details>

**63.** The policy matches `idp-lab-control-plane:30880/*`. An unsigned image from Docker Hub is deployed. What happens?

- **a)** It's denied
- **b)** It's signed automatically
- **c)** It's admitted: the rule doesn't look at other registries
- **d)** Kyverno mirrors it

<details markdown="1"><summary>Show answer</summary>

**c)** It's admitted: the rule doesn't look at other registries

Next production step: a rule that allows only the platform registry, and mirror third-party images into it after scanning.

</details>

**64.** Why does Kyverno need `allowInsecureRegistry: true` in this lab?

- **a)** To allow unsigned images
- **b)** The lab registry speaks plain HTTP, and Kyverno must fetch signatures and attestations from it
- **c)** To skip verification
- **d)** To speed up admission

<details markdown="1"><summary>Show answer</summary>

**b)** The lab registry speaks plain HTTP, and Kyverno must fetch signatures and attestations from it

In production the registry has TLS (Harbor, ECR, ACR) and this setting stays off.

</details>

## Lab 11: Cost per tenant

**65.** Cost per tenant label was impossible until you set `metricLabelsAllowlist` on kube-state-metrics. Why?

- **a)** Prometheus was down
- **b)** OpenCost doesn't support labels
- **c)** kube-state-metrics exports no Kubernetes labels by default, so `tenant.lab/id` never reached Prometheus
- **d)** The label had a typo

<details markdown="1"><summary>Show answer</summary>

**c)** kube-state-metrics exports no Kubernetes labels by default, so `tenant.lab/id` never reached Prometheus

You must allowlist the namespace labels you want as metrics (`namespaces=[tenant.lab/id,team,cost-center]`).

</details>

**66.** In OpenCost results, what is `__unallocated__` when aggregating by `label:tenant.lab/id`?

- **a)** Cost of deleted tenants
- **b)** Unused disk
- **c)** Cost of pods in namespaces without that label: shared platform cost (kube-system, monitoring, …)
- **d)** An error

<details markdown="1"><summary>Show answer</summary>

**c)** Cost of pods in namespaces without that label: shared platform cost (kube-system, monitoring, …)

You decide how to split it, with a documented allocation key, and show idle capacity separately.

</details>

**67.** What is the difference between showback and chargeback?

- **a)** Showback is for CPU, chargeback for memory
- **b)** Showback shows each team its cost; chargeback actually bills their budget
- **c)** Chargeback is free
- **d)** No difference

<details markdown="1"><summary>Show answer</summary>

**b)** Showback shows each team its cost; chargeback actually bills their budget

Start with showback so teams trust the numbers before money moves.

</details>

**68.** In Prometheus, the namespace label `tenant.lab/id` appears as which label?

- **a)** `label_tenant_lab_id`
- **b)** `tenant.lab/id`
- **c)** `tenantLabId`
- **d)** `label.tenant.lab.id`

<details markdown="1"><summary>Show answer</summary>

**a)** `label_tenant_lab_id`

kube-state-metrics prefixes `label_` and converts `.` and `/` into `_`.

</details>

**69.** The OpenCost add-on was blocked by your own Lab 5 guardrail. What is the platform way to fix it?

- **a)** Switch the policy to Audit
- **b)** Set `podLabels: {app.kubernetes.io/part-of: opencost}` in the add-on values
- **c)** Delete Kyverno
- **d)** Exclude the opencost namespace from the policy

<details markdown="1"><summary>Show answer</summary>

**b)** Set `podLabels: {app.kubernetes.io/part-of: opencost}` in the add-on values

Platform components follow the same rules as tenants. Fix the component, not the policy.

</details>

**70.** Why bill on requests rather than usage?

- **a)** Kubernetes doesn't track usage
- **b)** Requests are always lower
- **c)** Requests reserve node capacity whether used or not; billing on them makes teams right-size
- **d)** Usage can't be measured

<details markdown="1"><summary>Show answer</summary>

**c)** Requests reserve node capacity whether used or not; billing on them makes teams right-size

Show usage next to it so teams see the waste (VPA or Goldilocks recommendations).

</details>

## Lab 12: Kafka topics as code

**71.** Team identity's KafkaUser has prefix ACLs on `identity.`. It tries to produce to `payments.ledger`. What happens?

- **a)** `TopicAuthorizationException`
- **b)** It works
- **c)** Kafka crashes
- **d)** The topic is created automatically

<details markdown="1"><summary>Show answer</summary>

**a)** `TopicAuthorizationException`

Ownership is the naming convention: identity owns `identity.*` and nothing else.

</details>

**72.** Why is `auto.create.topics.enable: false` set?

- **a)** So a topic exists only if someone declared it as code (KafkaTopic), with guardrails
- **b)** To save disk
- **c)** Strimzi requires it
- **d)** For performance

<details markdown="1"><summary>Show answer</summary>

**a)** So a topic exists only if someone declared it as code (KafkaTopic), with guardrails

Auto-created topics bypass naming rules, partition limits and retention policy.

</details>

**73.** The Kafka topic policy reached a cell before Strimzi was installed. After Strimzi arrives, bad topics are still accepted. What fixes it?

- **a)** Switch to Audit
- **b)** Re-apply or change the policy (or restart Kyverno) after the CRDs exist
- **c)** Nothing, it's a Kafka bug
- **d)** Delete Strimzi

<details markdown="1"><summary>Show answer</summary>

**b)** Re-apply or change the policy (or restart Kyverno) after the CRDs exist

Found while testing: Kyverno kept a stale copy of a policy whose kind didn't exist yet. Order matters: CRDs first, then the policy.

</details>

**74.** How does a client prove its identity to the Kafka cluster in this lab?

- **a)** IP allowlist
- **b)** No identity is needed
- **c)** mTLS: a client certificate issued by the User Operator, stored in a Secret named after the KafkaUser
- **d)** Username in a header

<details markdown="1"><summary>Show answer</summary>

**c)** mTLS: a client certificate issued by the User Operator, stored in a Secret named after the KafkaUser

The only listener requires TLS client authentication, so ACLs and quotas apply per identity. No anonymous access.

</details>

**75.** What do KafkaUser quotas (`producerByteRate`, `consumerByteRate`) protect against?

- **a)** Data loss
- **b)** A noisy neighbour: one team using all broker capacity on a shared cluster
- **c)** Unauthorised access
- **d)** Schema changes

<details markdown="1"><summary>Show answer</summary>

**b)** A noisy neighbour: one team using all broker capacity on a shared cluster

Quotas keep a shared cluster fair. ACLs control who; quotas control how much.

</details>

**76.** This lab uses one broker with replication factor 1. What is a typical production setup?

- **a)** RF=1, min.insync.replicas=1
- **b)** RF=5 on one node
- **c)** RF=3 across zones, min.insync.replicas=2
- **d)** RF=2, min.insync.replicas=2

<details markdown="1"><summary>Show answer</summary>

**c)** RF=3 across zones, min.insync.replicas=2

RF=3 with min ISR 2 survives losing one broker without losing acknowledged writes.

</details>

## Mixed scenarios

**77.** Scenario: a developer says 'my deploy didn't happen'. What do you check first?

- **a)** Recreate the cluster
- **b)** The pod logs
- **c)** The Argo CD Application: sync status, revision and operation message
- **d)** Restart Argo CD

<details markdown="1"><summary>Show answer</summary>

**c)** The Argo CD Application: sync status, revision and operation message

Go top down: Argo CD app → rings (ApplicationSet status) → workload (Rollout/Deployment) → events → logs. Stop at the first red layer.

</details>

**78.** Scenario: Argo CD shows a Rollout Synced but Degraded with 'analysis … failed'. What does it mean?

- **a)** The cluster is down
- **b)** Kyverno blocked the pods
- **c)** Argo CD is broken
- **d)** The new version was tested and refused; users are still on stable. Fix Git (revert)

<details markdown="1"><summary>Show answer</summary>

**d)** The new version was tested and refused; users are still on stable. Fix Git (revert)

This is the canary doing its job. Synced means Git was applied; Degraded means the new version failed analysis.

</details>

**79.** Scenario: a ReplicaSet has 0 pods and events show FailedCreate 'admission webhook … denied'. Which layer is it?

- **a)** Argo CD
- **b)** The application code
- **c)** DNS
- **d)** Kyverno guardrails: the pod spec breaks a policy (tag, label, signature)

<details markdown="1"><summary>Show answer</summary>

**d)** Kyverno guardrails: the pod spec breaks a policy (tag, label, signature)

Read the policy and rule name in the message, then fix the workload in Git. Running pods are not affected; only new ones.

</details>

**80.** Which pairing is correct?

- **a)** Rings protect each pod; canaries protect the fleet
- **b)** Neither needs Git
- **c)** Rings protect the fleet (cell by cell); canaries protect each cell (pod by pod with analysis)
- **d)** Both do the same thing

<details markdown="1"><summary>Show answer</summary>

**c)** Rings protect the fleet (cell by cell); canaries protect each cell (pod by pod with analysis)

Defence in depth: in Lab 6 a ring gate let a bad commit through by a race, and cell-2's canary still stopped it.

</details>
