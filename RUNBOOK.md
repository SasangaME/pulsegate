# PulseGate: Runbook

PulseGate is built out of Terraform modules, Terragrunt configuration and Kubernetes manifests, with a short list of exceptions. An operation ends up on that list for one of three reasons: Azure exposes no API for it, Terraform has no resource for it, or the operation is the one that installs the tool that would otherwise have done the job.

Those exceptions are collected here so they are not rediscovered mid-apply. Each entry states why it exists, when in the roadmap it has to happen, the steps, and a check — the check matters most, because a hand-run operation produces no plan output to read afterward.

## Status

| Operation | Milestone | Blocking? | Status |
| --- | --- | --- | --- |
| 1. Register the resource providers | `v0-bootstrap` | **Yes** | Done |
| 2. Confirm the directory and subscription permissions | `v0-bootstrap` | **Yes** | Confirmed |
| 3. Configure the GitHub environments and variables | `v0-bootstrap` | Yes, for step 7 | Not done |
| 4. Install Argo CD, on every cluster rebuild | `v3-gitops` | Yes | Not done |
| 5. Retire the Argo CD initial admin password | `v3-gitops` | No | Not done |
| 6. Make the `ghcr.io` package public | `v4-pipeline` | **Yes** | Not done |

Operations 1 and 2 come before the first apply, not after it. Read both before you write any HCL.

`v9-edge` used to add an operation here — register a domain, delegate the nameservers, wait for propagation. It was removed when the project settled on Front Door's default endpoint hostname instead of a custom domain. No registrar, no DNS zone, no ACME, and nothing in that milestone now has to happen days ahead of the rest of it. The reasoning is in [ROADMAP.md](ROADMAP.md).

## Where the friction is

Nothing in this project waits on a billing system. Cost Analysis groups by tag with no activation step, so the tags described in [COST.md](COST.md) work from the day they are applied.

The friction is at the front instead. A subscription will not create a resource type whose provider is not registered, and a fresh subscription has almost nothing registered. The failure arrives as a `MissingSubscriptionRegistration` error in the middle of an apply, halfway through a dependency graph, which is a worse place to discover it than a runbook.

## Operation 1: Register the resource providers

**Reason.** Azure gates each resource type behind a subscription-level provider registration. Terraform's `azurerm` provider registers a core set automatically, and the set it registers does not include most of what this project needs. An unregistered provider fails the apply, not the plan, so `terraform plan` in CI will pass and the apply will not.

**When.** Before step 2 of `v0-bootstrap`. Registration is asynchronous and takes a few minutes for each namespace, so start it and do something else.

**Verified state.** Run on the project subscription on 2026-09-23. All 21 namespaces are `Registered`; both checks below return clean.

Eight of them already were, and nobody registered them — `Network`, `Compute`, `Storage`, `Authorization`, `Consumption`, `CostManagement`, `PolicyInsights` and `Security` arrive with a new subscription, as part of the 24 Azure registers by default. The earlier claim here that every namespace was `NotRegistered` was wrong about those eight. The other thirteen were submitted together and the whole set converged in **45 seconds**, which is faster than the few minutes per namespace this operation warns about — fast enough that it is worth polling rather than walking away, but not fast enough to put in the path of an apply.

That distinction is the reason this stays a runbook operation and not Terraform, which is worth stating because `azurerm_resource_provider_registration` exists and the file's own admission test — *anything expressible as code belongs in the modules* — would otherwise put it there. Two things argue against: destroying that resource **unregisters** the namespace, which hands a per-environment teardown the ability to revoke a subscription-wide flag that `dev`, `stage` and `prod` all depend on; and registration is subscription-scoped shared state, so it belongs to the same persistent tier as the state backend and the Entra applications rather than to anything Terragrunt runs per environment.

**Steps.**

Register the namespaces the roadmap reaches. Registering one this project never uses costs nothing, so register the full set now rather than returning here at each milestone.

```bash
for ns in \
  Microsoft.ContainerService \
  Microsoft.Network Microsoft.Compute Microsoft.Storage \
  Microsoft.KeyVault Microsoft.ServiceBus Microsoft.DBforPostgreSQL \
  Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor \
  Microsoft.AlertsManagement Microsoft.Dashboard \
  Microsoft.Cdn Microsoft.Consumption Microsoft.CostManagement \
  Microsoft.PolicyInsights Microsoft.Authorization \
  Microsoft.KubernetesConfiguration Microsoft.DataProtection \
  Microsoft.Security Microsoft.ManagedIdentity
do
  az provider register --namespace "$ns"
done
```

**Check.** Registration is not instant. Poll until nothing is pending:

```bash
az provider list \
  --query "[?registrationState!='Registered' && registrationState!='NotRegistered'].{n:namespace,s:registrationState}" \
  -o table
```

An empty result means nothing is mid-registration. Then confirm the ones that matter are actually `Registered`:

```bash
az provider list \
  --query "[?namespace=='Microsoft.ContainerService'||namespace=='Microsoft.KeyVault'||namespace=='Microsoft.ServiceBus'||namespace=='Microsoft.DBforPostgreSQL'||namespace=='Microsoft.OperationalInsights'].{n:namespace,s:registrationState}" \
  -o table
```

**Note.** A later milestone that uses a preview feature needs `az feature register` as well, which is a different command with a different wait. Add an operation to this file when that happens; do not guess the feature names now.

## Operation 2: Confirm the directory and subscription permissions

**Reason.** Step 4 of `v0-bootstrap` creates an Entra application, a service principal, federated credentials, and role assignments. Three of those four are not subscription resources. They live in the Entra directory and are created through Microsoft Graph, which means subscription `Owner` is not sufficient on its own. Discovering this halfway through the OIDC work costs an afternoon.

**When.** Before you write the `azuread` provider block.

**What is needed.**

| To create | Where it lives | Permission required |
| --- | --- | --- |
| Application registration, service principal | Entra directory | `Application Administrator`, or `Global Administrator` |
| Federated identity credential | Entra directory | The same |
| Role assignment on the subscription | The subscription | `Owner`, or `User Access Administrator` |
| Storage account, everything else | The subscription | `Contributor` is enough |

**Verified state.**

| Check | Result |
| --- | --- |
| Signed-in user | The break-glass admin account for the project tenant |
| Directory role | `Global Administrator` |
| Subscription role | `Owner` on the project subscription |
| Tenant | The project tenant |

Both conditions are met. No action is required, and this operation is recorded as confirmed rather than done.

**Check.** If the account ever changes, these two commands answer both questions:

```bash
az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf?\$select=displayName" \
  --query "value[].displayName" -o tsv
az role assignment list --assignee "$(az ad signed-in-user show --query userPrincipalName -o tsv)" \
  --include-inherited --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

**Note.** Being Global Administrator makes the bootstrap easy and is not a state to stay in. The whole purpose of step 4 is that CI never uses this identity. After `v0-bootstrap` is complete, this account is break-glass only, and the pipeline runs as a federated credential with role assignments that grow one milestone at a time.

## Operation 3: Configure the GitHub environments and variables

**Reason.** The `azure/login` action needs three identifiers to request a token: the client ID of the application, the tenant ID, and the subscription ID. None of them is a secret — they are identifiers, and the actual authentication is the federated OIDC token that GitHub mints for the job. Storing them as repository *variables* rather than *secrets* is deliberate and is the point of the exercise: after this milestone there is nothing secret in the repository's settings at all.

**When.** After step 4 of `v0-bootstrap` creates the application, and before step 7 runs the first workflow.

**Steps.** In the repository, under Settings, Secrets and variables, Actions, on the Variables tab, add the repository-wide values:

| Name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | The client ID of the plan application, from the Terraform output |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |

The plan identity is repository-wide because a plan is read-only and the same in every environment. The apply identity is not: it has a federated credential per environment, so it needs a GitHub **Environment** per Terragrunt environment.

Under Settings, Environments, create `dev`, `stage` and `prod`. Each holds one variable, `AZURE_APPLY_CLIENT_ID`, with that environment's apply client ID from the Terraform output. Put required reviewers on `prod`, which is the only protection rule this project needs — the environment gate is what makes an apply to `prod` a deliberate act rather than a merge.

None of these is a secret. They are identifiers, and the authentication is the federated OIDC token GitHub mints for the job.

**Check.** Open a pull request that changes a Terraform file. The workflow must reach `terraform plan` and read state from the storage account. If it fails at the login step, the federated credential's subject does not match the workflow's claim — this is almost always the `pull_request` versus `ref` subject distinction, and it is a Terraform-side fix, not a GitHub-side one.

**Note.** The federated credential's subject string is exact. A credential written for `repo:OWNER/pulsegate:ref:refs/heads/main` does not authorize a pull request job, which presents `repo:OWNER/pulsegate:pull_request`. Step 4 creates both, because step 7 needs the second and every later apply needs the first.

## Operation 4: Install Argo CD, on every cluster rebuild

**Reason.** Argo CD cannot install itself, and this project has declared that Terraform stops at the cluster boundary. The bootstrap has to break one of those two rules exactly once. Breaking it by hand, in the runbook, with a check, is better than breaking it in Terraform, where the exception becomes permanent and the cluster becomes a dependency of the state file.

**When.** At the start of `v3-gitops`, and then **every time a cluster is rebuilt** — which, with the stack destroyed at the end of each session, is every session.

That frequency changes what this operation is. A thing done once can be done by hand and written down; a thing done daily has to be a committed script, or it becomes the step that makes you skip the teardown. So the deliverable of `v3-gitops` is not a documented procedure but `scripts/bootstrap-argocd.sh`, idempotent, taking the environment name and reading the same committed values file.

Whether that stays one Argo CD per cluster or becomes a single control plane reconciling all three is an open decision in [ROADMAP.md](ROADMAP.md). The script is the same either way; what changes is how many times it runs.

**Steps.** The mechanics belong to the milestone and are not written out here in advance, because the chart version and the values file do not exist yet. The shape is fixed, and it is the part worth committing to now:

1. Install Argo CD into the cluster once, from the chart, with a values file that is committed to this repository.
2. Commit an Argo CD `Application` that points at Argo CD's own manifests in this repository.
3. Let Argo CD sync that Application. From that reconcile onward, Argo CD manages its own upgrades and the hand-install is never repeated.

**Check.** Delete the Argo CD Deployment and confirm that Argo CD restores it. If it does not, step 2 did not take, and Argo CD is a hand-installed component pretending to be a managed one — which is the exact failure this operation exists to avoid.

**Note.** After this operation, `kubectl apply` against that cluster is a diagnostic tool, not a deployment method. Anything applied by hand from here on is drift, and `v3-gitops` configures Argo CD to remove it.

The daily repetition is the check, and a harsh one: if standing an environment up from nothing is painful, the configuration is carrying state it should not. Record how long a cold rebuild takes the first time it works, and treat any growth in that number as a defect.

## Operation 5: Retire the Argo CD initial admin password

**Reason.** Argo CD generates an initial admin password and stores it in a Kubernetes Secret named `argocd-initial-admin-secret`. It is a bootstrap credential. It is not rotated, it is shared, and it grants full access to the thing that has full access to the cluster.

**When.** In `v3-gitops`, in the same session as operation 4. Not later.

**Steps.**

1. Read the initial password from the secret and use it to log in once.
2. Configure Entra ID as an OIDC provider for Argo CD, with RBAC mapping a directory group to the `admin` role.
3. Disable the local admin account in the Argo CD configuration.
4. Delete `argocd-initial-admin-secret`.

**Check.** Log out and log in through Entra. Then confirm the local account is refused, and that the secret no longer exists in the namespace.

**Note.** Step 2 needs another Entra application registration, which is why operation 2 matters beyond `v0-bootstrap`.

## Operation 6: Make the `ghcr.io` package public

**Reason.** A package published to GitHub Container Registry is **private by default** — *"when you first publish a package that is scoped to your personal account, the default visibility is private and only you can see the package."* Visibility is changed in the package's own settings, and there is no API resource in this project's Terraform that governs it.

This matters more than a visibility setting usually would. The whole reason `v2-cluster` needs no `imagePullSecret` is that public packages on the Container registry allow **anonymous pull**. Leave the package private and the kubelet gets an authentication failure on first pull, and the fix looks like a Kubernetes problem while living in GitHub's settings.

**When.** Immediately after the first successful push in `v4-pipeline`, and before the first deploy that pulls it.

**Steps.**

1. Push the image once, so the package exists.
2. Open the package's landing page — under the repository's **Packages**, or on the account's Packages tab.
3. Select the settings gear, scroll to **Danger Zone**, choose **Change visibility**, and set **Public**.
4. While there, link the package to the repository if it is not already, so its permissions follow the repo.

**Check.** Pull the image with no credentials at all, from somewhere logged out:

```bash
docker logout ghcr.io
docker pull ghcr.io/<owner>/pulsegate-api@sha256:<digest>
```

A successful pull means the kubelet will succeed too. A `denied` or `unauthorized` means step 3 did not take.

**Note.** This is a one-time setting per package, not per push, so it does not recur with the daily rebuild. But there is one package per component — `api`, `scheduler`, `checker` — and each needs it the first time it is published.

## A note on what is deliberately not here

The tag problem described in [COST.md](COST.md) — tags do not inherit downward, and most of an AKS bill comes from resources AKS created rather than resources Terraform created — reads like it belongs in this file, and it does not. It is solved by an Azure Policy assignment in `v0-bootstrap`, which is code.

That is the test for this file. An operation earns a place here when Azure gives no API, no Terraform resource, or when the operation is the one that bootstraps the tool that would otherwise perform it. Anything expressible as code belongs in the modules, however fiddly it is to write.
