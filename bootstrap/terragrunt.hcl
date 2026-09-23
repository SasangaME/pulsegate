# bootstrap/ creates the backend and then stores its own state in it. This file
# is what closes that loop, and it is why step 3 exists as a separate step: the
# account has to be applied on local state before this can point at it.

include "root" {
  path = find_in_parent_folders("root.hcl")
}
