# PulseGate

PulseGate is an uptime monitor. Register a URL and a probe interval; it checks that URL on that interval and tells you when the URL stops answering.

The application is deliberately small. The subject of this repository is the Azure and Kubernetes resource graph underneath it — designed in prose before it is written in code, built one milestone at a time, and never built further ahead than the application can actually use.

## The product

Three endpoints:

| Endpoint | Behavior |
| --- | --- |
| `POST /monitors` | Accepts a URL and a probe interval, returns a monitor ID |
| `GET /monitors/{id}` | Returns current state, last check time, uptime percentage |
| `GET /monitors/{id}/checks` | Returns recent check results |

And, once the probe work is split off the request path, three components:

| Component | Kubernetes object | Behavior |
| --- | --- | --- |
| `api` | Deployment | The three endpoints above |
| `scheduler` | CronJob | Every minute, finds monitors that are due and enqueues them |
| `checker` | Deployment | Pulls from the queue, performs the HTTP probe, writes the result |

A few hundred lines of Python, and no more interesting than that. Everything worth reading here starts at the container boundary and works outward.

## The problem at the centre of it

A service whose whole job is fetching URLs that strangers supply is a server-side request forgery engine by construction. It runs inside a virtual network, and the addresses it can be told to reach include the project's own PostgreSQL server, the Instance Metadata Service at `169.254.169.254`, and every private subnet in the VNet.

Egress control is therefore not a hardening pass bolted on at the end. It is the product's defining constraint, and it shapes the network from the first milestone that has one. `v1-network` puts a NAT Gateway in front of outbound traffic so the platform has a single known, attributable source address. `v10-harden` closes the loop: the checker pods get an egress policy that permits the public internet and denies every RFC 1918 range, the link-local address, and the cluster's own service CIDR. A pod that can reach any public URL and no private one is not what any Kubernetes network gives you by default — it has to be built.

The same property has a second consequence at the edge. `POST /monitors` is a public, unauthenticated write that makes the platform issue an outbound request to an address the caller chose. Rate limiting it in `v9-edge` is a functional requirement, not a nicety.

## Why an uptime monitor, and why Kubernetes

The product was picked so that Kubernetes is the honest answer rather than the fashionable one. Every primitive in the roadmap has a reason to exist here that comes from the product itself.

| What the product needs | What that forces into the design | Milestone |
| --- | --- | --- |
| Probes that fire on a fixed schedule | `CronJob`, with the concurrency control the platform already enforces | `v5-state` |
| Probe load that is spiky, not steady | KEDA on queue depth, cluster autoscaler, a Spot node pool | `v6-scale` |
| Checkers that may be evicted; an API that may not | Two node pools, taints and tolerations, PodDisruptionBudgets | `v6-scale` |
| Three components that version independently | Argo CD app-of-apps, sync waves | `v3-gitops` |
| A monitoring product that cannot be down during its own deploy | Argo Rollouts canary, analysis queried from Prometheus | `v8-progressive` |
| Check results as time series, then as retained history | PostgreSQL, then managed Prometheus, then a retention policy | `v5-state`, `v7-observable` |
| Outbound HTTP to arbitrary, user-supplied URLs | Controlled egress: NAT Gateway, egress NetworkPolicy, then a firewall enforcing the same rule from outside the cluster | `v1-network`, `v10-harden`, `v12-govern` |
| A public write endpoint that will be abused | Front Door WAF, rate limiting, request validation | `v9-edge` |

Nothing in that table is there because it would look good in a diagram. Remove the product and every row loses its justification.

## What it costs to keep this affordable

The method here is to stand the infrastructure up, work on it, and tear it down again — which only works if there is no large fixed monthly floor underneath. A managed Kubernetes service that bills for its control plane by the month puts exactly such a floor in place, and the nightly teardown becomes theatre.

The stack is destroyed at the end of every session and rebuilt from zero at the start of the next one. That is the constraint everything else here answers to: the repository has to be able to recreate the platform without a human remembering anything, because nothing is left running to remember it from. What persists between sessions is this repository, the images in `ghcr.io`, and the state backend — the Azure infrastructure itself does not.

