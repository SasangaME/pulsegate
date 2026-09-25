# The stage environment. Read by live/_envcommon/*.hcl through
# find_in_parent_folders("env.hcl"), so every unit under live/stage/ picks it up
# without naming the environment itself.
#
# Where the promotion path is proved: prod's shape at its smallest size.
# Applied to test a promotion, then destroyed.
#
# Only what differs between environments belongs here. Anything shared by all
# three stays in root.hcl, and anything specific to one component stays in
# that component's terragrunt.hcl.

locals {
  environment = "stage"
}
