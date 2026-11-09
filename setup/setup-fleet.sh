#!/bin/bash
# Creates (or starts) the cell clusters, registers them in the hub's Argo CD with fleet labels,
# and writes $LAB_DIR/fleet.kubeconfig with the contexts hub, cell-1 and cell-2. Safe to re-run.
#
# Needs: the hub cluster "idp-lab" (kind-hub.yaml) with Argo CD installed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="${LAB_DIR:-$HOME/idp-lab}"
HUBCFG="$LAB_DIR/idp-lab.kubeconfig"
mkdir -p "$LAB_DIR/kubeconfigs"
step() { echo; echo "==> $*"; }

step "Hub cluster (idp-lab)"
kind get kubeconfig --name idp-lab > "$HUBCFG"
until KUBECONFIG=$HUBCFG kubectl get nodes >/dev/null 2>&1; do sleep 2; done
echo "hub API is up"

grep -v '^#' "$HERE/cells.conf" | while read -r CELL RING TENANCY COMPLIANCE REGION; do
  [ -z "$CELL" ] && continue
  step "Cell $CELL (ring $RING, $TENANCY, $COMPLIANCE, $REGION)"
  if kind get clusters 2>/dev/null | grep -qx "$CELL"; then
    docker start "$CELL-control-plane" >/dev/null
    echo "exists, started"
  else
    kind create cluster --config "$HERE/kind-$CELL.yaml" --kubeconfig "$LAB_DIR/kubeconfigs/$CELL.kubeconfig"
  fi
  kind get kubeconfig --name "$CELL" > "$LAB_DIR/kubeconfigs/$CELL.kubeconfig"
  # --internal: the address the hub uses to reach the cell over the shared "kind" Docker network
  kind get kubeconfig --name "$CELL" --internal > "$LAB_DIR/kubeconfigs/$CELL.internal.kubeconfig"
  KUBECONFIG=$LAB_DIR/kubeconfigs/$CELL.kubeconfig kubectl wait --for=condition=Ready node --all --timeout=180s

  echo "registering $CELL in Argo CD (a labelled cluster Secret)"
  IK=$LAB_DIR/kubeconfigs/$CELL.internal.kubeconfig
  CA=$(KUBECONFIG=$IK kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  CERT=$(KUBECONFIG=$IK kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
  KEY=$(KUBECONFIG=$IK kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}')
  # Lab only: this reuses kind's admin client certificate. In production use a least-privilege
  # identity (cloud IAM / workload identity or a scoped ServiceAccount token).
  KUBECONFIG=$HUBCFG kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$CELL
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    fleet.lab/cell: "$CELL"
    fleet.lab/ring: "$RING"
    fleet.lab/tenancy: "$TENANCY"
    fleet.lab/compliance: "$COMPLIANCE"
    fleet.lab/region: "$REGION"
type: Opaque
stringData:
  name: $CELL
  server: https://$CELL-control-plane:6443
  config: |
    {"tlsClientConfig":{"caData":"$CA","certData":"$CERT","keyData":"$KEY"}}
YAML
  echo "  secret argocd/cluster-$CELL applied"
done

step "Fleet kubeconfig (contexts: hub, cell-1, cell-2)"
TMP=$(mktemp -d)
cp "$HUBCFG" "$TMP/hub"; KUBECONFIG=$TMP/hub kubectl config rename-context kind-idp-lab hub >/dev/null
for C in cell-1 cell-2; do
  cp "$LAB_DIR/kubeconfigs/$C.kubeconfig" "$TMP/$C"
  KUBECONFIG=$TMP/$C kubectl config rename-context "kind-$C" "$C" >/dev/null
done
KUBECONFIG=$TMP/hub:$TMP/cell-1:$TMP/cell-2 kubectl config view --flatten > "$LAB_DIR/fleet.kubeconfig"
chmod 600 "$LAB_DIR/fleet.kubeconfig" "$LAB_DIR"/kubeconfigs/*; rm -rf "$TMP"
KUBECONFIG=$LAB_DIR/fleet.kubeconfig kubectl config use-context hub >/dev/null

step "Argo CD sees these clusters"
KUBECONFIG=$HUBCFG kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -L fleet.lab/cell,fleet.lab/ring,fleet.lab/tenancy,fleet.lab/compliance
echo; echo "Fleet ready. export KUBECONFIG=$LAB_DIR/fleet.kubeconfig"
