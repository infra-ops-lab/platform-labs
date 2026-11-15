#!/usr/bin/env bash
# Step 3a: create a real x509 user through the CSR API and a kubeconfig context <user>@ops-lab.
# Usage: scripts/make-user.sh <user> <group>     e.g. scripts/make-user.sh alice acme-admins
# CN = user, O = group. Does NOT switch your current context.

# Stop on any error, unset variable, or failed pipe.
set -euo pipefail
# Read the two arguments; fail with a message if either is missing.
user=${1:?user}; group=${2:?group}
# Certs live in <lab>/certs no matter which directory you run the script from.
certs="$(cd "$(dirname "$0")/.." && pwd)/certs"
# Create the certs folder (if needed) and work inside it.
mkdir -p "$certs" && cd "$certs"

# 1. Private key: the user's secret. Never leaves this machine, never sent to the cluster.
openssl genrsa -out "$user.key" 2048
# 2. CSR file: "please sign this key for CN=<user> (username), O=<group> (group)". Identity is fixed here.
openssl req -new -key "$user.key" -out "$user.csr" -subj "/CN=$user/O=$group"
# 3. CSR object: submit the request to Kubernetes, asking for a 24h client-auth cert. Status: Pending.
kubectl apply -f - <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $user
spec:
  request: $(base64 < "$user.csr" | tr -d '\n')   # the CSR file, base64-encoded
  signerName: kubernetes.io/kube-apiserver-client  # signer for certs that log in to the API server
  expirationSeconds: 86400                         # requested validity = 24h (REQUESTEDDURATION)
  usages: ["client auth"]                          # cert may only be used to authenticate a client
YAML
# 4. Approve: the admin's decision. kube-controller-manager then signs it with the cluster CA. Status: Approved,Issued.
kubectl certificate approve "$user"
# 5. Wait up to 15s for the signed cert to appear in the CSR status.
for _ in $(seq 1 15); do
  crt=$(kubectl get csr "$user" -o jsonpath='{.status.certificate}')
  [ -n "$crt" ] && break; sleep 1
done
# Give up with an error if the cert never appeared.
[ -n "$crt" ] || { echo "certificate for $user was not issued" >&2; exit 1; }
# 6. Save the signed cert (base64-decoded) as <user>.crt. The 24h clock has already started.
echo "$crt" | base64 -d > "$user.crt"
# 7. Kubeconfig user entry: a local label holding key + cert (embedded, so the cert files can be deleted later).
kubectl config set-credentials "$user" --client-key="$user.key" --client-certificate="$user.crt" --embed-certs=true
# 8. Kubeconfig context: cluster + user + default namespace, used with --context <user>@ops-lab.
kubectl config set-context "$user@ops-lab" --cluster=kind-ops-lab --user="$user" --namespace=acme-dev
# Show who the cert says you are and when it expires.
openssl x509 -in "$user.crt" -noout -subject -enddate