AKS prices the control plane by tier and the bottom tier is free. There is no uptime SLA on that tier, which is the right trade for a cluster with no users that spends most of its life deallocated. `az aks stop` deallocates the node pool VMs and leaves the cluster object behind, so a pause between sessions is one command rather than a rebuild. [COST.md](COST.md) carries the numbers and the difference between stopping and destroying.

Two Azure specifics shape the design and are noted where they land:

- **Identity.** Entra Workload Identity federates a Kubernetes ServiceAccount token to a managed identity, so a pod reaches the database or the vault with no stored credential anywhere. It costs nothing, and `v2-cluster` turns it on before anything needs it, because enabling it later is a cluster update you would rather not have to schedule.
- **Secrets.** Key Vault charges per operation and nothing for the vault itself. The vault therefore does not have to be destroyed nightly to keep the project cheap, and holding secrets adds no permanent monthly floor.

## Where the application fits

The application shows up in `v2-cluster`, the first milestone with a cluster to run it on. A scheduler with no pods to run is not worth building. Before that, `v1-network` proves out private subnets and private access against a host that answers `/healthz` and nothing else.

From there the code arrives in whatever order the infrastructure can support.

| Milestone | The application | Deployed by |
| --- | --- | --- |
| `v1-network` | Nothing. A `/healthz` answer on a virtual machine | Not applicable |
| `v2-cluster` | `/healthz` plus a monitor list from an in-memory map | `docker build` on your machine, `kubectl apply` by hand |
| `v3-gitops` | Unchanged — what moves is who applies the manifests | Argo CD, from the `gitops/` path |
| `v4-pipeline` | Unchanged — what moves is who builds the image | GitHub Actions on merge, then Argo CD |
| `v5-state` | The three real endpoints, plus the scheduler and checker split | GitHub Actions, then Argo CD |
| `v6-scale` | The checker becomes horizontally elastic | GitHub Actions, then Argo CD |
| `v8-progressive` | A `/metrics` endpoint the canary analysis can query | GitHub Actions, then Argo Rollouts |

It stays a stub until `v5-state`, and the reason is honest rather than tidy: there is no store, so `POST /monitors` has nowhere to persist a monitor, and no queue, so the scheduler and checker have nothing to talk through.

`v5-state` is the change that carries real design weight. Before it, PulseGate is one process. After it, the probe work has left the request path entirely — the CronJob only enqueues, the checkers only consume, the API only reads what they wrote. That separation is what makes the checker fleet independently scalable in `v6-scale`, and it is the reason the product belongs on Kubernetes at all.

Writing more application than the infrastructure can currently carry is the specific failure this ordering exists to prevent.

## What the infrastructure asks of the application

The language is Python. The framework is chosen in `v2-cluster`, and only five properties matter to anything outside the container:

- Separate `/healthz` and `/readyz` routes. Readiness may check the database; liveness must not. A liveness probe that fails when PostgreSQL is slow restarts every healthy pod in the cluster at the worst possible moment.
- It listens on the port the container spec declares.
- It is async. The checker's entire job is waiting on remote HTTP, and a synchronous worker blocks on every probe.
- One process per container, so CPU stays a clean autoscaling signal.
- It handles `SIGTERM`: stop taking work, finish the in-flight probe, exit. `v6-scale` puts checkers on Spot nodes, and a Spot eviction gives thirty seconds of notice.

The container image is the real interface between the application and everything else here. Nothing downstream of the registry knows what is inside it, which is also what would make a later change of language cheap.

## Repository layout

