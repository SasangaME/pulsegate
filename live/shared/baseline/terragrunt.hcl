# The subscription baseline: the shared resource group, tag inheritance, and
# the activity log routed to a workspace. Step 6 of v0-bootstrap.
#
# Applied by hand, like the rest of live/shared. Assigning a role to the
# policy's identity needs Microsoft.Authorization/roleAssignments/write on the
# subscription, which no CI identity holds.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/modules/subscription-baseline"
}

inputs = {
  project = include.root.locals.project
}
