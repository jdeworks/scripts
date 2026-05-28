# scripts

A grab-bag of standalone scripts I reach for now and then. No structure yet — folders will appear once there's enough to group.

## Contents

- [`scan-for-package.sh`](./scan-for-package.sh) — hunts the filesystem for evidence of a specific npm or pip package (installed dirs, manifests, lockfiles, global/site-packages). Built for chasing reported compromised or typosquatted dependencies. Usage: `./scan-for-package.sh [-m npm|python|both] PACKAGE_NAME [SEARCH_ROOT]`.
