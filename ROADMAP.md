# PulseGate — Milestone Roadmap

Thirteen milestones, from one container on a cluster to a governed platform with GitOps, progressive delivery, policy enforcement, a second region, and a landing zone around it.

Each milestone adds only the infrastructure the application needs by then, and they are cumulative: `v6-scale` assumes the queue from `v5-state`, `v8-progressive` assumes the metrics from `v7-observable`. One application rather than thirteen exercises, so the resource groups, state backend, identities, network, build and deploy path get paid for once in `v0-bootstrap`.

This is a design in words — the resources, how they connect, and the arguments that matter. No HCL, no YAML. The application is Python and is not the subject; its constraints are in [README.md](README.md).

## The boundary: Terraform outside, Argo CD inside

| Side | Tool | Owns |
| --- | --- | --- |
| Outside the cluster | Terraform | Resource groups, network, AKS, registry, database, queue, vault, DNS, identities |
| Inside the cluster | Argo CD | Deployments, Services, CronJobs, Ingress, HPAs, ScaledObjects, Rollouts |

The boundary is not crossed. Terraform's Kubernetes and Helm providers work, but both make the cluster a dependency of the state file — after which a broken cluster is also a broken plan. `v3-gitops` sets the boundary and handles the one exception, Argo CD itself.

## Milestones

| Tag | Milestone | New resources |
| --- | --- | --- |
| `v0-bootstrap` | Subscription foundation | State backend in Blob Storage, GitHub OIDC federation, budget, tag policy |
| `v1-network` | A network and a host you can reach | VNet, subnets, NSGs, NAT Gateway, private access, Private DNS zones |
| `v2-cluster` | A cluster and a container on it | AKS Free tier, node pools, ACR, Workload Identity, ingress. The application is written here |
| `v3-gitops` | Declarative deployment | Argo CD, app-of-apps, sync waves, self-heal, drift detection |
| `v4-pipeline` | Automatic release | GitHub Actions with OIDC, digest pinning, image scan, SBOM, IaC scan |
| `v5-state` | Permanent data and async work | PostgreSQL Flexible Server, Service Bus, Key Vault, Blob Storage, CronJob |
| `v6-scale` | Elastic capacity | KEDA, HPA, cluster autoscaler, Spot node pool, taints, PDBs, topology spread |
| `v7-observable` | Monitoring and alerts | Managed Prometheus, Grafana, Container Insights, alert rules, OpenTelemetry |
| `v8-progressive` | Safe release | Argo Rollouts, canary steps, analysis templates, automatic rollback |
| `v9-edge` | Public access at the edge | Front Door, WAF, Azure DNS, cert-manager, private origin |
| `v10-harden` | Policy and least privilege | NetworkPolicy, Pod Security Admission, Azure Policy for AKS, Defender, private cluster, image signing |
| `v11-resilient` | Disaster recovery and review | Availability zones, Azure Backup for AKS, a second region, Well-Architected review |
| `v12-govern` | The landing zone around the workload | Management group hierarchy, ALZ initiatives at MG scope, hub VNet, Azure Firewall egress |

The application is a stub until `v5-state` — no database to persist a monitor to, no queue for the scheduler and checker to talk through. The table of what it does per milestone is in [README.md](README.md).

## What each milestone builds

### `v0-bootstrap` — the subscription foundation

- **Storage Account and state container** — versioned, encrypted, public network access closed, shared key access disabled so every read goes through Entra ID. Locking is the blob lease, which the `azurerm` backend takes natively; there is no lock table on Azure.
- **An Entra application** with federated credentials for GitHub. Two identities: a **plan** identity with `Reader` plus state access, and an **apply** identity whose role assignments grow each milestone.
- **A consumption budget**, action group and email receiver.
- **An Azure Policy assignment** inheriting tags from the resource group, because Azure tags do not propagate on their own.
- **A workflow** running `fmt`, `validate` and `plan` on every pull request.

The state module runs on local state — the backend it would use is the thing it creates — then the state moves into the container. That happens once in the life of the repository.

Three operations here are not Terraform and live in [RUNBOOK.md](RUNBOOK.md). One is a prerequisite: the Entra directory permissions must exist before the identities can be created.

### `v1-network` — the network and controlled egress

