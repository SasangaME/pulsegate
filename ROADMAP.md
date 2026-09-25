# PulseGate — Milestone Roadmap

Thirteen milestones, from one container on a cluster to a governed platform with GitOps, progressive delivery, policy enforcement, a second region, and a landing zone around it.

Each milestone adds only the infrastructure the application needs by then, and they are cumulative: `v6-scale` assumes the queue from `v5-state`, `v8-progressive` assumes the metrics from `v7-observable`. One application rather than thirteen exercises, so the resource groups, state backend, identities, network, build and deploy path get paid for once in `v0-bootstrap`.

This is a design in words — the resources, how they connect, and the arguments that matter. No HCL, no YAML. The application is Python and is not the subject; its constraints are in [README.md](README.md).

## The boundary: Terraform outside, Argo CD inside

| Side | Tool | Owns |
| --- | --- | --- |
| Outside the cluster | Terraform | Resource groups, network, AKS, database, queue, vault, identities |
| Inside the cluster | Argo CD | Deployments, Services, CronJobs, Ingress, HPAs, ScaledObjects, Rollouts |

The boundary is not crossed. Terraform's Kubernetes and Helm providers work, but both make the cluster a dependency of the state file — after which a broken cluster is also a broken plan. `v3-gitops` sets the boundary and handles the one exception, Argo CD itself.

## Three environments, one set of modules

`dev`, `stage` and `prod`, built from the same Terraform by Terragrunt. `modules/` knows nothing about environments; `live/<env>/<component>/terragrunt.hcl` supplies the inputs and declares the dependencies. The difference between environments is inputs, not code.

| | `dev` | `stage` | `prod` |
| --- | --- | --- | --- |
| Shape | Single zone, smallest SKUs | Prod's shape at its smallest size | Zone-redundant |
| Spot | Everything that tolerates it | Checkers only | Checkers only; the api never |
| Lifecycle | Up during a session | Applied to test promotion, then destroyed | Applied to test promotion, then destroyed |
| Purpose | Where milestones get built | Where the promotion path is proved | Where the production-shaped config is proved |

Shared across all three: the **state backend** and the **Entra applications**. Per environment: VNet, cluster, PostgreSQL, Service Bus, Key Vault. The container registry is shared too, but it is not an Azure resource — see the decision below.

The shared tier is persistent on purpose; it is what makes the per-environment tier safe to destroy. The registry matters most: the digests pinned in `gitops/` have to keep resolving between sessions, or promotion and rollback both stop meaning anything. Whatever holds the images is therefore never torn down with the rest.

Only `dev` and one other environment are ever up together. That is a quota limit before it is a budget one, and the arithmetic is in [COST.md](COST.md).

Sessions in `dev` are about an hour; `stage` and `prod` get under an hour a week between them, purely to verify a promotion. At that length the build and destroy around a verification costs more time than the verification does, which is the sort of ratio that quietly ends up skipped.

So the promotion check is a workflow, not a sitting: apply the environment, run the smoke test against it, destroy it, and report — unattended, on the pull request that moves the digest. The billed time is the same either way. What changes is that it keeps happening. `v11-resilient`'s restore exercise is the exception that stays manual, because it is timed and the timing is the output.

Terragrunt earns its place on three things that are repetitive in plain Terraform across environments:

- **`remote_state`**, deriving each state key from the directory path, so the three environments cannot collide in one storage container.
- **`dependency`**, so the cluster plans against the network's real outputs and `mock_outputs` keep a first plan working before anything is applied.
- **`run --all`**, to apply or destroy a whole environment in dependency order — which is what makes "stand `stage` up, prove the promotion, destroy it" a command rather than an afternoon.

Milestones are built in `dev` first. A milestone is not finished until its Terragrunt config applies cleanly in `stage` and `prod` too, because an environment that only ever ran one configuration has not proved the modules are parameterised.

## Milestones

