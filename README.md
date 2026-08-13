# pr-preview

Every pull request gets its own isolated, live, disposable copy of the application —
database included — reachable over HTTPS and destroyed automatically when the PR closes.

```
Open a PR  →  get a link.     Push  →  the link updates.     Merge  →  everything disappears.
```

No one on the team runs a command. Median time from PR open to live URL is about two
minutes.

---

## Why

Reviewing a pull request usually means reading a diff and imagining the behaviour. Checking
it for real means pulling the branch, installing dependencies, running migrations and
starting a server — fifteen minutes that most reviewers skip. Teams that share one staging
environment trade that for a queue: *"don't deploy, QA is testing."*

This gives every pull request its own environment instead. Reviewers click a link. Product
managers who cannot run code click the same link. Two open PRs never collide, because each
one owns its namespace and its database.

Vercel and Netlify sell this as a headline feature. This is that feature, built from
primitives on hardware that costs nothing.

---

## Architecture

```
GitHub PR event (opened · synchronize · closed)
        │
        ▼
GitHub Actions ──▶ self-hosted runner on the workstation
        │
        ├── docker build → image tagged pr-<n>-<sha>
        ├── k3d image import → cluster
        ├── helm upgrade --install → namespace pr-<n>
        ├── kubectl annotate → last-deploy timestamp
        └── sticky PR comment with the URL
                                │
┌───────────────────────────────┼──────────────────────────────┐
│  workstation                  ▼                              │
│                    ┌─────────────────────┐                   │
│   cloudflared ───▶ │ Traefik (in k3s)    │                   │
│        ▲           └──────────┬──────────┘                   │
│        │                      │ routes by Host header        │
│        │        ┌─────────────┴─────────────┐                │
│        │        ▼                           ▼                │
│        │   namespace pr-41            namespace pr-42        │
│        │   ├─ app (Go)                ├─ app (Go)            │
│        │   ├─ postgres                ├─ postgres            │
│        │   ├─ secret (generated)      ├─ secret (generated)  │
│        │   └─ seed job                └─ seed job            │
│        │                                                      │
│        │   namespace preview-system                          │
│        │   └─ ttl-cleanup CronJob (hourly)                   │
└────────┼──────────────────────────────────────────────────────┘
         │ outbound-only tunnel — no public IP, no port forwarding
         ▼
   Cloudflare edge (terminates TLS)
         │
         ▼
   https://pr-42-preview.ravidu.space
```

**Isolation model.** One Kubernetes namespace per pull request. Namespaces share the cluster
but cannot see each other, so `pr-41` and `pr-42` can both have a Service named `app` and a
Postgres holding entirely different rows. Update is `helm upgrade --install` into the same
namespace, which is idempotent — pushing ten commits updates one environment rather than
creating ten. Teardown is deleting the namespace, which takes everything with it.

**Public access without a public IP.** `cloudflared` opens an outbound connection to
Cloudflare's edge and serves traffic back down it. Nothing on the workstation listens for
inbound connections; there is no port forwarding and no firewall exception. TLS terminates
at the edge, so preview URLs get a valid certificate for free.

---

## Components

| Component | Role |
|-----------|------|
| GitHub Actions | Builds, deploys, comments, destroys |
| Self-hosted runner | Gives CI access to a cluster that has no inbound route |
| k3s via k3d | Kubernetes, running in Docker on the workstation |
| Helm | One chart templates a complete environment per PR |
| Traefik | Routes `pr-<n>-preview.<domain>` to the right namespace |
| Cloudflare Tunnel | Public HTTPS with no public IP |
| PostgreSQL | One instance per namespace, credentials generated at deploy time |
| Seed Job | Creates the schema and fixture rows once Postgres is accepting connections |
| TTL CronJob | Deletes preview namespaces idle longer than 48h |
| ResourceQuota | Caps what one preview may consume, so a runaway PR cannot starve the cluster |

---

## The demo application

Deliberately small — a guestbook. It reads its identity (`PR_NUMBER`, `GIT_SHA`,
`BG_COLOR`) and its `DATABASE_URL` from the environment, so one image serves every
environment and behaves differently based only on what Kubernetes injects.

Its purpose is to make isolation *visible*: post a message in PR #41 and it does not appear
in PR #42. Two environments, two databases, no interference.

Written in Go and compiled into a `scratch` image — **11.8 MB**, no operating system layer.
Image size is not vanity here; it is the difference between a fast and a slow feedback loop
when every push rebuilds.

---

## Per-PR database credentials

