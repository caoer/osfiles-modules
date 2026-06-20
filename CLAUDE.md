# osfiles-modules

## Commit discipline

**Golden rule: if it's been rebuilt, it must be committed and pushed.**

Any nix config change applied via `nixos-rebuild switch` (or `osf rebuild`) MUST be committed and pushed immediately after successful activation. Uncommitted local changes are silently overwritten by the next remote rebuild — there is no gate protecting uncommitted work on the target host. Agents working in this repo should commit after every successful rebuild, not batch commits.
