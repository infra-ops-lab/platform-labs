# RFC: Cell-based tenant placement and ring rollout

| | |
|---|---|
| Author | [your name] |
| Status | Draft / In review / Accepted |
| Reviewers | [platform, security, SRE, product engineering] |
| Last updated | [date] |

## Context
<!-- What is true today, and why it hurts. Numbers if you have them: tenants, clusters,
     incidents caused by shared blast radius, time to onboard a tenant, deploy lead time. -->

## Goals
<!-- 3-5 measurable outcomes. -->
-

## Non-goals
<!-- What this RFC deliberately does not solve. -->
-

## Options considered
<!-- At least three. For each: how it works, pros, cons, cost, and what kind of tenant it fits. -->

### Option A: Shared clusters, namespace per tenant

### Option B: Cells (N tenants per cell, bounded size)

### Option C: Cluster per tenant

### Option D: Hybrid (shared cells plus dedicated cells for regulated or large tenants)

## Decision
<!-- The option, and the trade-off you accept. Include one diagram. -->

```text
(diagram)
```

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| | | | |

## Migration plan
<!-- From today's shared clusters to the target. Phases, what moves first, how you roll back. -->

## Success metrics
<!-- Blast radius, cell provisioning time, deploy lead time across all rings, cost per tenant,
     migration progress. -->

## Cost
<!-- Fixed cost per cell (control plane, add-ons, observability), cost per tenant, break-even
     point, who pays for idle capacity. -->

## Open questions
-