- A **VNet** with separate subnets for cluster nodes, ingress, the database and private endpoints, an **NSG** on each, and **Private DNS zones** for the endpoints later milestones attach.
- A **NAT Gateway** for outbound traffic. PulseGate's job is making requests to strangers' servers, and a fixed, known egress address is what makes that traffic attributable.
- A **small VM**, no public IP, answering `/healthz`, reached by `az ssh` and `run-command`. It proves the private path works before anything expensive depends on it. Azure Bastion is the obvious answer and is refused in [COST.md](COST.md).

### `v2-cluster` — the cluster

AKS on the Free tier, API server reachable, nodes private.

- **Azure CNI Overlay, powered by Cilium** — Overlay so pods do not consume a VNet address each, Cilium because `v10-harden` needs NetworkPolicy and changing the data plane later means rebuilding the cluster.
- **Two node pools from the start** — a system pool tainted `CriticalAddonsOnly`, and a user pool. One pool is simpler and wrong: `v6-scale` adds a third on Spot, and a cluster that has never expressed pool affinity will not gain it cleanly.
- **ACR Basic**, attached to the cluster so pulls use the kubelet identity rather than a pull secret.
- **Entra Workload Identity** with the OIDC issuer on. Nothing uses it yet; enabling it later is a cluster update you would rather not schedule.
- **Managed NGINX ingress**, through the application routing add-on.

The application is written here and applied by hand with `kubectl` exactly once, so the next milestone has something to take away.

### `v3-gitops` — Argo CD and the boundary

Argo CD in the cluster, manifests moved to `gitops/`, and from here on `kubectl apply` against this cluster is drift rather than a workflow.

Argo CD cannot install itself, so the bootstrap either breaks the boundary in Terraform or breaks it once by hand. It is the second: install from the chart once, then commit an `Application` pointing at Argo CD's own manifests so it manages its own upgrades from the next reconcile. Operation 4 in [RUNBOOK.md](RUNBOOK.md), with a check.

Then app-of-apps — one root Application over a directory of child Applications, one per component, ordered by sync waves, with automated sync, prune and self-heal. GitOps that does not correct drift is a deployment tool with extra steps.

### `v4-pipeline` — the build

A GitHub Actions workflow that builds the image, scans it with Trivy, pushes to ACR and writes the new image **digest** into `gitops/`. Digest, not tag: a tag is a mutable pointer, and a GitOps repository that references one is not declarative. Checkov or `tfsec` scans the Terraform, the build emits an SBOM, and authentication is the federated credential from `v0-bootstrap`.

A path filter stops the commit to `gitops/` retriggering the build. This is where the single-repository decision gets tested — if the loop outgrows the filter, this is where `gitops/` becomes a second repository.

### `v5-state` — data and the split

- **PostgreSQL Flexible Server**, Burstable tier, private endpoint in its own subnet, reachable only from the cluster.
- **Service Bus** for the probe queue.
- **Key Vault** for connection strings, read through the Secrets Store CSI driver using the workload identity from `v2-cluster`. No secret is written into a Kubernetes `Secret` by hand, and no connection string reaches the GitOps repository.
- **Blob Storage** for check-result archives.

The application becomes three things — a `scheduler` CronJob that enqueues due monitors every minute, a `checker` Deployment that consumes the queue and probes, and an `api` that reads what the checkers wrote. The probe work leaves the request path for good, which is what lets the checker scale on its own next.

The CronJob needs `concurrencyPolicy: Forbid` and a `startingDeadlineSeconds`, or a slow minute produces overlapping waves that enqueue the same monitors twice.

### `v6-scale` — elastic capacity

Three scale controls, on three different signals:

| Control | Object | Scales | Signal |
| --- | --- | --- | --- |
| Pod scale, CPU | `HorizontalPodAutoscaler` | `api` pods | CPU, then requests per second |
| Pod scale, events | KEDA `ScaledObject` | `checker` pods | Service Bus queue depth |
| Node scale | Cluster autoscaler | Nodes under both | Pods that cannot be placed |

The `api` scales on CPU because its load is request-driven. The `checker` cannot: it spends its life waiting on a remote server, so its CPU sits near zero even when saturated. Queue depth describes its real backlog, and the `ScaledObject` scales from zero — between waves there is genuinely no work.

