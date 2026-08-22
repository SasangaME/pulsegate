# PulseGate

PulseGate is an uptime monitor. You register a URL, it probes that URL on a schedule, and it tells you when the URL stops answering. It is also the application that every piece of infrastructure in this repository exists to serve.

This is the Azure and Kubernetes counterpart to [LinkForge](../linkforge). Same method, different platform: one application, grown one milestone at a time, with the infrastructure design written in prose rather than accumulated as configuration.

## The product

Three endpoints and two background components.

| Endpoint | Behavior |
| --- | --- |
| `POST /monitors` | Accepts a URL and a probe interval, returns a monitor ID |
| `GET /monitors/{id}` | Returns current state, last check time, uptime percentage |
| `GET /monitors/{id}/checks` | Returns recent check results |

| Component | Kubernetes object | Behavior |
| --- | --- | --- |
| `api` | Deployment | The three endpoints above |
| `scheduler` | CronJob | Every minute, finds monitors that are due and enqueues them |
| `checker` | Deployment | Pulls from the queue, performs the HTTP probe, writes the result |

That is a few hundred lines of Python. It is boring on purpose. The application is never the subject of this project — the resource graph around it is.

## Why this product and not a to-do app

The shape of PulseGate is chosen so that Kubernetes is the honest answer rather than the fashionable one. Every primitive in the roadmap has a reason to exist here.

| The product needs | Which forces | Milestone |
| --- | --- | --- |
| Probes that fire on a fixed schedule | `CronJob` — a first-class Kubernetes object with no ECS equivalent | `v5-state` |
| Probe load that is spiky, not steady | KEDA on queue depth, cluster autoscaler, a Spot node pool | `v6-scale` |
| Checkers that may be evicted; an API that may not | Two node pools, taints and tolerations, PodDisruptionBudgets | `v6-scale` |
| Three components that version independently | Argo CD app-of-apps, sync waves | `v3-gitops` |
| A monitoring product that cannot be down during its own deploy | Argo Rollouts canary, analysis queried from Prometheus | `v8-progressive` |
| Check results as time series, then as retained history | PostgreSQL, then managed Prometheus, then a retention policy | `v5-state`, `v7-observable` |
| Outbound HTTP to arbitrary, user-supplied URLs | Controlled egress: NAT Gateway, egress NetworkPolicy, a dedicated egress path | `v1-network`, `v10-harden` |
| A public write endpoint that will be abused | Front Door WAF, rate limiting, request validation | `v9-edge` |

The seventh row is the one that makes this product interesting rather than merely convenient. A service whose entire job is to fetch URLs that strangers supply is a server-side request forgery engine by construction. It runs inside your virtual network, and the addresses it can reach include your own database, the Instance Metadata Service at `169.254.169.254`, and every private subnet you own. Egress control is not a checkbox at `v10-harden`; it is the product's core security problem, and the roadmap treats it that way.

## Why Kubernetes here, when LinkForge chose ECS

LinkForge rejected EKS on cost. The EKS control plane bills about $73 a month whether or not anything is running, which defeats a project built on destroying its infrastructure at the end of every session. That reasoning was correct, and it does not carry over.

AKS has a Free tier where the control plane costs nothing. There is no uptime SLA on that tier, which is the correct trade for a project that is torn down nightly and has no users. On top of that, `az aks stop` deallocates the node pool virtual machines and leaves the cluster object in place, so the daily shutdown is a single command instead of a full destroy and rebuild.

So the constraint that made Kubernetes the wrong answer on AWS does not exist on Azure. That is the entire premise of this repository, and it is worth stating plainly rather than leaving it as an unexamined preference.

Two other differences shape the design and are noted where they land:

- **Identity.** AWS gave LinkForge IAM roles for service accounts. Azure gives Entra Workload Identity, which federates a Kubernetes ServiceAccount token to a managed identity. Same idea, different failure modes, and it is free.
- **Secrets.** AWS charges a dollar per KMS key per month, which is why LinkForge tracks a minimum cost that only ever goes up. Azure Key Vault charges per operation and nothing for the vault, so the equivalent line in this project's cost model behaves differently.

## When the application gets written

`v2-cluster`. That is the first milestone with a registry and a cluster, and a registry with no image to store and a scheduler with no pods to run are not worth building. Before that, `v1-network` proves out private subnets and private access against a host that answers `/healthz` and nothing else.

The code then arrives in the order the infrastructure can support it.