| Tag | Milestone | New resources |
| --- | --- | --- |
| `v0-bootstrap` | Subscription foundation | State backend in Blob Storage, GitHub OIDC federation, budget, tag policy |
| `v1-network` | A network and a host you can reach | VNet, subnets, NSGs, NAT Gateway, private access, Private DNS zones |
| `v2-cluster` | A cluster and a container on it | AKS Free tier, node pools, Workload Identity, ingress. The application is written here |
| `v3-gitops` | Declarative deployment | Argo CD, app-of-apps, sync waves, self-heal, drift detection |
| `v4-pipeline` | Automatic release | GitHub Actions with OIDC, digest pinning, image scan, SBOM, IaC scan |
| `v5-state` | Permanent data and async work | PostgreSQL Flexible Server, Service Bus, Key Vault, Blob Storage, CronJob |
| `v6-scale` | Elastic capacity | KEDA, HPA, cluster autoscaler, Spot node pool, taints, PDBs, topology spread |
| `v7-observable` | Monitoring and alerts | Managed Prometheus, Grafana, Container Insights, alert rules, OpenTelemetry |
| `v8-progressive` | Safe release | Argo Rollouts, canary steps, analysis templates, automatic rollback |
| `v9-edge` | Public access at the edge | Front Door, WAF, the default endpoint hostname, private origin |
| `v10-harden` | Policy and least privilege | NetworkPolicy, Pod Security Admission, Azure Policy for AKS, Defender, private cluster, image signing |
| `v11-resilient` | Disaster recovery and review | Availability zones, Azure Backup for AKS, a second region, Well-Architected review |
| `v12-govern` | The landing zone around the workload | Management group hierarchy, ALZ initiatives at MG scope, identity vending with managed identities, hub VNet, Azure Firewall egress |

The application is a stub until `v5-state` — no database to persist a monitor to, no queue for the scheduler and checker to talk through. The table of what it does per milestone is in [README.md](README.md).

## What each milestone builds

### `v0-bootstrap` — the subscription foundation

- **Storage Account and one state container** — versioned, encrypted, shared key access disabled so every read goes through Entra ID, and the public endpoint left reachable because closing it locks CI out of state. The decision is below. Locking is the blob lease, which the `azurerm` backend takes natively; there is no lock table on Azure. All three environments share the container and are separated by state key, which Terragrunt derives from the directory path rather than anyone typing it.
- **An Entra application** with federated credentials for GitHub. Two identities: a **plan** identity with `Reader` plus state access, and an **apply** identity whose role assignments grow each milestone. The apply identity gets a federated credential per environment, so a job targeting `prod` presents a different subject than one targeting `dev`.
- **A consumption budget**, action group and email receiver.
- **An Azure Policy assignment** inheriting tags from the resource group, because Azure tags do not propagate on their own.
- **A workflow** running `fmt`, `validate` and `plan` on every pull request.

The state module runs on plain Terraform and local state — the backend it would use is the thing it creates — then the state moves into the container. That happens once in the life of the repository, and it is the only Terraform in this project that Terragrunt does not wrap.

Three operations here are not Terraform and live in [RUNBOOK.md](RUNBOOK.md). One is a prerequisite: the Entra directory permissions must exist before the identities can be created.

### `v1-network` — the network and controlled egress

- A **VNet** with separate subnets for cluster nodes, ingress, the database and private endpoints, an **NSG** on each, and **Private DNS zones** for the endpoints later milestones attach.
- A **NAT Gateway** for outbound traffic. PulseGate's job is making requests to strangers' servers, and a fixed, known egress address is what makes that traffic attributable.
- A **small VM**, no public IP, answering `/healthz`, reached by `az ssh` and `run-command`. It proves the private path works before anything expensive depends on it. Azure Bastion is the obvious answer and is refused in [COST.md](COST.md).

### `v2-cluster` — the cluster

AKS on the Free tier, API server reachable, nodes private.

- **Azure CNI Overlay, powered by Cilium** — Overlay so pods do not consume a VNet address each, Cilium because `v10-harden` needs NetworkPolicy and changing the data plane later means rebuilding the cluster.
- **Two node pools from the start** — a system pool tainted `CriticalAddonsOnly`, and a user pool. One pool is simpler and wrong: `v6-scale` adds a third on Spot, and a cluster that has never expressed pool affinity will not gain it cleanly.
- **No registry resource.** Images live in `ghcr.io` and the packages are public, so the kubelet pulls anonymously — no pull secret, nothing to attach. The decision, and what it gives up, is recorded below.
- **Entra Workload Identity** with the OIDC issuer on. Nothing uses it yet; enabling it later is a cluster update you would rather not schedule.
- **Managed NGINX ingress**, through the application routing add-on.

