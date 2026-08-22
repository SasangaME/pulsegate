# PulseGate — Milestone Roadmap

PulseGate begins as one container on a cluster and ends as a governed platform: GitOps reconciliation, progressive delivery, policy enforcement, a second region, and finally a landing zone built around the workload rather than under it. Thirteen milestones separate those two states, and each one adds only the infrastructure the application needs by then.

## One application, thirteen milestones

Any platform on Azure needs the same foundations before it does anything useful: a resource group layout, a state backend, the identities, a network, a build step, a deploy path. Thirteen unrelated exercises would mean building those six things thirteen times over, and most of the effort would go into scaffolding rather than into anything new.

Here they are paid for once, in `v0-bootstrap`. Every milestone after it adds only what is genuinely new, which is what makes it possible to cover this much of Azure and Kubernetes without spending the whole time on setup.

The corollary is that the milestones are cumulative, not interchangeable. `v8-progressive` assumes the metrics that `v7-observable` built; `v6-scale` assumes the queue from `v5-state`. The order is the design.

## What this document is

A design in words. It names the resources for each milestone, says how they connect, and calls out the arguments that matter and why — but it does not contain the HCL or the YAML. The goal is to be able to draw the resource graph from memory, not to accumulate configuration.

The application inside the container is simple and is not the subject. It is Python; the rest of its constraints are in [README.md](README.md).

## The boundary: Terraform outside, Argo CD inside

Two tools build this platform, and the cluster wall separates them.

| Side | Tool | What it owns |
| --- | --- | --- |
| Outside the cluster | Terraform | Resource groups, network, AKS, registry, database, queue, vault, DNS, identities |
| Inside the cluster | Argo CD | Deployments, Services, CronJobs, Ingress, HPAs, ScaledObjects, Rollouts |

That boundary is not crossed. Terraform's Kubernetes and Helm providers both work, and both make the cluster a dependency of the Terraform state — after which a broken cluster is also a broken plan. `v3-gitops` establishes the boundary and handles the single unavoidable exception, which is Argo CD itself.

## When the application arrives

`v2-cluster` is the first milestone with a registry and a cluster, so it is the first milestone where an application is worth writing. `v1-network` needs none: the host there answers `/healthz` and exists only to prove the private subnets and the private access path work.

After that the application grows alongside the infrastructure that carries it.

| Milestone | What the application does | Who builds the image | Who deploys it |
| --- | --- | --- | --- |
| `v1-network` | Nothing. A `/healthz` answer only | Not applicable | Not applicable |
| `v2-cluster` | `/healthz`, and a monitor list from a map in memory | You, with `docker build` and `docker push` | You, with `kubectl apply` |
| `v3-gitops` | No change | You | Argo CD |
| `v4-pipeline` | No change | GitHub Actions, on each merge | Argo CD |
| `v5-state` | The three real endpoints, with PostgreSQL and a queue | GitHub Actions | Argo CD |
| `v6-scale` | No change in behavior. The checker becomes elastic | GitHub Actions | Argo CD |
| `v8-progressive` | A `/metrics` route for the canary analysis | GitHub Actions | Argo Rollouts |

It stays a stub until `v5-state` because there is nothing for it to be otherwise: no database, so `POST /monitors` cannot persist a monitor; no queue, so the scheduler and the checker have no way to reach each other.

`v5-state` is the split that matters. One process becomes three — an API that only reads, a CronJob that only enqueues, a checker that only probes — and the probe work leaves the request path for good. That is what allows the checker to scale on its own in `v6-scale`.

Everything downstream of the registry deals with an image and nothing else — no resource past that point knows or cares what the image contains, which is what would keep a later change of language cheap.

## Three scale controls

Kubernetes gives three ways to add capacity, and they answer to different signals. All three arrive in `v6-scale`.

| Control | Object | Scales | Signal |
| --- | --- | --- | --- |
| Pod scale, CPU | `HorizontalPodAutoscaler` | The `api` pods | CPU, then requests per second |
| Pod scale, events | KEDA `ScaledObject` | The `checker` pods | Queue depth in Service Bus |
| Node scale | Cluster autoscaler | The nodes under both | Pods that cannot be placed |

The `api` scales on CPU because its load is request-driven and roughly continuous. The `checker` cannot, and this is the point worth keeping: a checker spends its life waiting on a remote server, so its CPU sits near zero even when it is completely saturated. Queue depth is the signal that describes its real backlog, and reading queue depth is what KEDA exists to do.

