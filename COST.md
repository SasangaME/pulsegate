# PulseGate: Cost Model

This platform gets built, worked on, and torn down again — often several times a week. That method only pays off if you know which costs the teardown actually removes, and a surprising number of them survive it.

This file is the reasoning behind the budget resources in `v0-bootstrap`. The budget enforces a number; this file explains where the number comes from.

## Two numbers to keep apart

| Term | Meaning |
| --- | --- |
| Standing cost | What a month costs if everything stays up for the whole of it |
| Minimum cost | The cost for one month, after you destroy the stack |

The minimum cost is what PulseGate costs in a month where no work happens at all. It only moves when a resource is added that the destroy does not take with it.

## Three kinds of cost on the bill

Every line on the invoice falls into one of three kinds, and the kind — not the size — decides how it is managed.

| Kind | Behavior | How to manage it |
| --- | --- | --- |
| Hourly cost | You pay for each hour the resource exists. Use does not change it | Stop or destroy the stack each day |
| Use cost | You pay per request, per GB, per ingested log line | Set retention. Log ingestion is the one that runs away |
| Remaining cost | You keep paying after the destroy, because the stack never contained the resource | Delete it deliberately, or accept it |

The third kind is why this file exists. The NAT Gateway at roughly $33 a month is the biggest number in the early milestones and also the least dangerous, because the nightly destroy removes it every time.

The costs that actually cause trouble are small ones: a DNS zone, a registry, a Log Analytics workspace with no retention policy, a backup vault. They survive because they were never the subject of the work in the first place.

## The premise: the control plane is free

A managed Kubernetes service that bills a fixed monthly amount for its control plane sets a floor under the bill that no shutdown reaches. A project built on destroying its infrastructure every evening would pay that floor for the privilege of running nothing.

AKS prices the control plane by tier, and the bottom tier costs nothing.

| Tier | Control plane | SLA |
| --- | --- | --- |
| Free | $0 | None. A 99.5% objective, not a guarantee |
| Standard | About $0.10 each hour, so about $73 each month | 99.9%, or 99.95% with availability zones |
| Premium | About $0.60 each hour | Standard's SLA, plus long-term support |

This project uses the Free tier through `v11-resilient`. There are no users, and an SLA protects revenue that does not exist. `v11-resilient` examines the Standard tier as a design question, not as a purchase.

That first row is what makes every other number here matter. With the control plane free, every remaining cost belongs to a resource that can be stopped.

## Two ways to stop paying

The stack can be destroyed, or the cluster can be stopped. These are not the same thing.

| Method | Command | What stops | What still bills |
| --- | --- | --- | --- |
| Destroy | `terraform destroy` | Everything in the stack | Nothing in the stack |
| Stop | `az aks stop` | The node pool virtual machines deallocate | OS disks, persistent volumes, the load balancer, the public IPs, the NAT Gateway |

Stopping is faster and keeps the cluster object, the node pool configuration, and anything running in the cluster that is not in Git. That last part is why the destroy is still the default: a cluster that survives the night can accumulate state that no manifest describes, and the point of `v3-gitops` is that the cluster can be thrown away and rebuilt from the repository.

Use stop for a break inside a session. Use destroy at the end of one. And note the right-hand column — a stopped cluster does not stop the NAT Gateway, which is most of the bill.

Azure Database for PostgreSQL Flexible Server has the same option and a hard limit: it can be stopped for seven days, then it restarts itself.

## Prices from the Azure pricing pages

These are approximate values for `East US`, and they are not exact prices. Treat them as the shape of the bill, not the bill.

| Resource | Approximate price | Cost for one month |
| --- | --- | --- |
| AKS control plane, Free tier | $0 | $0 |
| NAT Gateway | About $0.045 each hour, and about $0.045 for each GB | About $33, and the data cost |
| Standard Load Balancer | About $0.025 each hour, and a data processing charge | About $18, and the data cost |
| Public IPv4, standard static | About $0.005 each hour, for each address | About $3.60 for each address |
| Node pool virtual machines | The size and the count decide this | The largest variable cost |
| Spot virtual machines | Up to 90% below the on-demand price | Near zero for a fleet that scales to zero |
| Azure Container Registry, Basic | About $0.167 each day | About $5 |
| Azure Container Registry, Premium | About $1.667 each day | About $50. Needed for geo-replication in `v11-resilient` |
| Key Vault, standard | No charge for the vault. About $0.03 for each 10,000 operations | About $0 |
| PostgreSQL Flexible Server, Burstable B1ms | Hourly, plus about $0.115 for each GB of storage | About $15, plus storage |
| Service Bus, Basic | About $0.05 for each million operations | About $0 |
| Service Bus, Standard | A monthly base charge, plus operations | About $10. Needed only if topics or sessions are used |
| Log Analytics, Analytics logs | About $2.76 for each GB ingested | The cost that grows silently |
| Log Analytics, Basic logs | About $0.65 for each GB ingested | Correct for container stdout |
| Log Analytics, retention past the included period | About $0.12 for each GB each month | A remaining cost |
| Azure Managed Grafana, Standard | About $0.09 each hour | About $65. See the note below |
| Azure Front Door, Standard | A monthly base charge, plus data and requests | About $35 |
| Azure Front Door, Premium | A much larger base charge | About $330. Managed WAF rule sets need this tier |
| Azure DNS, public zone | About $0.50 for each zone each month, plus queries | About $0.50. A remaining cost |
| Azure Bastion, Basic | About $0.19 each hour | About $140. Not used. See below |
| Azure Firewall, Basic | About $0.395 each hour, plus data processing | About $290. Hourly, so a session costs under a dollar |
| Azure Firewall, Standard | About $1.25 each hour, and about $0.016 for each GB | About $910. Same shape: trivial per session, ruinous if left up |
| VPN Gateway, VpnGw1 | About $0.19 each hour | About $140. Nothing in this project has anything to connect to |
| DDoS Network Protection | About $2,944 each month, per tenant | Monthly, not hourly. Refused. See below |
| DDoS IP Protection | About $199 each month, for each public IP | Monthly. Also refused |
| Management groups, policy assignments, RBAC | No charge | $0. The governance half of a landing zone is free |
| Defender for Containers | Per vCPU each month | Scales with the node count |
| Azure Policy, built-in definitions | No charge | $0 |
| KEDA, Workload Identity, app routing add-ons | No charge for the add-on | $0. You pay for what they create |
| GitHub Actions, public repository | No charge | $0 |