Also: a **Spot node pool**, tainted, for checkers only, with tolerations keeping the API off it. Cluster autoscaler on the user and Spot pools. **PodDisruptionBudgets** so a node drain cannot take the whole API down, **topology spread** across zones, and requests and limits on everything, because the scheduler and the autoscaler are both blind without them.

Spot is what makes the checker fleet nearly free, and it is why the application had to handle `SIGTERM` correctly a milestone ago.

### `v7-observable` — monitoring the monitor

- **Azure Monitor managed Prometheus** scraping the cluster and the application, with **Grafana self-hosted** in the cluster and reconciled by Argo CD. Azure Managed Grafana is refused on cost in [COST.md](COST.md).
- **Container Insights** on the Basic Logs tier, with retention set *at creation* — log ingestion is the cost that grows silently.
- **Alert rules** on the checker queue growing without bound, the CronJob missing a wave, pod restart loops, and the node pool at capacity, with an action group to deliver them.
- **OpenTelemetry** in the application, exported to Application Insights, so a slow endpoint has a trace and not just a number.

### `v8-progressive` — releasing without an outage

Argo Rollouts replaces the `api` Deployment with a `Rollout`. Canary steps shift traffic a percentage at a time, and an `AnalysisTemplate` queries the Prometheus from `v7-observable` for error rate and latency, aborting automatically when either crosses a threshold.

Traffic splitting needs a router: NGINX canary annotations are the smaller change and the one to take, with the Istio add-on recorded as considered.

Ordered after `v7-observable` for a reason that is easy to get backwards — an automated canary is only as trustworthy as the metrics it queries. Build the rollback before the metrics and it fires on noise.

### `v9-edge` — the public edge

Azure Front Door Standard in front of the ingress, WAF in prevention mode, rate limiting on `POST /monitors`, and the origin locked to Front Door traffic only. An Azure DNS zone and a real domain, with certificates from either cert-manager over ACME HTTP-01 or Front Door's managed certificates.

`POST /monitors` is a public, unauthenticated write that makes the platform fetch an address the caller chose. Rate limiting it is a functional requirement, not hardening.

### `v10-harden` — policy and least privilege

Default-deny NetworkPolicy, then explicit allows. This is where the SSRF problem from the README is finally addressed: the checker pods get an egress policy permitting the internet and denying every RFC 1918 range, the link-local address `169.254.169.254`, and the cluster's own service CIDR. A pod that can reach any public URL and no private one is not what any Kubernetes network gives you by default.

Then **Pod Security Admission** in `restricted` mode, **Azure Policy for AKS** through Gatekeeper for what PSA does not cover, **Defender for Containers**, and the API server on **VNet integration** so the control plane is private. **Image signing** with Notation plus an admission policy refusing unsigned images, closing the loop back to `v4-pipeline` where the signature is produced.

Cost governance lands here too: a review of what the tags actually captured, and a second budget scoped to the platform resource group.

### `v11-resilient` — failure and review

Availability zones across the node pools and zone-redundant PostgreSQL. Azure Backup for AKS over cluster state and persistent volumes. A second region holding a warm registry replica and a database read replica, with Front Door failing over between origins.

Then a deliberate failure exercise — delete a node pool, restore from backup, record how long it took — and a Well-Architected review against the five pillars, with the findings written down even where they will not be fixed.

### `v12-govern` — the landing zone around it

Everything up to here builds a workload; this builds the platform a workload is supposed to sit inside, then moves PulseGate into it. The reference is the Cloud Adoption Framework's enterprise-scale architecture, and it splits along the same cost line this project already draws.

**The governance half is free and permanent.** A management group hierarchy under the tenant root — Platform, Landing Zones, Sandbox, Decommissioned — with the subscription under Landing Zones, and the policy assignments moved to MG scope, where the tag-inheritance assignment from `v0-bootstrap` would have lived if there had been a hierarchy to hang it on.

The ALZ initiatives are assigned with `enforcementMode` set to `DoNotEnforce` first, so the compliance dashboard reports what *would* happen before anything is denied or created; enforcing is then deliberate, one policy at a time. That ordering matters because much of the initiative is `deployIfNotExists` and `modify`, and a remediation run against the shipped defaults will enable paid Defender for Cloud plans, deploy a Log Analytics workspace, and wire diagnostic settings from every resource into it. Each is a remaining cost in the sense of [COST.md](COST.md) — it starts quietly and no destroy removes it.