The cluster autoscaler sits beneath both and adds nodes when pods will not fit. It replaces neither pod-level control.

The application does not change for any of this. It only has to be stateless — which it is not in `v2-cluster`, where monitors live in memory and the pods are therefore not interchangeable. `v5-state` moves them to PostgreSQL and the problem goes away.

## Milestones

| Tag | Milestone | New resources |
| --- | --- | --- |
| `v0-bootstrap` | Basic subscription setup | State backend in Blob Storage, GitHub OIDC federation, budget, tag policy |
| `v1-network` | A network and a host that you can reach | VNet, subnets, NSGs, NAT Gateway, private access, Private DNS zones |
| `v2-cluster` | A cluster and a container on it | AKS Free tier, node pools, ACR, Workload Identity, ingress. The application is written here |
| `v3-gitops` | Declarative deployment | Argo CD, app-of-apps, sync waves, self-heal, drift detection |
| `v4-pipeline` | Automatic release to the cluster | GitHub Actions with OIDC, digest pinning, image scan, SBOM, IaC scan |
| `v5-state` | Permanent data and asynchronous work | PostgreSQL Flexible Server, Service Bus, Key Vault, Blob Storage, CronJob |
| `v6-scale` | Elastic capacity | KEDA, HPA, cluster autoscaler, Spot node pool, taints, PDBs, topology spread |
| `v7-observable` | Monitoring and alerts | Managed Prometheus, Managed Grafana, Container Insights, alert rules, OpenTelemetry |
| `v8-progressive` | Safe release | Argo Rollouts, canary steps, analysis templates, automatic rollback |
| `v9-edge` | Public access at the edge | Front Door, WAF, Azure DNS, cert-manager, private origin |
| `v10-harden` | Policy and least privilege | NetworkPolicy, Pod Security Admission, Azure Policy for AKS, Defender, private cluster, image signing |
| `v11-resilient` | Disaster recovery and review | Availability zones, Azure Backup for AKS, a second region, Well-Architected review |
| `v12-govern` | The landing zone around the workload | Management group hierarchy, ALZ policy initiatives at MG scope, hub VNet, Azure Firewall egress |

## What each milestone builds

### `v0-bootstrap` — the subscription foundation

A Storage Account with a container for Terraform state, versioned so a bad apply is recoverable, encrypted, with public network access closed and shared key access disabled so that every read goes through Entra ID. Locking is the blob lease, which the `azurerm` backend takes natively. There is no separate lock table to build, and there never was one on Azure.

This module runs on local state, because the backend it would otherwise use is the thing it is creating. The state moves into the container afterward. This happens exactly once in the life of the repository.

Then the shared foundation: an Entra application with federated credentials for GitHub, so that nothing in this repository holds a client secret. Two identities, not one — a plan identity with `Reader` plus state access, and an apply identity whose role assignments grow with each milestone. A consumption budget with an action group, because a project that stands infrastructure up daily should say so when it costs more than expected. An Azure Policy assignment that inherits tags from the resource group, because Azure tags do not propagate on their own. And a workflow that runs `fmt`, `validate`, and `plan` on every pull request.

### `v1-network` — the network and controlled egress

A virtual network with separate subnets for the cluster nodes, the ingress, the database, and the private endpoints. Network security groups on each. A NAT Gateway for outbound traffic, which gives the cluster a fixed, known egress address — this matters more here than in most projects, because PulseGate's whole job is making outbound requests to strangers' servers, and a stable source address is what makes that traffic attributable.

Private DNS zones for the private endpoints that later milestones attach. Then a small virtual machine with no public IP, answering `/healthz`, reached by `az ssh` and `run-command` rather than a jump box. This exists to prove the private path works before anything expensive depends on it. Azure Bastion is the obvious answer and is deliberately not used; the reason is in [COST.md](COST.md).

### `v2-cluster` — the cluster

AKS on the Free tier, with the API server reachable but the nodes private. Azure CNI Overlay, powered by Cilium — Overlay because it does not consume a VNet address for every pod, and Cilium because `v10-harden` needs NetworkPolicy and choosing the data plane later means rebuilding the cluster.