The application is written at this milestone, in its own repository, built locally and applied by hand with `kubectl` exactly once — so the next milestone has something to take away.

### `v3-gitops` — Argo CD and the boundary

Argo CD in the cluster, manifests moved to `gitops/`, and from here on `kubectl apply` against this cluster is drift rather than a workflow.

Argo CD cannot install itself, so the bootstrap either breaks the boundary in Terraform or breaks it once by hand. It is the second: install from the chart once, then commit an `Application` pointing at Argo CD's own manifests so it manages its own upgrades from the next reconcile. Operation 4 in [RUNBOOK.md](RUNBOOK.md), with a check.

Then app-of-apps — one root Application over a directory of child Applications, one per component, ordered by sync waves, with automated sync, prune and self-heal. GitOps that does not correct drift is a deployment tool with extra steps.

### `v4-pipeline` — the build

Two workflows in two repositories. In the application repository: build the image, scan it with Trivy, emit an SBOM, push to `ghcr.io`. In this one: write the new image **digest** into the `dev` workload overlay, and scan the Terraform with Checkov or `tfsec`. Digest, not tag: a tag is a mutable pointer, and a GitOps repository that references one is not declarative.

Two identities are in play in the build and neither is a stored secret. Terraform authenticates to Azure with the federated credential from `v0-bootstrap`; the registry push authenticates with the `GITHUB_TOKEN` already in the job, given `packages: write`. There is no registry credential to create, store or rotate.

The digest is written into the `dev` overlay only. Promotion to `stage` and then `prod` is a pull request moving that digest between overlays — the image is never rebuilt, which is the whole point of a shared registry and of pinning by digest.

The retrigger loop that a single repository would have needed a path filter for does not exist here. The build runs in the application repository and the digest lands in this one, so the commit cannot retrigger the build that produced it. The repository split removes the problem rather than mitigating it.

What it adds is a cross-repository write, and that is where a third identity appears. `GITHUB_TOKEN` is scoped to the repository running the job, so the application repository cannot commit here without a fine-grained token or a GitHub App key — which would be the first stored credential in the project. The alternative inverts the direction: a workflow in this repository polls the registry for a newer digest and opens the pull request with its own `GITHUB_TOKEN`, storing nothing and paying the poll interval in latency instead. It is an open decision below, and it is the one thing the repository split made harder rather than easier.

### `v5-state` — data and the split

- **PostgreSQL Flexible Server**, Burstable tier, private endpoint in its own subnet, reachable only from the cluster.
- **Service Bus** for the probe queue.
- **Key Vault** for connection strings, read through the Secrets Store CSI driver using the workload identity from `v2-cluster`. No secret is written into a Kubernetes `Secret` by hand, and no connection string reaches the GitOps repository.
- **Blob Storage** for check-result archives.

The application becomes three things — a `scheduler` CronJob that enqueues due monitors every minute, a `checker` Deployment that consumes the queue and probes, and an `api` that reads what the checkers wrote. The probe work leaves the request path for good, which is what lets the checker scale on its own next.

The CronJob needs `concurrencyPolicy: Forbid` and a `startingDeadlineSeconds`, or a slow minute produces overlapping waves that enqueue the same monitors twice.

Because the stack is destroyed daily, the database is empty at the start of every session. Schema migration and seed data therefore have to run automatically on deploy — as a Job with a sync wave ahead of the application — and never as a command someone remembers to type. A rebuild that needs a manual step is a rebuild that will eventually be skipped.

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

Azure Front Door Standard in front of the ingress, WAF in prevention mode, rate limiting on `POST /monitors`, and the origin locked to Front Door traffic only.

No custom domain. The platform is reached on Front Door's own endpoint hostname, `<endpoint>-<hash>.z01.azurefd.net`, which arrives with a Microsoft-managed certificate and needs no DNS zone, no registrar and no ACME. The reasoning is recorded below.

The WAF policy attaches at **profile scope**, which covers the default endpoint without a custom domain being involved.

`POST /monitors` is a public, unauthenticated write that makes the platform fetch an address the caller chose. Rate limiting it is a functional requirement, not hardening.

