# Lab 0: Fleet tour (hub, cells and the control-plane split)

**Time:** about 20 minutes · **Needs:** the environment from [`setup/`](../setup/README.md)

Goal: be able to draw the fleet from memory. One **hub** (the management cluster) and two
**cells** (workload clusters), each cell labelled with its ring, region, tenancy and compliance.

```text
                 ┌──────────── hub (kind: idp-lab) ─────────────┐
 you ──► :3000 ──┤ Backstage (runs on your Mac)                 │
     ──► :3300 ──┤ Gitea      (Git server)                      │
     ──► :8080 ──┤ Argo CD    (deploys to the cells)            │
                 └────────────┬──────────────────┬──────────────┘
                              │ cluster Secrets   │
                   ┌──────────▼───────┐  ┌───────▼──────────┐
                   │ cell-1  ring 0   │  │ cell-2  ring 1   │
                   │ shared, us-east  │  │ dedicated, gov   │
                   └──────────────────┘  └──────────────────┘
```

## Step 1: Contexts

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
kubectl config get-contexts          # hub, cell-1, cell-2
kubectl --context cell-2 get nodes
```

`kubectl` only uses this file if `KUBECONFIG` points at it. Without it, kubectl falls back to
`http://localhost:8080`, which here is the Argo CD UI, and you get confusing errors such as
`failed to download openapi`.

## Step 2: Argo CD CLI

```bash
argocd login localhost:8080 --plaintext --username admin     # prompts for the password
argocd cluster list                                          # in-cluster, cell-1, cell-2
```

`--plaintext` is needed because this Argo CD serves plain HTTP. The `argocd` CLI uses its own
login (stored in `~/.config/argocd/config`), not your kubeconfig. If you see
`token is expired`, just log in again.

## Step 3: How Argo CD knows the cells

```bash
kubectl --context hub -n argocd get secret \
  -l argocd.argoproj.io/secret-type=cluster --show-labels
```

Each cell is a **Secret** in the `argocd` namespace with the label
`argocd.argoproj.io/secret-type=cluster`. It holds the API server URL and the credentials.
Creating such a Secret *is* adding a cluster; `argocd cluster add` only automates it.

The server URL is `https://cell-1-control-plane:6443`, not `127.0.0.1:6551` as in your
kubeconfig: Argo CD runs **inside** the hub and reaches the cells by container name on the
shared `kind` Docker network.

## Step 4: Look around

- Backstage (http://localhost:3000): Catalog → kind **Group**: `platform`, `team-identity`, `team-payments`.
- Gitea (http://localhost:3300): the `golden` org is empty for now.

## Questions to think through

1. Which label would you use to place a regulated tenant? Which one to order a rollout?
2. Why keep the hub separate from the cells? (blast radius, upgrade cadence, where credentials live)
3. One Argo CD for all cells vs one per cell: what breaks first at 200 cells?
4. Argo CD holds client certificates for the cells here. What would you use on EKS or AKS instead?
   (workload identity / IAM roles, short-lived tokens, no static kubeconfigs)
