# scripts

A grab-bag of standalone scripts I reach for now and then. No structure yet — folders will appear once there's enough to group.

## Contents

### [`scan-for-package.sh`](./scan-for-package.sh)

Hunts the filesystem for evidence of a specific npm or pip package — installed dirs, manifests, lockfiles, global/site-packages. Built for chasing compromised or typosquatted dependencies: e.g. when a malicious npm package shows up in the news and you want to know whether anything on the machine is pulling it in.

Each hit is annotated with the **actual version(s)** found, since takeovers are usually scoped to a specific release window. After the scan, if anything turned up, an interactive prompt lets you narrow the result by version — useful when a popular package (`lodash`, `chalk`, …) appears dozens of times but only the releases in the advisory window are problematic.

Supported filter expressions:

- exact: `1.2.3`, `v1.2.3`, `=1.2.3`
- range: `1.2.3 - 1.5.0` (inclusive, spaces required around the hyphen)
- operators: `>1.2.3`, `>=1.2.3`, `<1.2.3`, `<=1.2.3`
- caret / tilde: `^1.2.3` (next major), `~1.2.3` (next minor)
- multiple (OR): comma-separated — e.g. `4.17.15, >=5.0.0`

Usage:

```
./scan-for-package.sh [-m npm|python|both] PACKAGE_NAME [SEARCH_ROOT]
```

Run with no args for interactive prompts. Exits `0` for no evidence, `3` if anything was found. Hits whose version couldn't be extracted are still shown during the scan but excluded from filtered output.
