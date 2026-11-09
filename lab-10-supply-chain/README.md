# Lab 10: Supply chain: SBOM, signing and verification at admission

**Time:** about 60 minutes · **Level:** beginner-friendly · **Needs:** Lab 5 (Kyverno on the cells)

How do you know the image running in production is the one your pipeline built, and what's
inside it? You'll **sign** an image, attach its **SBOM**, and make the cells **refuse** images
from the platform registry that aren't signed.

---

## Part A: The ideas in plain words

| Idea | Plain meaning | Everyday comparison |
|---|---|---|
| **Digest** (`@sha256:…`) | The fingerprint of the exact image bytes. A tag (`:6.7.1`) is a name tag that can be moved; a digest can't | Tag = "the blue box"; digest = the box's serial number |
| **SBOM** | Software Bill of Materials: the list of every package inside the image (SPDX format here) | The ingredients list on food |
| **Signature** (cosign) | Proof that **your** key approved **this** digest | A seal on an envelope |
| **Attestation** | A signed statement *about* an image, here "this is its SBOM" | The ingredients list, also sealed |
| **verifyImages** (Kyverno) | At admission: no valid signature → pod rejected; also swap the tag for the digest | The guard checks the seal before letting the box in |

```text
build time (your Mac = the "CI")                           run time (cell-1)
  crane copy ─► registry: golden/podinfo:6.7.1               Pod image: …/golden/podinfo:6.7.1
  syft      ─► sbom.spdx.json                                     │ Kyverno verifyImages
  cosign sign + attest (by digest) ─► .sig, .att in registry ─────┤ signature OK? SBOM attestation OK?
                                                                  ▼
                                         admitted, image rewritten to …@sha256:…  (or denied)
```

**Why sign by digest:** a signature on a tag would be worthless, because someone can push a
different image under the same tag. You sign the fingerprint.

---

## Part B: Files in this folder

