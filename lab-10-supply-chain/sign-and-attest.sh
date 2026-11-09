#!/bin/bash
# Publish, SBOM, sign and attest the golden image. Run from your Mac.
# Tested with cosign v3.1.4, syft v1.57.0, crane v0.22.1 (brew install cosign syft crane).
set -euo pipefail
# Docker Desktop's credential helper can hang Go registry clients (crane, cosign).
# These public images need no login, so give the tools an empty Docker config.
export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.lab-docker-config}; mkdir -p "$DOCKER_CONFIG"
WORK=${WORK:-$HOME/idp-lab/supplychain}; mkdir -p "$WORK" && cd "$WORK"

# 1) Copy the images into the platform registry (registry to registry, no Docker daemon needed)
crane copy --insecure ghcr.io/stefanprodan/podinfo:6.7.1 localhost:8880/golden/podinfo:6.7.1
crane copy --insecure public.ecr.aws/nginx/nginx:1.27-alpine localhost:8880/thirdparty/nginx:1.27-alpine   # stays unsigned
IMG=localhost:8880/golden/podinfo@$(crane digest --insecure localhost:8880/golden/podinfo:6.7.1)   # always sign by DIGEST
echo "image: $IMG"

# 2) The platform signing key pair (production: a KMS-backed key, or keyless signing with the CI job's identity)
#    You'll be asked for a password for the private key; remember it for step 4.
[ -f cosign.key ] || cosign generate-key-pair

# 3) SBOM: the list of everything inside the image
SYFT_REGISTRY_INSECURE_USE_HTTP=true syft scan registry:localhost:8880/golden/podinfo:6.7.1 -o spdx-json=sbom.spdx.json

# 4) Sign, and attach the SBOM as a signed attestation.
#    cosign v3 defaults to a signing config with a public transparency log; for a private key and
#    no public log (air-gapped style) use the classic path, which stores .sig/.att tags Kyverno reads.
FLAGS=(--yes --key cosign.key --use-signing-config=false --tlog-upload=false --new-bundle-format=false --allow-http-registry --allow-insecure-registry)
cosign sign   "${FLAGS[@]}" "$IMG"
cosign attest "${FLAGS[@]}" --type spdxjson --predicate sbom.spdx.json "$IMG"

# 5) Verify the same way the cluster will
V=(--key cosign.pub --insecure-ignore-tlog --allow-http-registry --allow-insecure-registry)
cosign verify "${V[@]}" "$IMG" >/dev/null && echo "signature OK"
cosign verify-attestation "${V[@]}" --type spdxjson "$IMG" >/dev/null && echo "SBOM attestation OK"
crane ls --insecure localhost:8880/golden/podinfo     # sha256-<digest>.sig and .att next to the tag