```
bootstrap/    Terraform, applied once. The state backend and nothing else.
modules/      Terraform modules: network, cluster, data, observability, edge.
live/         Terragrunt. One directory per environment, pointing at modules/.
  _envcommon/   Component config shared by all three environments.
  dev/  stage/  prod/
  shared/       What the environments have in common: the identities.
charts/       Helm charts, if the v3-gitops decision goes that way.
gitops/       What Argo CD reads. Each subtree carries the three environments.
  bootstrap/    The root app-of-apps Application, one per cluster.
    dev/  stage/  prod/
  platform/     In-cluster platform: ingress, KEDA, OpenTelemetry, Rollouts.
    base/  dev/  stage/  prod/
  workloads/    api, scheduler and checker, with the pinned image digests.
    base/  dev/  stage/  prod/
scripts/      What the daily rebuild needs, starting with the Argo CD bootstrap.
.github/      Workflows.
```

**Three environments — `dev`, `stage`, `prod` — built from one set of modules by Terragrunt.** `modules/` holds the Terraform and knows nothing about environments; `live/` holds a small `terragrunt.hcl` per component per environment, supplying inputs and declaring dependencies. The difference between the environments is inputs, not code: `dev` runs single-zone on Spot with the cheapest SKUs, `prod` runs zone-redundant with the api off Spot, and `stage` matches prod's shape at prod's smallest size.

Terragrunt is here for three things Terraform alone makes repetitive across environments — a `remote_state` block that derives each state key from the directory path, so the environments cannot collide in the backend; `dependency` blocks so the cluster plans against the network's real outputs; and `run-all` to apply or destroy a whole environment in order.

`dev` is the environment that stays up during a session. `stage` and `prod` are applied to prove the promotion path and destroyed after. That is a cost decision and a quota one — the arithmetic is in [COST.md](COST.md).

The seam between `live/` and `gitops/` is deliberate and is defined in `v3-gitops`. Terraform stops at the cluster boundary: it creates the cluster, the databases and the identities, and then it stops. Everything that lives *inside* the cluster is a manifest under `gitops/`, reconciled by Argo CD, and Terraform never applies it.

The one exception is Argo CD itself, which cannot install itself. That bootstrap problem, and the reasoning behind how it is solved, belongs to `v3-gitops`.

**The application source is not in this repository.** It lives in its own, and what this one holds is the platform: the infrastructure, the deployment configuration Argo CD reconciles, the charts and the workflows. That is the canonical Argo CD split — application source on one side, deployment configuration on the other — and the reason behind it is real: CI writing an image digest back into the repository that triggered CI is a loop.

The seam falls on `apps/` leaving rather than `gitops/`, which is the better of the two cuts. Deployment configuration belongs with the platform that reconciles it, not with the application that happens to be deployed by it — `gitops/platform/` is most of that tree and has nothing to do with the application at all.

What the split costs is that the digest write becomes cross-repository, and `GITHUB_TOKEN` is scoped to the repository running the job. Whether the application repository pushes the digest here with a stored credential, or a workflow here pulls it from the registry with none, is an open decision in [ROADMAP.md](ROADMAP.md), due at `v4-pipeline`. It is the first point in this project where a stored secret is a candidate at all, which is why it is being decided rather than defaulted.

## Where the project stands

Nothing is applied. `v0-bootstrap` is under way: the documentation, the `.gitignore`, the directory skeleton and the `bootstrap/` Terraform are written, and no Azure resource exists yet.

The documentation and the `.gitignore` came first, in that order and on purpose — the ignore file has to be right before the first apply, not after it. State files and plan files both carry resource attributes in plaintext, and a secret that reaches a commit is disclosed whether or not the next commit removes it.

`v0-bootstrap` is finished when a pull request can plan against remote state in Azure Blob Storage using a federated credential that exists only for the life of the job, and no identity in the pipeline holds a client secret.

## How these documents work

The infrastructure is described in prose: which resources, how they connect, which arguments matter and why. It is not copy-paste HCL or YAML, because the goal is a mental model of the resource graph rather than a pile of configuration.

- [ROADMAP.md](ROADMAP.md) — the thirteen milestones, what each one builds, and current status.
- [COST.md](COST.md) — the cost model that governs what gets built and what gets refused.
- [RUNBOOK.md](RUNBOOK.md) — the operations that have no Terraform resource.
