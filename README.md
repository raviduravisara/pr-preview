# pr-preview

Every pull request gets its own isolated, live, disposable copy of the application —
database included — reachable over HTTPS and destroyed automatically when the PR closes.

```
Open a PR → get a link.    Push → the link updates.    Merge → everything disappears.
```

Add ten lines to a repository. Nobody on the team installs anything.

---

## Quickstart

**1. Set up a cluster once, on any machine with Docker**

```powershell
git clone https://github.com/raviduravisara/pr-preview
cd pr-preview
./scripts/install.ps1 -Repo your-org/your-app -Token <runner token>
```

The token comes from your repository's *Settings → Actions → Runners → New self-hosted
runner*. The script creates the cluster, installs TTL cleanup, registers the runner, and
prints the URL pattern your previews will use.

**2. Add this to any repository that should get previews**

`.github/workflows/preview.yml`

```yaml
name: preview
on:
  pull_request:
    types: [opened, synchronize, closed]

permissions:
  contents: read
  packages: write
  pull-requests: write

jobs:
  preview:
    uses: raviduravisara/pr-preview/.github/workflows/preview.yml@main
    with:
      host-ip: 192.168.1.10   # printed by install.ps1
      app-port: 3000
      database: postgres
    secrets: inherit
```

**3. There is no step three.** Open a pull request and a comment appears with a live URL.

One cluster serves any number of repositories. Teammates do nothing at all — they open pull
requests as usual and get links.

---

## Why

Reviewing a pull request usually means reading a diff and imagining the behaviour. Checking
it for real means pulling the branch, installing dependencies, running migrations and
starting a server — fifteen minutes that most reviewers skip. Teams sharing one staging
environment trade that for a queue: *"don't deploy, QA is testing."*

This gives every pull request its own environment instead. Reviewers click a link. Product
managers who cannot run code click the same link. Two open pull requests never collide,
because each owns its namespace and its database.

Vercel and Netlify sell this as a headline feature. This is that feature, self-hosted, on
hardware you already own — and your source never leaves it.

---

## Configuration

| Input | Default | Meaning |
|-------|---------|---------|
| `domain` | *(empty)* | Serve previews under your own domain. Host becomes `pr-<n>-preview.<domain>`. |
| `host-ip` | *(empty)* | Machine IP for free `sslip.io` URLs when no domain is set. |
| `app-path` | `./` | Directory containing the Dockerfile. |
| `app-port` | `8080` | Port the application listens on. |
| `health-path` | `/healthz` | Probe path. Empty disables probes. |
| `database` | `none` | `postgres`, `mysql`, `mongodb`, or `none`. |
| `seed-file` | *(empty)* | File in `charts/preview/seed/` run once the database is ready. |
| `registry` | *(empty)* | Push images here, e.g. `ghcr.io/org`. Empty builds locally and imports into the cluster. |
| `runs-on` | `self-hosted` | Runner label. Must reach the cluster when `registry` is empty. |

### URLs without a domain

