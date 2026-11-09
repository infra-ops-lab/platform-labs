#!/bin/bash
# Put your cosign public key into the policy: fill-key.sh <cosign.pub> <policy.yaml> > out.yaml
# Every line that says COSIGN_PUBLIC_KEY is replaced by the key, with the same indentation.
set -euo pipefail
awk -v keyfile="$1" '
  /COSIGN_PUBLIC_KEY/ {
    indent = substr($0, 1, index($0, "COSIGN_PUBLIC_KEY") - 1)
    while ((getline line < keyfile) > 0) if (line != "") print indent line
    close(keyfile); next
  }
  { print }' "$2"