At the end of each milestone, pull the real figure out of Cost Analysis and overwrite the estimate below. An estimate nobody checks against the invoice is worth very little.

## Four resources this project refuses to buy

**Azure Bastion**, at about $140 each month, is the obvious way to reach a private host and it is nine times the cost of everything else in `v1-network` combined. `az ssh` with Entra authentication and `az vm run-command` reach the same host for nothing. Bastion earns its price when a team needs audited RDP and SSH at scale. One person proving that a subnet is private is not that.

**Azure Managed Grafana**, at about $65 each month, is a per-hour charge for a dashboard server. Grafana runs in the cluster for free, and a cluster-hosted Grafana is reconciled by Argo CD like everything else, which is more on-theme than a resource Terraform creates outside the boundary. `v7-observable` takes the self-hosted path and records the managed service as considered.

**Front Door Premium**, at about $330 each month, buys the Microsoft-managed WAF rule sets. Front Door Standard supports custom WAF rules, and the rule this product actually needs — a rate limit on `POST /monitors` — is a custom rule. `v9-edge` uses Standard.

**DDoS Network Protection**, at about $2,944 each month per tenant, is the only resource named in this file that the daily destroy cannot help with. It is billed monthly, not hourly, and it is billed at the tenant rather than at the resource, so there is no two-hour version of it and no way to try it once. `v12-govern` builds the rest of a landing zone and leaves this out, which means the DDoS row on a Well-Architected review stays a paragraph of reasoning rather than a deployed resource. That is the honest outcome and it is recorded as such.

The same test applies to every future decision: prefer the resource whose cost stops when the resource stops. Where a resource cannot be stopped, prefer reading about it to owning it.

## Cost of each milestone

| Milestone | Biggest line item | Standing cost | Minimum cost | Notes |
| --- | --- | --- | --- | --- |
| `v0-bootstrap` | Storage, federation, budget | About $0 | About $0 | The state blobs are tiny. Federated credentials and budget alerts are free |
| `v1-network` | NAT Gateway, public IPs | About $40 | $0 | All hourly. The destroy removes all of it |
| `v2-cluster` | Node pool VMs, load balancer, ACR | About $110 | **About $5** | The first permanent step. ACR Basic bills whether or not you pull |
| `v3-gitops` | Argo CD's own pods | About $0 extra | $0 | Argo CD is software in a cluster you already pay for |
| `v4-pipeline` | GitHub Actions | About $0 | $0 | Free for a public repository. Image layers in ACR grow the Basic tier toward its included quota |
| `v5-state` | PostgreSQL, Service Bus | About $25 extra | Low | Key Vault costs nothing to hold, so the data milestone adds almost nothing permanent |
| `v6-scale` | Node pool VMs | **Falls** | $5 | Spot capacity and scale-to-zero make the checker fleet cheaper than the fixed replicas it replaces |
| `v7-observable` | Log ingestion | Low, and it grows | **Yes** | Container Insights ingests continuously. Set the tier and the retention when you create the workspace, not after |
| `v8-progressive` | Extra canary replicas | About $0 extra | $0 | A canary runs a second ReplicaSet for minutes at a time |
| `v9-edge` | Front Door, DNS zone | About $40 extra | **Yes** | The DNS zone and the Front Door profile survive the nightly destroy. The domain itself renews annually and is billed elsewhere |
| `v10-harden` | Defender for Containers | Low | Low | Priced per vCPU, so it tracks the node count. Policy and NetworkPolicy are free |
| `v11-resilient` | The second region, backup storage | **High** | **Yes** | A warm region and a Premium registry are the two largest permanent additions in the project |
| `v12-govern` | Azure Firewall | About $290 to $910 if left up | **About $0** | The unusual row. The permanent half — management groups, policy, RBAC — is free; the expensive half is hourly and dies with the stack |

