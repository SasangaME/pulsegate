# PulseGate: Cost Model

This platform gets built, worked on, and torn down again, often several times a week. That only pays off if you know which costs the teardown actually removes — and a surprising number of them survive it.

This file is the reasoning behind the budget resources in `v0-bootstrap`. The budget enforces a number; this file explains where the number comes from.

Every hourly figure below is **per environment**. There are three — `dev`, `stage`, `prod` — and the rule that keeps that from tripling the bill is that only `dev` plus one other is ever up at once. The shared half — state backend, identities, and a registry that is not an Azure resource — is deliberately the permanent half, and it costs almost nothing.

## Two numbers, three kinds of cost

| Term | Meaning |
| --- | --- |
| **Standing cost** | What a month costs if everything stays up for the whole of it |
| **Minimum cost** | What a month costs after you destroy the stack |

The minimum cost only moves when a resource is added that the destroy does not take with it.

Every line on the invoice is one of three kinds, and the kind — not the size — decides how it is managed.

| Kind | Behavior | How to manage it |
| --- | --- | --- |
| Hourly | You pay for each hour the resource exists. Use does not change it | Stop or destroy the stack each day |
| Use | You pay per request, per GB, per ingested log line | Set retention. Log ingestion is the one that runs away |
| Remaining | You keep paying after the destroy, because the stack never contained the resource | Delete it deliberately, or accept it |

The third kind is why this file exists. The NAT Gateway at ~$33 a month is the biggest number in the early milestones and the least dangerous, because the destroy removes it every time. The ones that cause trouble are small: a registry, a Log Analytics workspace with no retention policy, a backup vault. They survive because they were never the subject of the work.

## The premise: the control plane is free

AKS prices the control plane by tier, and the bottom tier is $0 — against about $73 a month for Standard and about $438 for Premium. Free has no SLA, only a 99.5% objective.

This project uses Free through `v11-resilient`. There are no users, and an SLA protects revenue that does not exist. `v11-resilient` examines Standard as a design question, not a purchase.

That is what makes every other number here matter. With the control plane free, every remaining cost belongs to a resource that can be stopped.

## Two ways to stop paying

| Method | Command | What stops | What still bills |
| --- | --- | --- | --- |
| Destroy | `terragrunt run-all destroy` | Everything in that environment | Nothing in that environment |
| Stop | `az aks stop` | That cluster's node pool VMs deallocate | OS disks, persistent volumes, the load balancer, the public IPs, the NAT Gateway |

Stopping keeps the cluster object, the pool configuration, and anything in the cluster that is not in Git — which is exactly why destroy is the default: the point of `v3-gitops` is that the cluster can be thrown away and rebuilt from the repository. Use stop for a break inside a session, destroy at the end of one.

Note the right-hand column: a stopped cluster does not stop the NAT Gateway, which is most of the bill.

PostgreSQL Flexible Server has the same option and a hard limit: stopped for seven days, then it restarts itself.

## Prices

`West US 3`, read from the Azure Retail Prices API. Accurate on the day they were read; not a quote. Treat them as the shape of the bill, not the bill.

**NAT Gateway and Standard Load Balancer are published at a single global rate**, worth knowing before shopping for a cheaper region: together they are the entire standing cost of `v1-network`, and no region choice moves them. The region decision is in [ROADMAP.md](ROADMAP.md).