### `v10-harden` — policy and least privilege

Default-deny NetworkPolicy, then explicit allows. This is where the SSRF problem from the README is finally addressed: the checker pods get an egress policy permitting the internet and denying every RFC 1918 range, the link-local address `169.254.169.254`, and the cluster's own service CIDR. A pod that can reach any public URL and no private one is not what any Kubernetes network gives you by default.

Then **Pod Security Admission** in `restricted` mode, **Azure Policy for AKS** through Gatekeeper for what PSA does not cover, **Defender for Containers** for runtime protection on the cluster, and the API server on **VNet integration** so the control plane is private.

**Image signing** with Cosign, keyless, using the GitHub Actions OIDC token as the signing identity — no key to store or rotate, and the signature bound to the workflow that produced it. An admission policy then refuses unsigned images, closing the loop back to `v4-pipeline`. Cosign rather than Notation because `ghcr.io`'s support for the OCI 1.1 referrers API is inconsistent; Cosign can fall back to the older tag-based signature layout, which works everywhere. Pin that behaviour explicitly rather than trusting the default, and verify a signature end to end before the admission policy is set to enforce.

Defender for Containers covers the cluster here but not the images — its registry scanning is an ACR feature and the images are in `ghcr.io`. Image scanning stays where `v4-pipeline` put it, in Trivy.

Cost governance lands here too: a review of what the tags actually captured, and a second budget scoped to the platform resource group.

### `v11-resilient` — failure and review

Availability zones across the node pools and zone-redundant PostgreSQL. Azure Backup for AKS over cluster state and persistent volumes. A second region holding a database read replica, with Front Door failing over between origins. There is no registry replication to build: `ghcr.io` is globally distributed by GitHub, which is one of the things that choice gave away.

Then a deliberate failure exercise — delete a node pool, restore from backup, record how long it took — and a Well-Architected review against the five pillars, with the findings written down even where they will not be fixed.

### `v12-govern` — the landing zone around it

Everything up to here builds a workload; this builds the platform a workload is supposed to sit inside, then moves PulseGate into it. The reference is the Cloud Adoption Framework's enterprise-scale architecture, and it splits along the same cost line this project already draws.

**The governance half is free and permanent.** A management group hierarchy under the tenant root — Platform, Landing Zones, Sandbox, Decommissioned — with the subscription under Landing Zones, and the policy assignments moved to MG scope, where the tag-inheritance assignment from `v0-bootstrap` would have lived if there had been a hierarchy to hang it on.

The ALZ initiatives are assigned with `enforcementMode` set to `DoNotEnforce` first, so the compliance dashboard reports what *would* happen before anything is denied or created; enforcing is then deliberate, one policy at a time. That ordering matters because much of the initiative is `deployIfNotExists` and `modify`, and a remediation run against the shipped defaults will enable paid Defender for Cloud plans, deploy a Log Analytics workspace, and wire diagnostic settings from every resource into it. Each is a remaining cost in the sense of [COST.md](COST.md) — it starts quietly and no destroy removes it.

**The connectivity half is hourly and disposable.** A hub VNet peered to the spoke, a route table forcing `0.0.0.0/0` from the checker subnet to the hub, and Azure Firewall as the single egress point — application rules allowing outbound HTTP and HTTPS, network rules denying RFC 1918 and the link-local address.

That is the same policy `v10-harden` wrote as a NetworkPolicy, enforced again somewhere the cluster does not control. A pod that escapes the CNI's policy engine still has to get past the firewall, and for a product whose defining risk is fetching URLs strangers chose, two independent enforcement points are worth having. Comparing them is the exercise.

**The identity half moves out of the workload.** In a landing zone the workload repository does not create its own CI identities; the platform layer hands them over with the subscription. The Entra applications from `v0-bootstrap` are replaced by **user-assigned managed identities** with GitHub federated credentials, created by the platform layer's vending code and not by anything under `live/`. The same shape as before survives — one plan identity, one apply identity per environment, the same federated subjects — but the identities become Azure resources, created with subscription `Owner` rather than directory rights, and no app registration is left for the pipeline. The workload side shrinks to what it should have been all along: it receives client IDs. `live/shared/identity/` is destroyed, the GitHub variables from [RUNBOOK.md](RUNBOOK.md) operation 3 are repointed, and the cutover is proved the same way `v0-bootstrap` was — a pull request plans against remote state with the new identity and nothing else.