| File | What it is |
|---|---|
| `setup-registry.sh` | A small registry in the hub (`localhost:8880` from your Mac, `idp-lab-control-plane:30880` from the cells) |
| `sign-and-attest.sh` | Copy images, make the SBOM, sign and attest, verify |
| `addon-kyverno-appset.yaml` | The Lab 5 Kyverno add-on plus `allowInsecureRegistry` (the lab registry is plain HTTP) |
| `policies/30-verify-images.yaml` | The admission rule (put your public key in it) |
| `fill-key.sh` | Puts your `cosign.pub` into the policy |

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/platform-labs/lab-10-supply-chain
brew install cosign syft crane       # tested: cosign 3.1.4, syft 1.57.0, crane 0.22.1
```

---

## Step 1: The platform registry

```bash
./setup-registry.sh
curl -s localhost:8880/v2/_catalog
```

**You should see:** `cell-1: containerd trusts idp-lab-control-plane:30880`, the same for cell-2,
and `{"repositories":[]}` (or a list).

(`idp-lab-control-plane` is the hub's kind node. The cells reach it over the shared Docker
network.)

---

## Step 2: SBOM, sign, attest

```bash
./sign-and-attest.sh
```

cosign asks for a password for the new private key `~/idp-lab/supplychain/cosign.key`, and
again each time it signs (in this lab you may press Enter for an empty one). **Never commit
`cosign.key`**; `.gitignore` already blocks `*.key`.

**You should see** at the end:

```text
signature OK
SBOM attestation OK
6.7.1
sha256-<digest>.att
sha256-<digest>.sig
```

Look inside the SBOM:

```bash
jq '.packages | length' ~/idp-lab/supplychain/sbom.spdx.json                # how many packages
jq -r '.packages[].name' ~/idp-lab/supplychain/sbom.spdx.json | head -20
```

> **Note:** the `cosign` flags look long. cosign v3 defaults to a public transparency log
> (Rekor). For a private key with **no** public log, which is how air-gapped or regulated setups
> often work, you use the classic path: `--use-signing-config=false --tlog-upload=false
> --new-bundle-format=false`.

---

## Step 3: Let Kyverno read the registry, then add the rule (through Git)

### 3a. Kyverno add-on

```bash
kubectl --context hub apply -f addon-kyverno-appset.yaml
kubectl --context cell-1 -n kyverno get deploy kyverno-admission-controller -o yaml | grep allowInsecureRegistry
```

**You should see:** `--allowInsecureRegistry=true`. The admission controller restarts once.

### 3b. The policy, with your key

```bash
cd /tmp && { [ -d policies ] || git clone http://localhost:3300/platform/policies.git; } && cd policies && git pull
~/idp-lab/platform-labs/lab-10-supply-chain/fill-key.sh ~/idp-lab/supplychain/cosign.pub \
  ~/idp-lab/platform-labs/lab-10-supply-chain/policies/30-verify-images.yaml > 30-verify-images.yaml
grep -c "BEGIN PUBLIC KEY" 30-verify-images.yaml      # expect 2
git add 30-verify-images.yaml && git commit -m "Verify platform images: signature and SBOM" && git push
kubectl --context hub -n argocd annotate app policies-cell-1 policies-cell-2 argocd.argoproj.io/refresh=normal --overwrite
kubectl --context cell-1 get clusterpolicy verify-platform-images
```

**You should see:** `READY True`.

Only the **public** key goes into Git. Anyone may read it; only the private key can sign.

---

## Step 4: Prove it in cell-1

```bash
kubectl --context cell-1 create namespace sc-test

# signed image: admitted
kubectl --context cell-1 -n sc-test run ok --image=idp-lab-control-plane:30880/golden/podinfo:6.7.1 \
  --labels=app.kubernetes.io/part-of=lab
kubectl --context cell-1 -n sc-test get pod ok -o jsonpath='{.spec.containers[0].image}{"\n"}'

# unsigned image: denied
kubectl --context cell-1 -n sc-test run bad --image=idp-lab-control-plane:30880/thirdparty/nginx:1.27-alpine \
  --labels=app.kubernetes.io/part-of=lab
```

**You should see:**
- `ok` runs, and its image is now `…/golden/podinfo:6.7.1@sha256:…`. Kyverno pinned it to the
  digest it verified (`mutateDigest`).
- `bad` is **denied** by `verify-platform-images` (`failed to verify image`): it has no signature.

The `part-of` label is there because your Lab 5 guardrails still apply.

> **Think:** images from *other* registries (Docker Hub, ghcr.io) aren't checked by this rule at
> all. The next step in production: only allow the platform registry (a validate rule on the
> image prefix), and mirror third-party images into it after scanning.

Clean up: `kubectl --context cell-1 delete namespace sc-test`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `crane` or `cosign` hangs | The Docker Desktop credential helper; the script sets an empty `DOCKER_CONFIG` |
| `ok` denied with "http: server gave HTTP response to HTTPS client" | Step 3a not applied, or the admission controller hasn't restarted |
| `ok` pod `ErrImagePull` | `setup-registry.sh` didn't configure that cell's containerd; run it again |
| Policy not Ready | The key wasn't filled in (still `COSIGN_PUBLIC_KEY`) or the indentation broke |
| Denied for "no matching attestations" | `cosign attest` didn't run, or was run against a different digest |

---

## Questions to think through

1. **Keys vs keyless vs KMS.** Keyless (Fulcio/OIDC): the CI job's identity signs, nothing to
   leak, but it needs to reach Sigstore. In regulated environments: a private Sigstore, or
   KMS-held keys inside the boundary.
2. **What does SLSA level 3 ask for?** A hardened, isolated build service and provenance the
   build itself can't fake. How far does your CI get you?
3. **An SBOM shows a critical CVE in a base image used by 140 services.** An SBOM index finds
   them, automated dependency PRs, rebuild the golden base image, ring rollout, and a policy
   grace period for the stragglers.
4. **Sign at build, verify at admission, and what else?** Re-verify continuously (background
   scans), because keys get revoked and new CVEs appear after deploy.
