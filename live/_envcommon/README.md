# `_envcommon/`

One file per component, holding the configuration that component has in every
environment: the module source, the `dependency` blocks and the inputs that do
not change between `dev`, `stage` and `prod`.

A unit under `live/<env>/<component>/` includes two files and adds only what
differs:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path   = "${get_repo_root()}/live/_envcommon/<component>.hcl"
  expose = true
}

inputs = {
  # Only the inputs that differ by environment.
}
```

The component file reads the environment from the nearest `env.hcl`, so it
never names one itself:

```hcl
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}
```

`live/shared/` has no `env.hcl` and does not use this directory. Its units
exist once, not once per environment.

Empty until `v1-network` adds the first per-environment component.