With no `domain`, previews are served on [sslip.io](https://sslip.io), which resolves any
hostname containing an IP back to that IP — no DNS record, no registrar, no account:

```
http://pr-41-preview.192-168-1-10.sslip.io:8080
```

Reachable by anyone on the same network. Set `domain` instead for public HTTPS URLs.

### Requirements

- Docker, and the machine running the cluster stays on while previews are in use
- Workflow permissions set to read and write, under *Settings → Actions → General*
- The application reads configuration from environment variables — `PR_NUMBER`, `GIT_SHA`
  and `DATABASE_URL` are injected automatically

---

## Architecture

```
GitHub PR event (opened · synchronize · closed)
        |
        v
Reusable workflow ---> runner on your machine
        |
        +-- docker build -> image tagged pr-<n>-<sha>
        +-- import into cluster, or push to a registry
        +-- helm upgrade --install -> namespace pr-<n>
        +-- kubectl annotate -> last-deploy timestamp
        +-- sticky PR comment with the URL
                                |
+-------------------------------+------------------------------+
|  your machine                 v                              |
|                    +---------------------+                   |
|   cloudflared ---> | Traefik (in k3s)    |                   |
|        ^           +----------+----------+                   |
|        |                      | routes by Host header        |
|        |        +-------------+-------------+                |
|        |        v                           v                |
|        |   namespace pr-41            namespace pr-42        |
|        |   +- app                     +- app                 |
|        |   +- database                +- database            |
|        |   +- secret (generated)      +- secret (generated)  |
|        |   +- seed job                +- seed job            |
|        |                                                     |
|        |   namespace preview-system                          |
|        |   +- ttl-cleanup CronJob (hourly)                   |
|        |   +- prometheus + grafana                           |
+--------+-----------------------------------------------------+
         | outbound-only tunnel, no public IP, no port forwarding
         v
   Cloudflare edge (terminates TLS)
```

**Isolation.** One namespace per pull request. Namespaces share the cluster but cannot see
each other, so `pr-41` and `pr-42` can both hold a Service named `app` and a database with
entirely different rows. Updates are `helm upgrade --install` into the same namespace, which
is idempotent — ten pushes update one environment rather than creating ten. Teardown deletes
the namespace, which takes everything with it.

**Public access without a public IP.** `cloudflared` opens an outbound connection to
Cloudflare's edge and serves traffic back down it. Nothing on the machine listens for
inbound connections; no port forwarding, no firewall exception. TLS terminates at the edge.

---

## Per-preview databases

Set `database` to `postgres`, `mysql`, or `mongodb` and each preview gets its own instance,
its own generated password, and its own seeded data. Testers can delete everything in PR #41
without PR #42 noticing.

Passwords are never written to `values.yaml` or committed. Helm generates one at install
time and stores it in a Secret, reusing any password already present — otherwise every
`helm upgrade` would mint a new one while the running database still held the old, and the
application would start being rejected on the second push.

The seed job polls for readiness before connecting, closing the race between "the database
pod is running" and "the database is accepting connections".

---

## TTL cleanup

A Go program using the Kubernetes client library, running hourly as a CronJob.

Measuring idleness by namespace age would delete environments belonging to pull requests
under active development. Instead the workflow stamps each namespace on every push:

```
preview.dev/last-deploy: 2026-08-19T07:10:57Z
```

The cleanup job reads that annotation and deletes namespaces older than `TTL` (default
`48h`). An actively updated pull request keeps refreshing its stamp and never expires; an
abandoned one is reaped. Namespaces without the annotation fall back to creation time.

It runs under a ServiceAccount whose ClusterRole grants exactly two verbs — `list` and
`delete`, on namespaces and nothing else. `DRY_RUN=true` reports what it would remove
without removing anything.

---

## What a preview costs

Reserved per namespace by the `ResourceQuota`:

| Resource | Requested | Ceiling |
|----------|-----------|---------|
| CPU requests | 35m | 1 |
| Memory requests | 80Mi | 512Mi |
| Memory limits | 320Mi | 1Gi |
| Pods | 2 | 10 |

Measured in Grafana with two idle environments: **~54 MiB and under 0.002 cores each**. Idle
previews cost almost nothing in CPU; concurrency is bounded by memory — roughly a dozen
simultaneous environments on a modest workstation.

Every namespace also carries a `LimitRange`, which is not optional once a quota exists:
Kubernetes rejects containers with no resource requests outright, so a quota without a
LimitRange breaks every workload that forgot to set them.

### Monitoring

```powershell
kubectl apply -f infra/monitoring/
```

Prometheus scrapes cAdvisor and kube-state-metrics; Grafana provisions its datasource and
dashboard from ConfigMaps. The dashboard reports live environment count, per-namespace CPU
and memory, and a step graph of previews over time.

---

## Repository layout

```
.github/workflows/preview.yml   the reusable workflow other repositories call
charts/preview/                 Helm chart, one complete environment
  templates/                    deployment, service, ingress, database, seed job, quota
  seed/                         seed files, selected per repository
tools/ttl-cleanup/              Go cleanup tool
infra/                          cluster-wide manifests (CronJob, RBAC, monitoring)
scripts/install.ps1             one-command cluster setup
examples/guestbook/             demo application this repository previews for itself
```

This repository uses its own tool: [preview-deploy.yml](.github/workflows/preview-deploy.yml)
is the same ten-line call any other repository would make.

---

## Notes from building it

**A wildcard certificate covers one level.** Cloudflare's free Universal SSL covers
`*.example.com` but not `*.preview.example.com` — a wildcard matches exactly one label. The
first URL scheme, `pr-41.preview.<domain>`, failed TLS for that reason. Flattening it to
`pr-41-preview.<domain>` keeps every preview inside the free certificate.

**Expressions are not a shell.** GitHub Actions has no `split()` or `replace()`. Both were
used and both produced `Unrecognized function` at workflow-validation time, before any job
started. String manipulation belongs in `actions/github-script`.

**A called workflow cannot exceed its caller's permissions.** With repository defaults set
to read-only, the nested job requesting `packages: write` failed validation. The caller must
declare the permissions explicitly.

**`shell: bash` on a Windows runner is Git Bash**, which strips the backslashes out of
`C:\actions-runner\_work\...` and reports "No such file or directory". The steps here avoid
pinning a shell at all, so the workflow runs on either platform.

**`nodes/metrics` is not `nodes/proxy`.** Prometheus scraped kube-state-metrics happily but
got `403 Forbidden` on every cAdvisor target. Reaching a kubelet through the API server is a
proxy operation and needs the `nodes/proxy` subresource.

**Ephemeral means ephemeral.** Databases use an `emptyDir` volume rather than a
PersistentVolumeClaim. Preview data is disposable by definition, and PVCs would outlive the
namespaces that created them.

---

## Cost

| Item | Cost |
|------|------|
| Domain | optional, `sslip.io` URLs are free |
| GitHub Actions, GHCR (public repo) | free |
| Cloudflare DNS, Tunnel, TLS | free |
| k3s, Helm, Traefik, databases, Prometheus | free |
| Compute | a machine you already have |

Originally specified against a cloud VM. The credit expired before the build started, which
turned out to be a better constraint: a cluster that rebuilds in sixty seconds is one you are
willing to break, and the tunnel removes the last reason to pay for a public IP.

The trade is honest — previews are reachable while the machine is on. Moving to a server is a
kubeconfig swap and a DNS record; the chart, the workflow and the application do not change.

---

## License

MIT. See [LICENSE](LICENSE).