| Resource | Price | Per month |
| --- | --- | --- |
| AKS control plane, Free tier | $0 | $0 |
| NAT Gateway | $0.045/hr + $0.045/GB. **Global rate** | ~$33, plus data |
| Standard Load Balancer | $0.025/hr + data processing. **Global rate** | ~$18, plus data |
| Public IPv4, standard static | $0.005/hr each | ~$3.60 each |
| Node pool VMs | Size and count decide it | The largest variable cost |
| Spot VMs | Up to 90% below on-demand | Near zero for a fleet that scales to zero |
| Container registry, `ghcr.io` | Nothing for public packages | $0. Azure Container Registry has no free tier; Basic would be ~$5 |
| Key Vault, standard | Nothing for the vault; $0.03 per 10,000 operations | ~$0 |
| PostgreSQL Flexible, B1ms | $0.017/hr + ~$0.115/GB storage | ~$12, plus storage |
| Service Bus, Basic | $0.05 per million operations | ~$0 |
| Service Bus, Standard | Monthly base + operations | ~$10. Only if topics or sessions are used |
| Log Analytics, Analytics logs | $2.76/GB ingested | The cost that grows silently |
| Log Analytics, Basic logs | $0.65/GB ingested | Correct for container stdout |
| Log Analytics, extended retention | $0.12/GB/month | A remaining cost |
| Front Door, Standard | Monthly base + data and requests | ~$35 |
| Azure Firewall, Basic | $0.395/hr + data processing | ~$290. Hourly, so a session costs under a dollar |
| Azure Firewall, Standard | $1.25/hr + $0.016/GB | ~$910. Same shape: trivial per session, ruinous if left up |
| Defender for Containers | Per vCPU per month | Tracks the node count |
| Management groups, policy, RBAC | Nothing | $0. The governance half of a landing zone is free |
| KEDA, Workload Identity, app routing | Nothing for the add-on | $0. You pay for what they create |
| GitHub Actions, public repository | Nothing | $0 |

At the end of each milestone, pull the real figure from Cost Analysis and overwrite the estimate below. An estimate nobody checks against the invoice is worth very little.

## Refused

| Resource | Cost | Instead |
| --- | --- | --- |
| Azure Bastion | ~$140/mo | `az ssh` with Entra auth and `az vm run-command`, for nothing. Bastion earns its price for audited RDP and SSH at team scale, not for one person proving a subnet is private |
| Azure Managed Grafana | ~$65/mo | Grafana in the cluster, free, and reconciled by Argo CD like everything else. `v7-observable` records the managed service as considered |
| Front Door Premium | ~$330/mo | Standard. Premium buys Microsoft-managed WAF rule sets, and the rule this product needs — a rate limit on `POST /monitors` — is a custom rule, which Standard supports |
| DDoS Network Protection | ~$2,944/mo per tenant | Nothing. Billed monthly at the tenant, so there is no two-hour version and no way to try it once. `v12-govern` leaves it out and the Well-Architected row stays reasoning rather than a resource |
| VPN Gateway, VpnGw1 | ~$140/mo | Nothing in this project has anything to connect to |
| DDoS IP Protection | ~$199/mo per IP | Monthly. Same objection as above |

The test for anything added later: prefer the resource whose cost stops when the resource stops. Where it cannot be stopped, prefer reading about it to owning it.

## The other ceiling, which is not money

A new pay-as-you-go subscription ships with vCPU quotas low enough to constrain this roadmap before the budget does. Quota is checked at allocation time, so it fails the apply and not the plan — the same trap as an unregistered provider.

Read on subscription `<subscription-id>`, identical across every region considered:

| Quota | Limit | Constrains |
| --- | --- | --- |
| Total Regional vCPUs | 10 | Every pool, added together |
| Total Regional **Low-priority** vCPUs | 3 | The Spot pool in `v6-scale` |
| `Standard BS Family` vCPUs | 10 | The B-series, which is what this leaves available |
| `Standard DSv5 Family` vCPUs | **0** | `Standard_D2s_v5` cannot be allocated at all |

So `Standard_B2s` is the node SKU by default rather than by preference. With a system and a user pool at one node each, **an environment costs four vCPUs**:

| Environments up | vCPUs | Fits in 10? |
| --- | --- | --- |
| `dev` alone | 4 | Yes, with six spare |
| `dev` + one of `stage` / `prod` | 8 | Yes, with two spare |
| All three | 12 | **No** |

That is the real reason only two environments are ever up together, and it binds before the budget does. Three low-priority vCPUs is **one** Spot node across the whole subscription, so `v6-scale` can show that KEDA scales the checker fleet on queue depth without showing it scale to anything, and only in one environment at a time.

Quota increases are free and usually granted in a day or two. File the request well before `v6-scale` needs it.

## Cost of each milestone

