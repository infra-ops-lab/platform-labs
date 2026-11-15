#!/usr/bin/env bash
# Step 5b: RBAC matrix. Predict each answer before running.
check() { printf '%-80s %-4s (expect %s)\n' "${*:2}" "$(kubectl auth can-i "${@:2}" 2>/dev/null)" "$1"; }
CI=system:serviceaccount:acme-prod:acme-ci

check yes create deployments -n acme-prod --as=alice --as-group=acme-admins
check yes create deployments -n acme-prod --as=bob   --as-group=acme-devs
check no  get secrets        -n acme-prod --as=bob   --as-group=acme-devs
check yes create pods/exec   -n acme-dev  --as=bob   --as-group=acme-devs
check no  create pods/exec   -n acme-prod --as=bob   --as-group=acme-devs      # dev only
check yes list pods          -n acme-prod --as=carol
check no  delete pods        -n acme-prod --as=carol
check yes patch deployments  -n acme-prod --as=$CI
check no  create deployments -n acme-prod --as=$CI
check no  get pods           -n other-team  --as=alice --as-group=acme-admins  # other tenant
check no  update resourcequotas -n acme-dev --as=alice --as-group=acme-admins    # admin cannot change quota
check no  patch namespaces/acme-dev --as=alice --as-group=acme-admins            # cannot remove PSA labels
check no  list namespaces    --as=alice --as-group=acme-admins