**Not built.** Creating a subscription through vending needs an MCA or EA billing account, which a personal pay-as-you-go subscription does not have, so that step is read rather than run. The vending module is pointed at the existing subscription instead, which still exercises everything that happens after a subscription exists: placement in the hierarchy, identities, federated credentials and role assignments. DDoS Network Protection stays off — billed monthly per tenant with no proration worth the name, it is the one part of a landing zone that cannot be practised cheaply.

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
| 2 | The `bootstrap` module. Storage Account and state container, on local state | Done |
| 3 | The root `root.hcl`: `remote_state`, provider generation, and the move of the state into the container | Done |
| 4 | The Entra application, federated credentials for GitHub, plan and apply identities | Done |
| 5 | The budget. A consumption budget, an action group, an email receiver | Done |
| 6 | The subscription baseline. Tag inheritance policy, resource group layout, diagnostic defaults | **Next** |
| 6a | The `live/` skeleton. `_envcommon/`, the three environment directories, `env.hcl` per environment | Done |
| 7 | The first workflow. `fmt`, `validate` and `plan` on each pull request | Not started |

Steps 1 to 3 produce a state backend that stores its own state. Steps 4 and 7 are one test in two halves: step 4 creates the identities, step 7 proves they work. Step 6a builds no Azure resources — it is the directory shape the rest of the project applies through, and it is worth having before `v1-network` has something to put in it.

`v0-bootstrap` is complete when a pull request runs a plan that reads state from Blob Storage using a federated credential, and no identity in the pipeline holds a client secret.

## Decisions taken

### Region: `westus3`

Priced against the Azure Retail Prices API on the basket this project actually runs.

**NAT Gateway and Standard Load Balancer are billed at one global rate**, with no region attached — and they are the whole of `v1-network`, so for the first two milestones the region is not a cost decision at all.

On everything that does vary, five regions tie at the cheapest price: `eastus`, `eastus2`, `westus2`, `westus3`, `northcentralus`. The next cheapest anywhere is about 6% above them, and `southeastasia` — the one geography would argue for — is 28% above on compute, which latency does not buy back for this workload. `northcentralus` is out on one availability zone, since `v6-scale` spreads across zones and `v11-resilient` wants zone-redundant PostgreSQL.

That leaves Spot as the tiebreak, which is the right one, because `v6-scale` puts the whole checker fleet on it: `westus3` at $0.0178 an hour, then `eastus` at $0.0203, `westus2` at $0.0210, and `eastus2` at $0.0382.

`D2s_v5` is the comparison SKU rather than necessarily the deployed one — this subscription has no quota for that family, which is recorded in [COST.md](COST.md). Spot rates move; a re-read before `v6-scale` is cheap.

### Environments: `dev`, `stage`, `prod`, on Terragrunt

Three environments, one set of modules, differing by inputs. `dev` is the working environment and stays up during a session; `stage` and `prod` are applied to prove the promotion path and destroyed after.

Only two environments are ever up at once, and the binding constraint is quota rather than budget. At two nodes per cluster on `Standard_B2s`, an environment costs four of this subscription's ten regional vCPUs — so `dev` plus one other fits with two to spare, and all three do not fit at all.

The registry, the state backend and the Entra applications are shared, which makes promotion a digest moving between overlays rather than an image copied between registries.

Terragrunt rather than plain Terraform with workspaces: workspaces share one backend key and one set of variables, which is exactly the coupling three genuinely different environments should not have. The three features that pay for the extra tool are `remote_state` key derivation, `dependency` blocks between components, and `run --all`.

### The state backend: a public endpoint, with identity as the boundary

The state account keeps its public endpoint. Shared key access is disabled, anonymous blob access is off, TLS 1.2 is the floor, and every read — CI's and mine — carries an Entra token and a data-plane role assignment. The boundary around the most sensitive blobs in the project is identity rather than network, and that is a decision, not an oversight.

Closing the endpoint was the first instinct, and this file said so until it was worked through. There are two ways to close it and neither survives `v0-bootstrap`.

