# Writing a package

1. One folder per package under `recipes/<name>/` with a `package.toml`:
   `name` (= folder), `version` (semver), `kind = "recipe"`, `title`, `title_de`, `requires_core = ">=1"` (the API level of the core
   helpers it uses), `audience = "generic"` (or `"personal"`: hidden unless asked for).
2. `run.sh` is the idempotent installer, built from the helpers of the core (`scripts/recipes/_lib.sh`: ensure_container, step, spin, in_ct, piece, fetch_pinned, ...). It never prints raw command output, never reads a secret from argv or the environment, pins every download (version + sha256) and never opens a public route for an admin page.
3. Raise `version` in `package.toml` AND in `index.toml` (a patch for a fix, a minor for a feature, a major when a person has to act).
4. `python3 <core>/scripts/pkg.py validate` and `repo-check .` must pass (CI runs them against the core).
5. A release is a signed tag `vX.Y.Z` on the commit with the new index. The maintainer cuts it with `bash <core>/scripts/dev/release.sh [patch|minor|major]` on `main`; `release.sh bump <package> [patch|minor|major]` raises one package's version in `package.toml` and `index.toml` together.
