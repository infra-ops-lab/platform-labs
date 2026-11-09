#!/bin/bash
# A small OCI registry inside the hub, for this lab.
#   From your Mac:            localhost:8880/<repo>:<tag>              (hub port 8880 -> NodePort 30880)
#   From the cells (containerd and Kyverno): idp-lab-control-plane:30880/<repo>  (same registry)
# It speaks plain HTTP, so each cell's containerd is told to trust it. Safe to re-run.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-~/idp-lab/fleet.kubeconfig}
HUB_NODE=${HUB_NODE:-idp-lab-control-plane}      # the hub's kind node name
kubectl --context hub apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata: { name: registry }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: registry-data, namespace: registry }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 5Gi } } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: registry, namespace: registry }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: registry } }
  template:
    metadata: { labels: { app: registry } }
    spec:
      containers:
        - name: registry
          image: public.ecr.aws/docker/library/registry:2
          env: [{ name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true" }]
          ports: [{ containerPort: 5000 }]
          readinessProbe: { httpGet: { path: /v2/, port: 5000 } }
          volumeMounts: [{ name: data, mountPath: /var/lib/registry }]
      volumes: [{ name: data, persistentVolumeClaim: { claimName: registry-data } }]
---
apiVersion: v1
kind: Service
metadata: { name: registry, namespace: registry }
spec:
  type: NodePort
  selector: { app: registry }
  ports: [{ port: 5000, targetPort: 5000, nodePort: 30880 }]
YAML
kubectl --context hub -n registry rollout status deploy/registry --timeout=180s | tail -1
REG=$HUB_NODE:30880
for CELL in cell-1 cell-2; do
  N=$CELL-control-plane
  docker inspect $N >/dev/null 2>&1 || continue
  RESTART=0
  if ! docker exec $N grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
    docker exec $N sh -c 'printf "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n" >> /etc/containerd/config.toml'
    RESTART=1
  fi
  docker exec $N sh -c "D=/etc/containerd/certs.d/$REG; mkdir -p \$D && printf 'server = \"http://$REG\"\n\n[host.\"http://$REG\"]\n  capabilities = [\"pull\", \"resolve\"]\n' > \$D/hosts.toml"
  if [ $RESTART = 1 ]; then docker exec $N systemctl restart containerd; echo "$CELL: containerd trusts $REG (restarted)"; else echo "$CELL: containerd trusts $REG"; fi
done
curl -s localhost:8880/v2/ >/dev/null && echo "registry: push to localhost:8880/<repo>, pull in cells as $REG/<repo>"