| Milestone | The application | Deployed by |
| --- | --- | --- |
| `v1-network` | Nothing. A `/healthz` answer on a virtual machine | Not applicable |
| `v2-cluster` | `/healthz` plus a monitor list from an in-memory map | `docker build` on your machine, `kubectl apply` by hand |
| `v3-gitops` | Unchanged — what moves is who applies the manifests | Argo CD, from the `gitops/` path |
| `v4-pipeline` | Unchanged — what moves is who builds the image | GitHub Actions on merge, then Argo CD |
| `v5-state` | The three real endpoints, plus the scheduler and checker split | GitHub Actions, then Argo CD |
| `v6-scale` | The checker becomes horizontally elastic | GitHub Actions, then Argo CD |
| `v8-progressive` | A `/metrics` endpoint the canary analysis can query | GitHub Actions, then Argo Rollouts |

It stays a stub until `v5-state` for an honest reason: there is no store to write to, so `POST /monitors` cannot persist anything before then, and no queue to enqueue to, so the scheduler and checker have nothing to talk through.

The split at `v5-state` is the one change carrying real design weight. Up to that point PulseGate is one process. After it, the probe work leaves the request path entirely: the CronJob only enqueues, the checkers only consume, and the API only reads what they wrote. This is what makes the checker fleet independently scalable at `v6-scale`, and it is the whole reason the product is worth putting on Kubernetes.

Building more application than the infrastructure can currently serve is exactly the failure mode this ordering exists to prevent.

## About the application

The application is Python. The framework choice is deferred to `v2-cluster` and matters in five ways only:

- It must expose `/healthz` for the liveness probe and `/readyz` for the readiness probe, and these must be different routes. Readiness may check the database; liveness must not. A liveness probe that fails when PostgreSQL is slow will restart every healthy pod in the cluster at the worst possible moment.
- It must listen on the port the container spec declares.
- It must be async. The checker's entire job is waiting on remote HTTP; a synchronous worker blocks on every probe.
- It must run one process per container, so CPU stays a clean autoscaling signal.
- It must exit cleanly on `SIGTERM` and finish the in-flight probe first, because `v6-scale` puts checkers on Spot nodes that get thirty seconds of notice.

The container image is the real interface between the application and everything in this repository. Nothing downstream of the registry knows or cares what is inside it, which is also what makes a later change of language cheap.

## How this repository grows

PulseGate starts as one container on a cluster and ends as a multi-region, GitOps-reconciled, progressively-delivered, policy-governed platform. Each milestone adds only the infrastructure the application needs at that point. The shared foundations — state backend, identity federation, network, build, deploy path — are paid for once, in `v0-bootstrap`.

See [ROADMAP.md](ROADMAP.md) for the milestone list and current status, [COST.md](COST.md) for the cost model that governs what gets built, and [RUNBOOK.md](RUNBOOK.md) for the operations that have no Terraform resource.

## Repository layout

```
bootstrap/    Terraform, applied once. The state backend and nothing else.
platform/     Terraform. The Azure resources: network, cluster, data, edge.
gitops/       Kubernetes manifests. The only thing Argo CD reads.
apps/         Application source and Dockerfiles.
.github/      Workflows.
```

The seam between `platform/` and `gitops/` is deliberate and is defined at `v3-gitops`. Terraform stops at the cluster boundary. It creates the cluster, the registry, the databases, the identities, and the DNS records — and then it stops. Everything that lives *inside* the cluster is a manifest under `gitops/`, reconciled by Argo CD, and Terraform never applies it.

The one exception is Argo CD itself, which cannot install itself. That bootstrap problem, and the reasoning for how it is solved, belongs to `v3-gitops`.

`gitops/` sits in this repository rather than a second one. The canonical Argo CD guidance is to split application source from deployment configuration, and the reason is real: CI writing an image tag back into the same repository can retrigger CI. The single repository is chosen anyway, because the loop is cheap to break with a path filter and the split costs the project a coherent narrative. If the retrigger problem turns out to be worse than expected, `v4-pipeline` is where it will show, and the split is a cheap change at that point.

## What exists today

Nothing. `v0-bootstrap` has not started.

This repository currently holds its documentation and its `.gitignore`, in that order and on purpose. LinkForge's first lesson was that the ignore file must exist before the first `terraform apply`, not after, and that lesson transfers without modification.

`v0-bootstrap` is done when a pull request can plan against remote state in Azure Blob Storage using a federated credential that exists only for the life of the job, and no identity in the pipeline holds a client secret.

## About the infrastructure code

The design is described in prose: which resources, how they connect, and which arguments matter. It is not copy-paste HCL or YAML. The purpose is to build the mental model of the resource graph, not to accumulate configuration.