A **private endpoint** needs a VNet, and there is none until `v1-network`. The state backend is built before the network that would host the endpoint, and inverting that order leaves the network's own state with nowhere to live.

A **firewall with IP rules** works for a laptop and fails for CI. GitHub-hosted runners have no stable egress address — the published range is thousands of prefixes against a storage account that accepts a few hundred IP rules — and `bypass = ["AzureServices"]` does not cover them, because a GitHub runner is not an Azure service. A firewalled state account therefore makes this milestone's own completion test, a pull request planning against remote state with a federated credential, impossible to pass.

What the identity boundary gives up is less than it first sounds. With shared keys disabled there is no account key to steal, leak or rotate, and no SAS URL to find in a log. The account name is not a credential and is not treated as one, so knowing it buys nothing. What remains is the blast radius of a compromised Entra principal, which a network rule would not have reduced either: CI has to reach this account from the internet for the pipeline to exist at all.

Refused, and worth naming: a **self-hosted runner** inside the VNet would allow a private endpoint and a default-deny rule. It also adds a permanently running VM, which is exactly the standing monthly floor [COST.md](COST.md) exists to prevent, bought in exchange for closing a hole that identity already closes.

Worth revisiting only if a self-hosted runner arrives for some other reason. Nothing in the roadmap needs one.

### Hostname: Front Door's default endpoint, no custom domain

`<endpoint>-<hash>.z01.azurefd.net`, with the certificate Microsoft issues for it. No registrar, no Azure DNS zone, no ACME, no cert-manager.

The daily rebuild is what settles this. Let's Encrypt allows **5 certificates per identical set of hostnames every 7 days**, refilling at one per 34 hours; a stack rebuilt daily asks for one every 24 hours, which is faster than the bucket refills, so cert-manager over ACME HTTP-01 would exhaust the allowance in week one and stay throttled. The limit counts issuance rather than failures, so getting the challenge right does not help. A custom domain would have needed an answer to that. Not having one removes the question.

What it costs is a hostname nobody would choose to read out loud. What it buys, beyond avoiding the rate limit: the Azure DNS zone and its ~$0.50 a month leave the remaining-cost column, the annual domain registration — the only charge in this project Azure does not bill — disappears, and [RUNBOOK.md](RUNBOOK.md) loses its one blocking manual operation for this milestone, since nameserver delegation was the thing that had to happen days ahead of anything else.

Two details that matter in the Terraform:

- **The WAF policy attaches at profile scope.** Security policies associate at profile, domain or route scope, and profile scope covers the default endpoint — so rate limiting `POST /monitors` survives intact, which it had to, being a functional requirement rather than hardening.
- **The hostname is stable across rebuilds, but only because of a setting.** The hash exists to prevent subdomain takeover, and its reuse is governed by `autoGeneratedDomainNameLabelScope`. The default, `TenantReuse`, gives an endpoint of the same name in the same tenant the same label — so destroying and recreating returns the same URL. It cannot be changed on an existing endpoint, so it is set explicitly at creation rather than relied on as a default.

### Registry: `ghcr.io`, not Azure Container Registry

Images live in GitHub Container Registry, in public packages. It is free, digests persist between sessions, and it takes the project's minimum cost to roughly zero — ACR Basic has no free tier and its ~$5 a month was the entire floor.

The pull path gets simpler rather than worse. Public packages on `ghcr.io` allow **anonymous pull**, so the kubelet needs no credential: no `imagePullSecret`, and no registry attachment on the cluster. The push side is a `GITHUB_TOKEN` already present in the job. Nothing in this project stores a registry credential.

What it gives up is Azure surface area, and that is the honest cost:

| Lost | Where it mattered |
| --- | --- |
| ACR attached via kubelet managed identity | `v2-cluster` — one fewer use of managed identity, though Workload Identity still earns its place in `v5-state` for the database and vault |
| Defender for Containers **registry scanning** | `v10-harden` — cluster runtime protection is unaffected; image scanning stays with Trivy |
| ACR Premium geo-replication | `v11-resilient` — nothing to build, since GitHub distributes `ghcr.io` globally |

Two consequences to handle rather than discover:

