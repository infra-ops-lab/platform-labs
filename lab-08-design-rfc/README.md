# Lab 8: Write the design RFC

**Time:** about 90 minutes · **Level:** senior / staff · **Needs:** Labs 0–7 (you'll quote them)

Senior engineers lead through writing. In this lab you write the design document that explains
**why** the lab is built the way it is: cells, rings, guardrails and a golden path. You'll then
defend it out loud.

---

## Part A: What an RFC is

An **RFC** ("request for comments") or **design doc** is a short document that proposes a
change, compares options and records the decision **before** the work starts. A good one:

- starts from the **problem**, not the solution;
- compares **real options**, including "do nothing" or the boring one;
- makes every decision with its **trade-off** stated ("we accept X to get Y");
- has **measurable** success metrics;
- has a **migration plan**, because nobody starts from zero.

---

## The task

Write: **"Cell-based tenant placement and ring rollout for a multi-tenant SaaS platform"**.

The scenario:
- Kubernetes on two clouds (EKS and AKS);
- about 500 tenants on shared clusters today;
- some tenants need a **dedicated** or **regulated** environment (for example FedRAMP);
- one bad deploy or a noisy tenant currently affects everyone in a region.

Rules:
1. Use the sections in [`rfc-template.md`](rfc-template.md): Context, Goals, Non-goals, Options
   considered (at least 3), Decision, Risks, Migration plan, Success metrics, Cost.
2. 600–2,000 words. Every decision states its trade-off.
3. At least one diagram (ASCII is fine).
4. Then answer this **aloud, in 3 minutes, with a timer**: *"Why not just one big cluster per region?"*

```bash
cp ~/idp-lab/platform-labs/lab-08-design-rfc/rfc-template.md ~/rfc-cell-placement.md
wc -w ~/rfc-cell-placement.md        # check the length when you're done
```

---

## Hints

<details markdown="1"><summary>Hint 1: the options</summary>

| Option | Good at | Weak at |
|---|---|---|
| Shared clusters, namespace per tenant | Cheapest, simplest to run | Blast radius = the whole cluster; noisy neighbours; weak isolation for regulated tenants |
| Cells (N tenants per cell) | Bounded blast radius; rings map onto cells; capacity limit per cell | Fixed cost per cell; needs placement and routing |
| Cluster per tenant | Strongest isolation | Cost and operations grow with every tenant; upgrades for 500 clusters |
| Hybrid | Shared cells for most tenants, dedicated cells for regulated or large ones | Two kinds of cell to run (but the same blueprint) |
</details>

<details markdown="1"><summary>Hint 2: make the cell a product</summary>

- **A fixed blueprint**: Terraform or Crossplane builds every cell the same way; add-ons come
  from ApplicationSets (Labs 1, 5, 6).
- **A capacity limit**: for example, at most 50 tenants or N pods per cell. A full cell means
  you build a new one; you don't grow the old one.
- **A placement service**: the single source of truth for which tenant lives in which cell.
- **A cell router**: DNS or edge routing by tenant ID.
- **Rings**: canary cell → ring 0 → ring 1 … (Lab 4), canaries inside each cell (Lab 6).
</details>

<details markdown="1"><summary>Hint 3: metrics</summary>

- **Blast radius**: the largest % of tenants one bad deploy can affect.
- **Cell provisioning time**: from "we need a cell" to "it takes tenants".
- **Deploy lead time across all rings.**
- **Cost per tenant**, and the fixed cost of an empty cell.
- **Migration progress**: % of tenants on cells.
</details>

<details markdown="1"><summary>Hint 4: the 3-minute answer</summary>

Structure: **blast radius → noisy neighbours → compliance boundary → upgrades → limits → what
it costs**. One big cluster makes every control-plane upgrade, CNI bug or bad admission
webhook a regional outage. Kubernetes has scaling limits (etcd size, objects, nodes). Regulated
tenants need their own boundary anyway. Cells cost more in fixed overhead; that's the trade-off
you accept for a bounded blast radius.
</details>

---

## Check your work

- [ ] All nine sections are there.
- [ ] At least three options, each with pros, cons and cost.
- [ ] The decision names the trade-off in one sentence.
- [ ] One diagram.
- [ ] 600–2,000 words (`wc -w`).
- [ ] The success metrics are numbers you could measure.
- [ ] The migration plan says what moves first and how you go back.
- [ ] You answered "why not one big cluster per region?" aloud in under 3 minutes.

---

## Questions a reviewer will ask

1. **How do you move a live tenant between cells with no downtime?** Data replication
   (dual-write or change-data-capture), switch at the router, a rollback plan, and one tenant at
   a time.
2. **Who owns the placement service, and what happens when it's down?** The edge keeps a static
   routing cache. The control plane must not be in the request path.
3. **How does this change on-call?** Alerts per cell; an embedded SRE in each product team plus a
   central platform SRE team; runbooks per cell type.
