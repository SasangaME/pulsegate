# The prod environment. Read by live/_envcommon/*.hcl through
# find_in_parent_folders("env.hcl"), so every unit under live/prod/ picks it up
# without naming the environment itself.
#
# Where the production-shaped config is proved. Zone-redundant. Applied to
# test a promotion, then destroyed.
#
# Only what differs between environments belongs here. Anything shared by all
# three stays in root.hcl, and anything specific to one component stays in
# that component's terragrunt.hcl.

locals {
  environment = "prod"
}