- **Signing changes tool.** `ghcr.io`'s OCI 1.1 referrers support is inconsistent, so `v10-harden` signs with Cosign keyless rather than Notation. That is arguably a better exercise — the signing identity is the GitHub Actions OIDC token, so there is no key anywhere — but the fallback signature layout has to be pinned deliberately.
- **Packages are private when first pushed.** Visibility is a manual setting, and anonymous pull depends on it. It is [RUNBOOK.md](RUNBOOK.md) operation 6.

Destroying an ACR nightly was considered and refused: it saves at most $4.70 and breaks digest pinning, promotion and rollback, which makes it strictly worse than this.

### Two repositories: the platform here, the application elsewhere

The application source lives in its own repository. This one holds the platform — `bootstrap/`, `modules/`, `live/`, `charts/`, `gitops/`, `scripts/`, `.github/` — and no Python.

This was decided the other way first, on the grounds that one repository told a more coherent story and that the retrigger loop was cheap to break with a path filter. What changed it is the shape of `gitops/`: `platform/` — ingress, KEDA, the collector, Argo Rollouts — is most of that tree and has nothing to do with the application. Keeping it in the application's repository would have coupled the platform's release cadence to the workload's, which is the wrong way round for a repository whose subject is the platform.

The seam is therefore `apps/` leaving, not `gitops/`. Deployment configuration stays with the platform that reconciles it, which is also the canonical Argo CD layout.

Two consequences, one of each sign:

- **The retrigger loop disappears.** A commit here cannot retrigger a build that runs in another repository, so `v4-pipeline` needs no path filter and the single-repository question is closed.
- **The digest write becomes cross-repository**, and `GITHUB_TOKEN` does not cross repositories. Push needs a stored credential; pull needs a poll. That is the first point in this project where a stored secret is a candidate at all, and it is recorded as an open decision rather than settled here.

### CI identities: `live/shared/identity/`, not `bootstrap/`

The Entra applications, their federated credentials and their role assignments live in their own Terragrunt unit under `live/shared/`, next to the environments rather than inside the module that creates the state backend.

They belong with the backend in lifetime — subscription-wide, shared by `dev`, `stage` and `prod`, and never destroyed at the end of a session — but not in anything else. `bootstrap/` is the one unit that has to exist before remote state does, and it stays that size: the backend that stores its own state. Anything that can be applied through `root.hcl` should be, and the identities can.

It is also the first unit applied from `live/`, which makes it the first real test of `root.hcl` somewhere other than the directory it was written against.

The unit is applied by a human, not by CI. The identity that creates the pipeline's identities needs directory permissions the pipeline should never hold, so the pipeline never plans or applies it. This is the pre-landing-zone shape, and it is temporary. `v12-govern` replaces it with the industry-standard one: the platform layer vends user-assigned managed identities to the workload, and this unit is destroyed.

## Open decisions

Recorded here because deciding them silently later is how a project acquires configuration it cannot explain.

| Decision | Due at | Note |
| --- | --- | --- |
| Python framework | `v2-cluster` | Must be async. See the constraints in [README.md](README.md) |
| Helm charts or plain manifests under `gitops/` | `v3-gitops` | Kustomize is the third option and the one that argues best with a digest-writing pipeline |
| NGINX canary annotations or the Istio add-on | `v8-progressive` | Traffic splitting for Argo Rollouts |
| How the image digest crosses repositories | `v4-pipeline` | Push with a stored token, or poll the registry from this repository with none. Push would be the project's first stored credential |
| Azure Firewall Basic or Standard | `v12-govern` | Basic is roughly a third of the hourly rate and has no DNS proxy, which FQDN-based egress rules need |
| Where the platform layer's vending code lives | `v12-govern` | A separate platform repository is the enterprise shape; a top-level directory here keeps the project in one place. Either way, nothing under `live/` applies it |
| Whether the tag policy moves to management group scope | `v12-govern` | It belongs there; the question is whether re-pointing it is worth a re-remediation |
| One Argo CD per cluster, or one reconciling all three | `v3-gitops` | Per-cluster is simpler and matches the destroy-and-rebuild method; a single control plane is more realistic and makes `dev` a dependency of `prod` |
| Whether `stage` and `prod` get their own edge | `v9-edge` | Cheaper now that no DNS zone is involved: a second endpoint on one profile, rather than a second profile |
