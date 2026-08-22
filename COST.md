# PulseGate: Cost Model

This project creates infrastructure and destroys it each day. Thus you must know which costs the destroy operation removes. Many costs do not stop when you destroy the stack.

This file is the cost part of `v0-bootstrap`. The budget resources control the cost. This file gives the reasons for the budget values.

## Two terms

| Term | Meaning |
| --- | --- |
| Standing cost | The cost for one month, if the resources operate for all of that month |
| Minimum cost | The cost for one month, after you destroy the stack |

The minimum cost is the cost of PulseGate in a month with no work. The minimum cost increases only when you add a resource that the destroy operation does not remove.

## Three classes of cost

Each cost on the bill is in one of three classes. The class controls how you manage the cost. The size of the cost does not control this.

| Class | Behavior | How to manage it |
| --- | --- | --- |
| Hourly cost | You pay for each hour that the resource exists. Use does not change this cost | Stop or destroy the stack each day |
| Use cost | You pay for each request, each GB, and each ingested log line | Set retention. Log ingestion is the one that grows |
| Remaining cost | You pay each month after the destroy operation, because the stack does not contain the resource | Delete the resource, or accept the cost |

The third class is the reason for this file. The NAT Gateway costs about $33 each month, and it is the largest number in the early milestones. It is also the safest, because the destroy operation removes it every evening.

The costs that cause a problem are small: a DNS zone, a registry, a Log Analytics workspace with no retention policy, a backup vault. You do not destroy these, because they are not the subject of your work.

## The premise: why this project can use Kubernetes at all

LinkForge rejected EKS because the control plane bills about $73 each month whether or not anything runs. A daily destroy cannot make that cheap.

AKS does not have that number.

| Tier | Control plane | SLA |
| --- | --- | --- |
| Free | $0 | None. A 99.5% objective, not a guarantee |
| Standard | About $0.10 each hour, so about $73 each month | 99.9%, or 99.95% with availability zones |
| Premium | About $0.60 each hour | Standard's SLA, plus long-term support |

This project uses the Free tier through `v11-resilient`. There are no users, and an SLA protects revenue that does not exist. Milestone `v11-resilient` examines the Standard tier as a design question, not as a purchase.

This single row is the reason this repository exists next to LinkForge instead of inside it.

## Two ways to stop paying

Azure gives this project a second option that AWS did not.

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
| Defender for Containers | Per vCPU each month | Scales with the node count |
| Azure Policy, built-in definitions | No charge | $0 |
| KEDA, Workload Identity, app routing add-ons | No charge for the add-on | $0. You pay for what they create |
| GitHub Actions, public repository | No charge | $0 |

When you complete a milestone, get the true cost from Cost Analysis and replace the value in the next table. An estimate that you compare with the true bill has much more value than an estimate that you do not compare.

## Three resources this project refuses to buy

**Azure Bastion**, at about $140 each month, is the obvious way to reach a private host and it is nine times the cost of everything else in `v1-network` combined. `az ssh` with Entra authentication and `az vm run-command` reach the same host for nothing. Bastion earns its price when a team needs audited RDP and SSH at scale. One person proving that a subnet is private is not that.

**Azure Managed Grafana**, at about $65 each month, is a per-hour charge for a dashboard server. Grafana runs in the cluster for free, and a cluster-hosted Grafana is reconciled by Argo CD like everything else, which is more on-theme than a resource Terraform creates outside the boundary. Milestone `v7-observable` takes the self-hosted path and records the managed service as considered.

**Front Door Premium**, at about $330 each month, buys the Microsoft-managed WAF rule sets. Front Door Standard supports custom WAF rules, and the rule this product actually needs — a rate limit on `POST /monitors` — is a custom rule. `v9-edge` uses Standard.

The same test applies to every future decision: prefer the resource whose cost stops when the resource stops.

## Cost of each milestone