Passwords are never written to `values.yaml` or committed. Helm generates one at install
time and stores it in a Kubernetes Secret:

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace "postgres" }}
{{- if $existing }}
{{- $password = index $existing.data "password" | b64dec }}
{{- else }}
{{- $password = randAlphaNum 24 }}
{{- end }}
```

The `lookup` matters. Without it `randAlphaNum` would mint a new password on every
`helm upgrade`, so the running Postgres — which still holds the old one — would start
rejecting the app on the second push.

The seed Job then polls `pg_isready` before connecting, which closes the race between
"Postgres pod is running" and "Postgres is accepting connections".

---

## TTL cleanup

A Go program using the Kubernetes client library, running hourly as a CronJob.

Measuring idleness by namespace age would delete environments belonging to PRs under active
development. Instead, the deploy workflow stamps each namespace on every push:

```
preview.ravidu.space/last-deploy: 2026-08-12T07:10:57Z
```

The cleanup job reads that annotation and deletes namespaces older than `TTL` (default
`48h`). An actively updated PR keeps refreshing its stamp and never expires; an abandoned
one is reaped. Namespaces without the annotation fall back to creation time, so anything
created outside the workflow is still collected.

It runs under a ServiceAccount whose ClusterRole grants exactly two verbs:

```yaml
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["list", "delete"]
```

`DRY_RUN=true` reports what it would remove without removing anything —
`infra/ttl-cleanup-dryrun.yaml` runs it that way with a 1-second TTL.

---

## What a preview environment costs

Measured on a live environment with `kubectl describe resourcequota`:

| Resource | Used | Namespace ceiling |
|----------|------|-------------------|
| CPU requests | 35m | 1 |
| Memory requests | 80Mi | 512Mi |
| Memory limits | 320Mi | 1Gi |
| Pods | 2 | 10 |

35 millicores is 3.5% of a single core, so concurrency is bounded by memory rather than CPU
— roughly a dozen simultaneous previews on a modest workstation.

Every namespace carries a `ResourceQuota` and a `LimitRange`. The quota is the ceiling; the
LimitRange supplies defaults for containers that do not declare their own requests, which is
not optional once a quota exists — Kubernetes rejects unspecified containers outright, so
adding a quota without a LimitRange breaks every workload that forgot to set them.

---

## Repository layout

```
app/                         Go demo application and its Dockerfile
charts/preview/              Helm chart — one complete environment
  templates/                 deployment, service, ingress, postgres, secret, seed job
  seed/seed.sql              schema and fixture rows
tools/ttl-cleanup/           Go cleanup tool
infra/                       cluster-wide manifests (CronJob, RBAC)
.github/workflows/           preview-deploy.yml, preview-destroy.yml
```

---

## Running it yourself

Requires Docker, k3d, kubectl, Helm, Go, cloudflared, and a domain on Cloudflare.

**1. Cluster**

```powershell
k3d cluster create preview --agents 2 --port "8080:80@loadbalancer"
```

**2. Tunnel**

```powershell
cloudflared tunnel login
cloudflared tunnel create preview
cloudflared tunnel route dns preview "*.<your-domain>"
```

Then point the tunnel at the cluster ingress in `~/.cloudflared/config.yml`:

```yaml
tunnel: <tunnel-id>
credentials-file: <path-to>/<tunnel-id>.json
ingress:
  - hostname: "*.<your-domain>"
    service: http://localhost:8080
  - service: http_status:404
```

Set `ingress.domain` in `charts/preview/values.yaml` to match.

**3. Runner**

Add a self-hosted runner under *Settings → Actions → Runners*, then run it interactively
(`run.cmd`) rather than as a service — a Windows service runs under an account that cannot
reach Docker Desktop or the cluster.

**4. TTL cleanup**

```powershell
docker build -t pr-preview-ttl-cleanup:dev ./tools/ttl-cleanup
k3d image import pr-preview-ttl-cleanup:dev -c preview
kubectl apply -f infra/ttl-cleanup.yaml
```

**5. Deploy one by hand**

```powershell
docker build -t pr-preview-app:dev ./app
k3d image import pr-preview-app:dev -c preview
helm upgrade --install pr-1 ./charts/preview --namespace pr-1 --create-namespace --set prNumber=1 --wait
```

---

## Notes from building it

**A single-level wildcard certificate.** Cloudflare's free Universal SSL covers
`*.example.com` but not `*.preview.example.com` — a wildcard matches exactly one label. The
first URL scheme, `pr-41.preview.<domain>`, failed TLS for that reason. Flattening it to
`pr-41-preview.<domain>` keeps every preview inside the free certificate. Advanced
Certificate Manager would cover deeper wildcards, but it costs more per month than the
domain does per year.

**Windows runners are PowerShell 5.1.** Not PowerShell 7. Bash `\` line continuations do not
parse, `shell: pwsh` fails unless PowerShell 7 is installed, and `Get-Date -AsUTC` does not
exist — `[DateTime]::UtcNow.ToString(...)` does.

**k3d writes `host.docker.internal` into the kubeconfig.** That resolves to whatever the
host's current LAN address is, so joining a different network breaks `kubectl` with a
connection timeout. Pointing the cluster at `https://127.0.0.1:<port>` avoids the drift.

**Ephemeral means ephemeral.** Postgres uses an `emptyDir` volume rather than a
PersistentVolumeClaim. Preview data is disposable by definition, and PVCs would outlive the
namespaces that created them.

---

## Cost

| Item | Cost |
|------|------|
| Domain | $1.18 for the first year |
| GitHub Actions, GHCR (public repo) | Free |
| Cloudflare DNS, Tunnel, TLS | Free |
| k3s, Helm, Traefik, PostgreSQL, Prometheus | Free |
| Compute | Existing workstation |

Originally specified against a cloud VM. The Azure credit expired before the build started,
which turned out to be a better constraint: a cluster that rebuilds in sixty seconds is one
you are willing to break, and the tunnel removes the last reason to pay for a public IP.

The trade is honest — previews are reachable while the workstation is on. The chart, the
workflows and the application are provider-neutral; moving to a VM is a kubeconfig swap and
a DNS record.

---

## Status

Working: per-PR environments with isolated databases, automatic teardown on close, TTL
reaping of idle namespaces, resource quotas, sticky PR comments, secret scanning in CI.

Next: a gitleaks pre-commit hook for local secret scanning, and a Prometheus/Grafana
dashboard tracking per-namespace resource use over time.