Two node pools from the start: a system pool that runs only system workloads, tainted `CriticalAddonsOnly`, and a user pool that runs PulseGate. One pool is simpler and is the wrong choice, because `v6-scale` adds a third Spot pool and a cluster that has never had pool affinity expressed will not gain it cleanly.

An Azure Container Registry on the Basic tier, attached to the cluster so that image pulls use the kubelet identity and not a pull secret. Entra Workload Identity enabled on the cluster, with the OIDC issuer turned on — nothing uses it yet, and turning it on later is a cluster update you do not want to schedule.

The managed NGINX ingress controller, through the application routing add-on. The application is written in this milestone and deployed by hand with `kubectl apply`, exactly once, so that the next milestone has something to take away.

### `v3-gitops` — Argo CD and the boundary

Argo CD installed in the cluster, and then the manifests that Argo CD reconciles moved into `gitops/`. From this milestone on, `kubectl apply` against this cluster is a mistake, not a workflow.

The bootstrap problem is the interesting part. Argo CD cannot install itself. The options are a one-time `helm install` recorded in the runbook, or a Terraform Helm release that crosses the boundary this project just declared. The choice is the first: install once by hand, then commit an Argo CD Application that points at Argo CD's own manifests, so that from the second reconcile onward Argo CD manages its own upgrades. The hand-install is recorded in [RUNBOOK.md](RUNBOOK.md) with a check.

The app-of-apps pattern: one root Application in the repository, pointing at a directory of child Applications, one per PulseGate component. Sync waves order them. Automated sync with prune and self-heal, because a GitOps setup that does not correct drift is a deployment tool with extra steps.

### `v4-pipeline` — the build

A GitHub Actions workflow that builds the image, scans it, pushes it to ACR, and then writes the new image **digest** into the `gitops/` path. Digest, not tag: a tag is a mutable pointer and a GitOps repository that references one is not actually declarative.

The push authenticates with the federated credential from `v0-bootstrap`. A path filter stops the commit to `gitops/` from retriggering the build. Trivy scans the image, Checkov or `tfsec` scans the Terraform, and the build emits an SBOM. Argo CD notices the commit and syncs.

This is where the single-repository decision gets tested. If the retrigger loop is worse than a path filter can handle, this is the milestone where `gitops/` becomes a second repository.

### `v5-state` — data and the split

Azure Database for PostgreSQL Flexible Server, Burstable tier, on a private endpoint in its own subnet, reachable only from the cluster. Azure Service Bus for the probe queue. Azure Key Vault for the connection strings, read through the Secrets Store CSI driver using the workload identity from `v2-cluster` — no secret is ever written into a Kubernetes `Secret` by a human, and no connection string appears in the GitOps repository. Blob Storage for check-result archives.

The application becomes real here, and it becomes three things. The `scheduler` CronJob runs every minute, queries for monitors that are due, and enqueues them. The `checker` Deployment consumes the queue and performs the probes at a fixed replica count. The `api` serves the three endpoints and reads what the checkers wrote.

The CronJob needs `concurrencyPolicy: Forbid` and a `startingDeadlineSeconds`, or a slow minute produces overlapping waves that enqueue the same monitors twice.

### `v6-scale` — elastic capacity

The KEDA add-on, with a `ScaledObject` that scales the checker on Service Bus queue depth, from zero. Scaling to zero is the point: between probe waves there is genuinely no work, and a fleet that idles at zero is a fleet that costs nothing.

An HPA on the `api`, on CPU. A third node pool on Spot, tainted, for the checkers only, with tolerations that keep the API off it. The cluster autoscaler on the user and Spot pools. PodDisruptionBudgets so that a node drain cannot take the whole API down. Topology spread constraints across availability zones. Resource requests and limits on everything, because the scheduler and the autoscaler are both blind without them.

Spot capacity is what makes the checker fleet nearly free, and it is also why the application had to handle `SIGTERM` correctly two milestones ago.

### `v7-observable` — monitoring the monitor

Azure Monitor managed Prometheus scraping the cluster and the application. Azure Managed Grafana for the dashboards. Container Insights for the container logs, with a Basic Logs tier and a retention policy set at creation, because log ingestion is the cost that grows silently.

Alert rules on the things that matter: the checker queue growing without bound, the CronJob missing a wave, pod restart loops, and the node pool at capacity. An action group to deliver them. OpenTelemetry instrumentation in the application, exported to Application Insights, so that a slow endpoint has a trace and not just a number.