| Milestone | Largest cost | Standing cost | Minimum cost | Notes |
| --- | --- | --- | --- | --- |
| `v0-bootstrap` | Storage, federation, budget | About $0 | About $0 | The state blobs are tiny. Federated credentials and budget alerts are free |
| `v1-network` | NAT Gateway, public IPs | About $40 | $0 | All hourly. The destroy removes all of it |
| `v2-cluster` | Node pool VMs, load balancer, ACR | About $110 | **About $5** | The first permanent step. ACR Basic bills whether or not you pull |
| `v3-gitops` | Argo CD's own pods | About $0 extra | $0 | Argo CD is software in a cluster you already pay for |
| `v4-pipeline` | GitHub Actions | About $0 | $0 | Free for a public repository. Image layers in ACR grow the Basic tier toward its included quota |
| `v5-state` | PostgreSQL, Service Bus | About $25 extra | Low | Key Vault costs nothing to hold. This is where Azure and AWS diverge most |
| `v6-scale` | Node pool VMs | **Falls** | $5 | Spot capacity and scale-to-zero make the checker fleet cheaper than the fixed replicas it replaces |
| `v7-observable` | Log ingestion | Low, and it grows | **Yes** | Container Insights ingests continuously. Set the tier and the retention when you create the workspace, not after |
| `v8-progressive` | Extra canary replicas | About $0 extra | $0 | A canary runs a second ReplicaSet for minutes at a time |
| `v9-edge` | Front Door, DNS zone | About $40 extra | **Yes** | The DNS zone and the Front Door profile are not destroyed nightly. The domain registration is a separate annual cost |
| `v10-harden` | Defender for Containers | Low | Low | Priced per vCPU, so it tracks the node count. Policy and NetworkPolicy are free |
| `v11-resilient` | The second region, backup storage | **High** | **Yes** | A warm region and a Premium registry are the two largest permanent additions in the project |

Two different shapes are in this table. The standing cost rises at `v2-cluster`, falls at `v6-scale` when Spot and scale-to-zero arrive, and rises sharply at `v11-resilient`. The minimum cost rises in small permanent steps, and it starts earlier than LinkForge's did — at `v2-cluster` with the registry rather than at `v5-state` with the vault, because Azure charges for the registry and does not charge for the vault.

## The value of the daily destroy

Milestones `v1-network` through `v4-pipeline` have a standing cost of about $110 each month. Their minimum cost is about $5. If you run this infrastructure for two hours each day, the cost is roughly $10 to $15 each month.

That ratio is the entire argument for the daily destroy, and it is the same argument LinkForge made. The difference is that on Azure the ratio survives contact with Kubernetes, because the control plane is not a fixed monthly floor.

## The budget in `v0-bootstrap`

Step 5 creates one monthly consumption budget for the whole subscription, with an action group that sends email. It alerts at 50% and 80% of actual cost, and at 100% of forecast cost. It does not create one budget for each milestone.

Azure does not charge for budget alerts, so price is not the reason. The reason is the quality of the alert. Twelve budgets give twelve alerts, each one small, and soon you ignore all of them. One subscription budget answers the only question that matters: is this month different from the last one?

Cost Analysis answers the per-milestone question, and it uses the tags. A budget cannot do that.

The budget must alert only. Azure budgets can trigger an action group that runs an automation runbook, and that runbook could shut things down. That function is wrong for this project: it adds an automatic destroy to an account you are using to learn, and a learning environment that deletes itself at an unpredictable moment teaches the wrong lesson. Examine it again at `v10-harden`, where a second budget scoped to the platform resource group is added.

## Tags, and the way Azure differs here

The tag set is `Project`, `Environment`, `ManagedBy`, and `Milestone`. The `Milestone` tag is the important one. It makes Cost Analysis show the cost of each milestone.

Azure has no activation step. AWS required you to enable Cost Explorer, wait a day for a tag key to appear, activate it, and wait another day. Azure Cost Analysis groups by tag with no setup, so the three-day sequence that opened LinkForge's runbook does not exist here.

Azure has a different problem instead, and it is worse: **tags do not inherit.** A tag on a resource group does not appear on the resources inside it, and a resource created by another resource — a node pool virtual machine, a managed disk, a load balancer in the `MC_` resource group — carries whatever tags its creator gave it, which is usually none. On a Kubernetes project this is not a corner case. Most of the bill is generated by resources AKS created, not by resources Terraform created.

Two mechanisms address it, and `v0-bootstrap` uses both:

- An Azure Policy assignment with the `modify` effect, inheriting the four tag keys from the resource group onto resources that lack them.
- The `node_resource_group` and the AKS `tags` argument, so that the resources AKS generates start with the tags rather than acquire them.

Neither is retroactive. A policy with a `modify` effect corrects existing resources only when you run a remediation task, and the cost record for a day when a resource was untagged stays untagged forever.

## Rules

1. Set the tier and the retention period on the Log Analytics workspace when you create it. The default retention is not the cheapest one, and log ingestion is the only cost in this project that grows without you doing anything.
2. Destroy the stack at the end of each session. From `v2-cluster`, this is the difference between a small bill and a large one.
3. Check the minimum cost each month. In a week with no work, the bill must stay flat. If it does not, a resource exists outside the stack — look first in the `MC_` node resource group, which is where AKS puts the things you did not declare.
4. When you complete a milestone, record the true cost from Cost Analysis and replace the estimate in the table above.
5. Before adding any resource, ask which of the three classes it belongs to. If the answer is "remaining", say out loud what it costs each month forever.
