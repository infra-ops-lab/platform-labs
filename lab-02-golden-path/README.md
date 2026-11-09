# Lab 2: Golden path (a Backstage software template)

**Time:** 60–90 minutes · **Needs:** Lab 1

Goal: one form in Backstage creates a new service that is **secure, standard, owned,
documented and deployed to every cell**.

## What happens when someone clicks Create

```text
Form (name, description, owner, tier, replicas)
  │
  ├─ fetch:template    render skeleton/ with the answers
  ├─ publish:gitea     create golden/<name> and push the files
  └─ catalog:register  add the Component to the Backstage catalog
                          │
        Lab 1 ApplicationSet finds deploy/ ──► <name>-cell-1, <name>-cell-2
```

Backstage creates the repo and the catalog entry. Argo CD does the deploying. They never call
each other: they meet through Git.

## The files

```text
golden-service/
├── template.yaml            the form (parameters), the steps, the output links
└── skeleton/                copied into the new repo; ${{ values.x }} is filled in
    ├── catalog-info.yaml    Component: owner, lifecycle, TechDocs annotation
    ├── mkdocs.yml, docs/    the service's docs page
    └── deploy/
        ├── kustomization.yaml   app.kubernetes.io/* labels
        ├── deployment.yaml      podinfo 6.7.1 on :9898 with the guardrails
        └── service.yaml         port 80 → 9898
```

Guardrails built into `deployment.yaml`: readiness and liveness probes, requests and limits,
`runAsNonRoot` with a numeric `runAsUser`, read-only root filesystem, all capabilities dropped,
seccomp `RuntimeDefault`.

Two design details:

- `template.yaml` uses `${{ parameters.x }}`; files in `skeleton/` use `${{ values.x }}`.
- Only stable labels (`name`, `instance`, `part-of`) go into the Deployment **selector**.
  Selectors can't change after creation, so `tier` and `version` are labels on the objects and
  pods but not in the selector.

## Step 1: Let Backstage load the template

Backstage reads templates from catalog locations in `app-config.local.yaml`. Point one at this
folder (the path is relative to `packages/backend`):

```yaml
catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Group, User, Template]
  locations:
    - type: file
      target: ../../../templates/*/template.yaml      # e.g. copy golden-service/ into ~/idp-lab/templates/
```

The Gitea integration must match the host used in `publish:gitea` (`localhost:3300`):

```yaml
integrations:
  gitea:
    - host: localhost:3300
      baseUrl: http://localhost:3300
      username: <gitea user>
      password: ${GITEA_TOKEN}          # a Gitea access token, from the environment
```

Restart Backstage, then open http://localhost:3000/create. **Golden path - HTTP microservice**
should be listed. After the first load, edits are picked up on the next catalog refresh.

## Step 2: Test without creating anything

Backstage has a **Template Editor** at http://localhost:3000/create/edit: load the template
folder, fill in the form and see the rendered files without publishing. Steps that can't
dry-run (`publish:gitea`, `catalog:register`) are skipped.

## Problems met while building it

| Problem | Fix (already in this template) |
|---|---|
| `publish:gitea ... requires property "description"` | Description is a required form field, plus a fallback value in the step |
| `catalog:register` 404 | `publish:gitea` returns a contents URL without the branch, so `catalogInfoUrl` is built explicitly with `/src/branch/main/catalog-info.yaml` |
| Pods `CreateContainerConfigError` | `runAsNonRoot` needs a numeric `runAsUser` for this image |
| Template not on the Create page | YAML error or wrong location path. Check the Backstage log for the template name |
| Red error overlay on every page in dev mode | Not the template: read the call stack. Here it was the sample "Random Joke" home widget calling a public API that was down; it's disabled with `- home-page-widget:home/random-joke: false` |

## Questions to think through

1. 300 repos were created from v1 of the template. Now the probes must change. How do you roll
   that out? (a shared, versioned base or Helm chart; bot PRs; never re-scaffold)
2. Build or buy a developer portal? (team size, plugin ecosystem, TypeScript skills, ongoing cost)
3. Who may run which template, and as which Git identity? (permission framework, least-privilege bot or the user's own token, audit of scaffolder tasks)
