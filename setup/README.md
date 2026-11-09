# Setup: build the lab environment

Everything runs on one laptop with Docker and [kind](https://kind.sigs.k8s.io/).
Tested on macOS with Docker Desktop (8 CPUs, 24 GB memory given to Docker).

| Tool | Version used |
|---|---|
| kind | 0.24.0 (node image `kindest/node:v1.31.0`) |
| kubectl | 1.31 or newer |
| helm | 3.16 |
| argocd CLI | 3.x |
| Node.js / Yarn | Node 22 or 24, Yarn 4 (for Backstage) |
| git, jq, curl | any recent |

```text
Ports on your machine
  6550  hub API server        3300  Gitea         8080  Argo CD UI
  6551  cell-1 API server     3000  Backstage UI  7007  Backstage backend
  6552  cell-2 API server     8880  lab registry (hub, Lab 10)   8881 / 8882  apps on cell-1 / cell-2
```

## 1. Hub cluster

```bash
kind create cluster --config kind-hub.yaml
```

## 2. Argo CD and Gitea on the hub

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update

helm install argocd argo/argo-cd --version 10.12.1 \
  -n argocd --create-namespace -f argocd-values.yaml

helm install gitea gitea-charts/gitea --version 12.7.0 \
  -n gitea --create-namespace -f gitea-values.yaml \
  --set gitea.admin.password='<choose-a-password>'
```

- Argo CD: http://localhost:8080, user `admin`. Initial password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- Gitea: http://localhost:3300, user `labadmin` with the password you chose.

## 3. Cells and fleet registration

```bash
./setup-fleet.sh
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
kubectl config get-contexts        # hub, cell-1, cell-2
```

`cells.conf` is the small inventory: one line per cell with its ring, tenancy, compliance and
region. The script turns each line into a kind cluster and a labelled Argo CD cluster Secret.

## 4. Backstage

```bash
cd ~/idp-lab
npx @backstage/create-app@latest      # name it "backstage"
cd backstage
yarn --cwd packages/backend add @backstage/plugin-scaffolder-backend-module-gitea
```

Add the module to `packages/backend/src/index.ts`:

```ts
backend.add(import('@backstage/plugin-scaffolder-backend-module-gitea'));
```

Create `app-config.local.yaml` from [`app-config.local.example.yaml`](app-config.local.example.yaml),
create a Gitea access token for your user, and start Backstage with the tokens in the environment:

```bash
export GITEA_TOKEN='<gitea access token>'
export BACKSTAGE_LAB_TOKEN="$(openssl rand -hex 24)"
yarn start                             # http://localhost:3000
```

The default home page includes a "Random Joke" widget that calls a public API; if that API is
down, the dev error overlay covers every page. Disable it in `app-config.yaml`:

```yaml
app:
  extensions:
    - home-page-widget:home/random-joke: false
```

## Never commit

kubeconfigs, `*.kubeconfig`, Gitea or Argo CD passwords, access tokens, `app-config.local.yaml`.
The [`.gitignore`](https://github.com/infra-ops-lab/platform-labs/blob/main/.gitignore) at the repo root covers the common ones.