There is a pleasing recursion here that is also a real risk: PulseGate monitors uptime, and this milestone monitors PulseGate. Nothing in this project monitors the monitor's monitor, and that is a correct place to stop.

### `v8-progressive` — releasing without an outage

Argo Rollouts, replacing the `api` Deployment with a `Rollout`. Canary steps that shift a percentage of traffic at a time, with an `AnalysisTemplate` that queries the Prometheus from `v7-observable` for error rate and latency, and aborts the rollout automatically when either crosses a threshold.

Traffic splitting needs a router. The NGINX ingress canary annotations are the smaller change and the one to take; the Istio add-on is the more capable answer and the larger commitment, and it is written down here as considered rather than chosen.

This milestone is ordered after `v7-observable` for a reason that is easy to get backwards: an automated canary analysis is only as trustworthy as the metrics it queries. Building the rollback mechanism before the metrics exist produces a rollback that fires on noise.

### `v9-edge` — the public edge

Azure Front Door Standard in front of the ingress, with the WAF policy in prevention mode, rate limiting on `POST /monitors`, and the origin locked so that it accepts traffic from Front Door only. An Azure DNS zone and a real domain. Certificates from cert-manager through the ACME HTTP-01 challenge, or Front Door managed certificates — the trade is written out in this milestone.

`POST /monitors` is a public, unauthenticated write endpoint that causes the platform to make an outbound request to an address the caller chose. Rate limiting it is not hardening, it is a functional requirement.

### `v10-harden` — policy and least privilege

Default-deny NetworkPolicy, then explicit allows. This is where the SSRF problem from the README is finally addressed properly: the checker pods get an egress policy that permits the internet and denies every RFC 1918 range, the link-local address `169.254.169.254`, and the cluster's own service CIDR. The checker must be able to reach any public URL and no private one, and that is not the default in any Kubernetes network.

Pod Security Admission in `restricted` mode. Azure Policy for AKS, through the Gatekeeper add-on, enforcing the constraints that PSA does not cover. Microsoft Defender for Containers. Converting the API server to VNet integration so the control plane is private. Image signing with Notation, and an admission policy that refuses unsigned images — which closes the loop back to `v4-pipeline`, where the signature is produced.

Cost governance also lands here: a review of what the tags actually captured, and a second budget scoped to the platform resource group.

### `v11-resilient` — failure and review

Availability zones across the node pools and zone-redundant PostgreSQL. Azure Backup for AKS, covering the cluster state and the persistent volumes. A second region holding a warm registry replica and a database read replica, with Front Door failing over between origins.

Then a deliberate failure exercise: delete a node pool, restore from backup, and record how long it took. A Well-Architected review of the whole platform against the five pillars, with the findings written down even where they will not be fixed.

### `v12-govern` — the landing zone around it

Everything up to here builds a workload. This milestone builds the platform that a workload is supposed to sit inside, and then moves PulseGate into it. The reference design is the Cloud Adoption Framework's enterprise-scale architecture — Azure Landing Zones — and the useful discovery is that it splits cleanly along the cost line this project already draws.

**The governance half, which is free and permanent.** A management group hierarchy under the tenant root: Platform, Landing Zones, Sandbox, Decommissioned. The PulseGate subscription moves under Landing Zones. Management groups cost nothing, there are ten thousand of them available, and they are not the expensive part of a landing zone — the connectivity subscription is.

Policy assignments then move to management group scope, which is where the tag-inheritance assignment from `v0-bootstrap` would have lived if there had been a hierarchy to hang it on. The ALZ policy initiatives are assigned with `enforcementMode` set to `DoNotEnforce` on the first pass, so that the compliance dashboard reports what *would* happen before anything is denied or created. Moving individual policies to enforced is then a deliberate act, one at a time, with the compliance report as evidence.

That ordering is not caution for its own sake. A large share of the ALZ initiative is `deployIfNotExists` and `modify` policies, and a remediation task run against the shipped defaults will enable paid Defender for Cloud plans across the subscription, deploy a Log Analytics workspace, and wire diagnostic settings from every resource into it. Every one of those is a remaining cost in the sense of [COST.md](COST.md): it starts quietly and no destroy removes it. The parameters that control them are set before the first assignment, not discovered on the next invoice.