| Milestone | Biggest line item | Standing | Minimum | Notes |
| --- | --- | --- | --- | --- |
| `v0-bootstrap` | Storage, federation, budget | ~$0 | ~$0 | State blobs are tiny. Federated credentials and budget alerts are free |
| `v1-network` | NAT Gateway, public IPs | ~$40 | $0 | All hourly. The destroy removes all of it |
| `v2-cluster` | Node pool VMs, load balancer | ~$110 | ~$0 | All hourly. The registry is `ghcr.io` and free, so nothing permanent is added here |
| `v3-gitops` | Argo CD's own pods | ~$0 extra | $0 | Software in a cluster you already pay for |
| `v4-pipeline` | GitHub Actions | ~$0 | $0 | Free for a public repository, and so is the registry it pushes to |
| `v5-state` | PostgreSQL, Service Bus | ~$25 extra | Low | Key Vault costs nothing to hold, so the data milestone adds almost nothing permanent |
| `v6-scale` | Node pool VMs | **Falls** | $5 | Spot and scale-to-zero beat the fixed replicas they replace |
| `v7-observable` | Log ingestion | Low, and it grows | **Yes** | Container Insights ingests continuously. Set tier and retention at creation, not after |
| `v8-progressive` | Extra canary replicas | ~$0 extra | $0 | A second ReplicaSet for minutes at a time |
| `v9-edge` | Front Door | ~$35 extra | **Yes** | The profile survives the destroy. No DNS zone and no domain: the default endpoint hostname is used instead |
| `v10-harden` | Defender for Containers | Low | Low | Per vCPU, so it tracks the node count. Policy and NetworkPolicy are free |
| `v11-resilient` | Second region, backup storage | **High** | **Yes** | A warm second region is the largest permanent addition in the project |
| `v12-govern` | Azure Firewall | ~$290–910 if left up | **~$0** | The permanent half — management groups, policy, RBAC — is free; the expensive half is hourly and dies with the stack |

Those are **per-environment** figures. The minimum column is not: it is shared.

Two shapes are in the table. Standing cost rises at `v2-cluster`, **falls** at `v6-scale`, and rises sharply at `v11-resilient`. Minimum cost stays at essentially zero for far longer than it would have — the state blobs are cents and the registry is free — and the first real permanent charge is **`v9-edge`**, with the Front Door profile. That is worth holding onto: through nine of thirteen milestones, a month with no work costs nothing.

From `v1-network` through `v4-pipeline`, `dev` alone stands at about $110 a month against a shared minimum of about $5. At the working pattern this project actually has — **one hour a day** — that becomes:

A session is about an hour in `dev`, plus roughly half an hour of build and destroy around it. `stage` and `prod` add under an hour a week between them. The cadence is irregular — this competes with other work — so the bill is a range rather than a number:

| Sessions | `dev` hours a month | `dev` | `stage`/`prod` | **Total** |
| --- | --- | --- | --- | --- |
| Every day | 45 | $6.86 | ~$1 | **~$8** |
| 5 a week | 33 | $4.90 | ~$1 | **~$6** |
| 3 a week | 20 | $2.94 | ~$1 | **~$4** |
| 2 a week | 13 | $1.96 | ~$1 | **~$3** |
| 1 a week | 7 | $0.98 | ~$1 | **~$2** |

Three things in that table are worth reading twice.

**`stage` and `prod` are a rounding error.** Under an hour a week of verification costs about a dollar a month, because they are hourly and they are almost never up. That is the environment split paying for itself: the thing that would have tripled the bill is the thing that is never running.

**Almost all of it is hourly, so a quiet month is genuinely cheap.** There is no floor to speak of until `v9-edge`: the registry is free, the state blobs are cents, and everything else dies with the stack. A month with no sessions costs close to nothing, which is the property the whole method depends on.

**Build and destroy is the largest inefficiency, not the largest cost.** At one-hour sessions, a third of `dev`'s billed time is infrastructure that exists but is not being worked on — creating an AKS cluster and a PostgreSQL Flexible Server are each several minutes, and the destroy is not instant either. For `stage` and `prod` it is worse, because the useful window is shorter than the setup:

| A verification of | Plus ~30 min of build and destroy | Overhead |
| --- | --- | --- |
| 30 minutes | 60 min billed | 50% |
| 15 minutes | 45 min billed | 67% |
| 10 minutes | 40 min billed | 75% |

In dollars that is pennies and not worth optimising. In attention it is the reason a verification step stops happening, which is why the conclusion in [ROADMAP.md](ROADMAP.md) is to make it a pipeline job rather than a thing to sit through. Cold-rebuild time is worth measuring for the same reason: it is the one number here entirely within the repository's control.

