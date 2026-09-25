# The dev environment. Read by live/_envcommon/*.hcl through
# find_in_parent_folders("env.hcl"), so every unit under live/dev/ picks it up
# without naming the environment itself.
#
# Where milestones get built. Up for the length of a session, destroyed after.
#
# Only what differs between environments belongs here. Anything shared by all
# three stays in root.hcl, and anything specific to one component stays in
# that component's terragrunt.hcl.

locals {
  environment = "dev"
}