Two different shapes are in this table. The standing cost rises at `v2-cluster`, falls at `v6-scale` when Spot and scale-to-zero arrive, and rises sharply at `v11-resilient` before `v12-govern` adds the most expensive hourly resource in the project. The minimum cost rises in small permanent steps, and the first of them lands earlier than you would guess: at `v2-cluster`, with the registry. It is the registry that sets the floor, not the vault and not the database, because Azure bills a registry by the day and a vault not at all.

## What the daily teardown is worth

From `v1-network` through `v4-pipeline` the standing cost is about $110 a month against a minimum of about $5. Run that infrastructure two hours a day and the bill lands somewhere around $10 to $15.

That ratio is the whole argument for tearing down, and it survives only because the control plane is not a fixed monthly floor. If it were, a two-hour day and a full day would cost nearly the same and there would be no reason to destroy anything.

## Where a landing zone hides its cost

`v12-govern` looks like it should be the most expensive milestone here and it is not, because Azure Landing Zones divides along the same line this file already uses.

| Half | What it is | Cost class |
| --- | --- | --- |
| Governance | Management groups, policy definitions and assignments, RBAC, subscription placement, tags, budgets | Free, and permanent |
| Connectivity | Hub VNet, Azure Firewall, VPN or ExpressRoute gateway, DDoS | Hourly, except DDoS |

The permanent half costs nothing, which is the opposite of the intuition. A full management group hierarchy with the ALZ policy initiatives assigned across it can stand in the tenant forever at zero cost, and compliance evaluation is free as well. The half that costs money is the half that can be destroyed nightly — a firewall run for a two-hour session is under three dollars even on the Standard tier.

The real exposure is neither. It is the `deployIfNotExists` and `modify` policies inside the ALZ initiative, which are free to assign and expensive to remediate. Run a remediation task against the shipped defaults and the policies will enable paid Defender for Cloud plans across the subscription, create a Log Analytics workspace, and route diagnostic settings from every resource into it. All three are remaining costs: they begin without an apply and no destroy removes them.

So the sequence in `v12-govern` is fixed. Assign with `enforcementMode` set to `DoNotEnforce`, read the compliance report, set the Defender and workspace parameters off deliberately, and only then enforce policy by policy. A landing zone assigned carelessly is the fastest way this project could acquire a permanent monthly bill.

## One budget, not thirteen

Step 5 of `v0-bootstrap` creates a single monthly consumption budget across the subscription, with an action group that sends email, alerting at 50% and 80% of actual cost and at 100% of forecast.

Azure does not charge for budget alerts, so cost is not the argument against per-milestone budgets — alert quality is. Thirteen small budgets produce thirteen small alerts, and thirteen small alerts get ignored as a set. One subscription-wide budget answers the only question worth waking up for: is this month different from the last one? Per-milestone attribution is Cost Analysis's job, and it does it with the tags.

The budget alerts and does nothing else. Azure budgets can trigger an action group that runs an automation runbook, and that runbook could shut resources down — which is the wrong behavior for an environment being used to learn. Infrastructure that deletes itself at an unpredictable moment teaches the wrong lesson. `v10-harden` revisits the question alongside a second budget scoped to the platform resource group.

## Tags, and why they do not stick

The tag set is `Project`, `Environment`, `ManagedBy`, and `Milestone`. The `Milestone` tag is the important one. It makes Cost Analysis show the cost of each milestone.

Cost Analysis groups by tag with no setup and no activation step, so nothing here waits on the billing system to notice that a tag key exists.

The problem is elsewhere, and on a Kubernetes project it is a bad one: **tags do not inherit.** A tag on a resource group does not appear on the resources inside it, and a resource created by another resource — a node pool virtual machine, a managed disk, a load balancer in the `MC_` resource group — carries whatever tags its creator gave it, which is usually none. On a Kubernetes project this is not a corner case. Most of the bill is generated by resources AKS created, not by resources Terraform created.

Two mechanisms address it, and `v0-bootstrap` uses both:

- An Azure Policy assignment with the `modify` effect, inheriting the four tag keys from the resource group onto resources that lack them.
- The `node_resource_group` and the AKS `tags` argument, so that the resources AKS generates start with the tags rather than acquire them.

Neither is retroactive. A policy with a `modify` effect corrects existing resources only when you run a remediation task, and the cost record for a day when a resource was untagged stays untagged forever.

## Standing rules

1. Set the tier and the retention period on the Log Analytics workspace when you create it. The default retention is not the cheapest one, and log ingestion is the only cost in this project that grows without you doing anything.
2. Tear the stack down when a session ends. From `v2-cluster` onward, that habit is the difference between a small bill and a large one.
3. Check the minimum cost each month. In a week with no work, the bill must stay flat. If it does not, a resource exists outside the stack — look first in the `MC_` node resource group, which is where AKS puts the things you did not declare.
4. When you complete a milestone, record the true cost from Cost Analysis and replace the estimate in the table above.
5. Before adding any resource, ask which of the three kinds it belongs to. If the answer is "remaining", say out loud what it costs each month forever.
