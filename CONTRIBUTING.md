# Contributing

## Regenerating `docs/variables.md`

`docs/variables.md` is generated from `variables.hcl`.

After changing any variable definition, run:

```bash
./scripts/generate-vars-doc.sh
```

Then commit both updated files (`variables.hcl` and `docs/variables.md` as applicable).

CI validates this with the `Check variables.md is up-to-date` workflow step.

## Updating compatibility matrix on release

When preparing a release, update `docs/compatibility.md` with:

- the new `pack.version`
- the corresponding OpenStudio Server `app_version`
- minimum supported Nomad and Consul versions
- any notes about compatibility changes

This keeps operators aligned on known-good version combinations.