**The connectivity half is hourly and disposable.** A hub VNet peered to the spoke, a route table forcing `0.0.0.0/0` from the checker subnet to the hub, and Azure Firewall as the single egress point — application rules allowing outbound HTTP and HTTPS, network rules denying RFC 1918 and the link-local address.

That is the same policy `v10-harden` wrote as a NetworkPolicy, enforced again somewhere the cluster does not control. A pod that escapes the CNI's policy engine still has to get past the firewall, and for a product whose defining risk is fetching URLs strangers chose, two independent enforcement points are worth having. Comparing them is the exercise.

**Not built.** Subscription vending needs an MCA or EA billing account, which a personal pay-as-you-go subscription does not have, so that half is read rather than run and only the placement side gets practised. DDoS Network Protection stays off — billed monthly per tenant with no proration worth the name, it is the one part of a landing zone that cannot be practised cheaply.

## Status

| Tag | Status |
| --- | --- |
| `v0-bootstrap` | **In progress** |
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

### Inside `v0-bootstrap`

| Step | Work | Status |
| --- | --- | --- |
| 1 | Repository safety rails: the `.gitignore`, before anything is applied | Done |
| 2 | The `bootstrap` module. Storage Account and state container, on local state | Not started |
| 3 | The `backend` block, and the move of the state into the container | Not started |
| 4 | The Entra application, federated credentials for GitHub, plan and apply identities | Not started |
| 5 | The budget. A consumption budget, an action group, an email receiver | Not started |
| 6 | The subscription baseline. Tag inheritance policy, resource group layout, diagnostic defaults | Not started |
| 7 | The first workflow. `fmt`, `validate` and `plan` on each pull request | Not started |

Steps 1 to 3 produce a state backend that stores its own state. Steps 4 and 7 are one test in two halves: step 4 creates the identities, step 7 proves they work.

`v0-bootstrap` is complete when a pull request runs a plan that reads state from Blob Storage using a federated credential, and no identity in the pipeline holds a client secret.

## Decisions taken

### Region: `westus3`

Priced against the Azure Retail Prices API on the basket this project actually runs.

**NAT Gateway and Standard Load Balancer are billed at one global rate**, with no region attached — and they are the whole of `v1-network`, so for the first two milestones the region is not a cost decision at all.

On everything that does vary, five regions tie at the cheapest price: `eastus`, `eastus2`, `westus2`, `westus3`, `northcentralus`. The next cheapest anywhere is about 6% above them, and `southeastasia` — the one geography would argue for — is 28% above on compute, which latency does not buy back for this workload. `northcentralus` is out on one availability zone, since `v6-scale` spreads across zones and `v11-resilient` wants zone-redundant PostgreSQL.

That leaves Spot as the tiebreak, which is the right one, because `v6-scale` puts the whole checker fleet on it: `westus3` at $0.0178 an hour, then `eastus` at $0.0203, `westus2` at $0.0210, and `eastus2` at $0.0382.

`D2s_v5` is the comparison SKU rather than necessarily the deployed one — this subscription has no quota for that family, which is recorded in [COST.md](COST.md). Spot rates move; a re-read before `v6-scale` is cheap.

## Open decisions

Recorded here because deciding them silently later is how a project acquires configuration it cannot explain.

| Decision | Due at | Note |
| --- | --- | --- |
| Python framework | `v2-cluster` | Must be async. See the constraints in [README.md](README.md) |
| Helm charts or plain manifests under `gitops/` | `v3-gitops` | Kustomize is the third option and the one that argues best with a digest-writing pipeline |
| NGINX canary annotations or the Istio add-on | `v8-progressive` | Traffic splitting for Argo Rollouts |
| cert-manager or Front Door managed certificates | `v9-edge` | Two valid answers with different failure modes |
| Whether `gitops/` becomes a second repository | `v4-pipeline` | Decided by whether the path filter holds |
| Azure Firewall Basic or Standard | `v12-govern` | Basic is roughly a third of the hourly rate and has no DNS proxy, which FQDN-based egress rules need |
| Whether the tag policy moves to management group scope | `v12-govern` | It belongs there; the question is whether re-pointing it is worth a re-remediation |