**The connectivity half, which is hourly and disposable.** A hub virtual network peered to the PulseGate spoke, a route table on the checker subnet forcing `0.0.0.0/0` to the hub, and Azure Firewall as the single egress point. Application rules allow outbound HTTP and HTTPS to the public internet; network rules deny every RFC 1918 range and the link-local address.

That is the same policy `v10-harden` already wrote as a Kubernetes NetworkPolicy, enforced a second time somewhere the cluster does not control. A pod that escapes the CNI's policy engine still has to get past the firewall. For a product whose defining risk is fetching URLs that strangers chose, two independent enforcement points are worth having — and comparing them is the exercise: one is reconciled by Argo CD inside the cluster boundary, the other is Terraform outside it, and the boundary rule from `v3-gitops` still decides which is which.

The firewall is billed by the hour and is destroyed with the rest of the stack. The management groups and the policy assignments are free and stay.

**What this milestone deliberately does not build.** Subscription vending — the ALZ pattern where Terraform creates a subscription per workload — needs an MCA billing account or an EA enrolment. A personal pay-as-you-go subscription cannot create subscriptions programmatically, so that half of the pattern is read rather than run; what can be practised is the placement side, moving an existing subscription between management groups and applying the policy and RBAC that come with the position. And DDoS Network Protection stays off: it is billed monthly per tenant with no proration worth the name, which makes it the one part of a landing zone that cannot be practised cheaply.


## Status

| Tag | Status |
| --- | --- |
| `v0-bootstrap` | Not started |
| `v1-network` | Not started |
| `v2-cluster` | Not started |
| `v3-gitops` | Not started |
| `v4-pipeline` | Not started |
| `v5-state` | Not started |
| `v6-scale` | Not started |
| `v7-observable` | Not started |
| `v8-progressive` | Not started |
| `v9-edge` | Not started |
| `v10-harden` | Not started |
| `v11-resilient` | Not started |
| `v12-govern` | Not started |

That table only moves when a milestone ends, so it says nothing useful while one is underway. The table below carries the detail for the milestone in progress.

### Inside `v0-bootstrap`

| Step | Work | Status |
| --- | --- | --- |
| 1 | Repository safety rails: the `.gitignore`, in place before anything is applied | Done |
| 2 | The `bootstrap` module. The Storage Account and state container, applied with local state | Not started |
| 3 | The `backend` block, and the move of the state into the container | Not started |
| 4 | The Entra application, with federated credentials for GitHub, a plan identity and an apply identity | Not started |
| 5 | The budget. A consumption budget, an action group, and an email receiver | Not started |
| 6 | The subscription baseline. The tag inheritance policy, the resource group layout, the diagnostic defaults | Not started |
| 7 | The first workflow. `fmt`, `validate`, and `plan` on each pull request | Not started |

Steps 1 to 3 produce a state backend that stores its own state, which is what every later milestone builds on.

Steps 4 and 7 are one test in two halves: step 4 creates the identities, step 7 proves they work. `v0-bootstrap` is complete when a pull request runs a plan that reads state from Blob Storage using a federated credential, and no identity in the pipeline holds a client secret.

Three operations in this milestone are not Terraform code. They live in [RUNBOOK.md](RUNBOOK.md), and one of them is a prerequisite rather than a follow-up: the Entra directory permissions must exist before step 4 can run at all.

## Open decisions

Recorded here because deciding them silently later is how a project acquires configuration it cannot explain.

| Decision | Due at | Note |
| --- | --- | --- |
| Region | `v0-bootstrap` | Weigh availability-zone support and price against latency, which barely matters here |
| Python framework | `v2-cluster` | Must be async. See the constraints in [README.md](README.md) |
| Helm charts or plain manifests under `gitops/` | `v3-gitops` | Kustomize is the third option and the one that argues best with a digest-writing pipeline |
| NGINX canary annotations or the Istio add-on | `v8-progressive` | Traffic splitting for Argo Rollouts |
| cert-manager or Front Door managed certificates | `v9-edge` | Two valid answers with different failure modes |
| Whether `gitops/` becomes a second repository | `v4-pipeline` | Decided by whether the path filter holds |
| Azure Firewall Basic or Standard | `v12-govern` | Basic is roughly a third of the hourly rate and has no DNS proxy, which FQDN-based egress rules need |
| Whether the tag policy moves to management group scope | `v12-govern` | It belongs there; the question is whether re-pointing it is worth a re-remediation |