| Up | Standing | Minimum |
| --- | --- | --- |
| Nothing | $0 | ~$5 |
| `dev` | ~$110 | ~$5 |
| `dev` + `stage` | ~$220 | ~$5 |
| All three | ~$330, and over quota | ~$5 |

## Where a landing zone hides its cost

`v12-govern` looks like it should be the most expensive milestone and is not, because Azure Landing Zones divides along the same line this file already uses: the **governance** half (management groups, policy, RBAC, subscription placement, tags, budgets) is free and permanent, and the **connectivity** half (hub VNet, firewall, gateways) is hourly and destroyable. A firewall run for a two-hour session is under three dollars.

The real exposure is neither. It is the `deployIfNotExists` and `modify` policies inside the ALZ initiative — free to assign, expensive to remediate. A remediation task against the shipped defaults will enable paid Defender for Cloud plans, create a Log Analytics workspace, and route diagnostic settings from every resource into it. All three are remaining costs: they begin without an apply and no destroy removes them. The sequence that avoids this is in [ROADMAP.md](ROADMAP.md).

## One budget, not thirteen

Step 5 of `v0-bootstrap` creates one monthly consumption budget across the subscription, alerting at 50% and 80% of actual cost and 100% of forecast.

**The number is $20 a month**, and it comes from the table above. Expected spend through `v6-scale` runs $2 to $8 depending on how busy the month is. The failure this budget exists to catch is a stack left running, which burns $3.62 a day — so the 50% threshold at $10 sits about $2 above the busiest ordinary month and trips within a day of a stack being forgotten. A $15 budget would alert at $7.50 and fire on normal use; a $30 budget would take two days to notice.

The 100%-of-forecast alert is the one that will actually catch it first, because month-to-date actual is low early in the month regardless. The 50% threshold is the backstop, and it will occasionally fire on an unusually heavy month — which is a true answer to the only question this budget asks.

Raise it at `v9-edge`, which adds ~$35 of Front Door and is the first real permanent charge in the project, and again at `v11-resilient`.

Budget alerts are free, so the argument against per-milestone budgets is alert quality, not cost: thirteen small alerts get ignored as a set. One subscription-wide budget answers the only question worth waking up for — is this month different from the last one? Per-milestone attribution is Cost Analysis's job, and it does it with the tags.

It alerts and does nothing else. Azure budgets can trigger a runbook that shuts resources down, which is wrong for an environment used to learn. `v10-harden` revisits this alongside a second budget scoped to the platform resource group.

## Tags, and why they do not stick

The tag set is `Project`, `Environment`, `ManagedBy`, `Milestone`. `Milestone` is the one that makes Cost Analysis show the cost of each milestone, and it groups by tag with no activation step.

The problem is that **tags do not inherit.** A tag on a resource group does not reach the resources inside it, and a resource created by another resource — a node pool VM, a managed disk, a load balancer in the `MC_` resource group — carries whatever tags its creator gave it, usually none. On a Kubernetes project that is not a corner case: most of the bill comes from resources AKS created, not resources Terraform created.

`v0-bootstrap` uses both fixes — an Azure Policy assignment with the `modify` effect inheriting the four keys onto resources that lack them, and the `node_resource_group` and AKS `tags` arguments so generated resources start tagged.

Neither is retroactive. A `modify` policy corrects existing resources only on a remediation run, and the cost record for a day a resource was untagged stays untagged forever.

## Standing rules

1. Set the tier and retention on the Log Analytics workspace **when you create it**. The default retention is not the cheapest, and log ingestion is the only cost here that grows without you doing anything.
2. Destroy the stack at the end of every session — `terragrunt run-all destroy` in the environment directory, not resource by resource. From `v2-cluster` onward this is the difference between a bill around $10 and one around $110.
3. Destroy `stage` and `prod` the moment the promotion they were stood up for is proved. They exist to be applied, not to be kept.
4. Check the minimum cost each month. In a week with no work the bill must stay flat. If it does not, look first in the `MC_` node resource group.
5. When a milestone completes, record the true cost from Cost Analysis and replace the estimate above.
6. Before adding any resource, ask which of the three kinds it is. If the answer is "remaining", say out loud what it costs each month forever.
