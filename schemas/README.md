# Cluster configuration schema

This directory holds a copy of the JSON Schema for the cluster configuration
document that the platform generator injects into consumer projects as the File
type CI/CD variable `SPARK_K8S_CONFIG`.

## Do not edit the copy

`cluster-config.schema.json` is owned by the platform generator, where it lives
at `internal/assets/schemas/cluster-config.schema.json`. That file is the single
source of truth.

The copy in this repository arrives only through the automatic sync pull
request that the generator's `schema_sync` job opens on the branch
`chore/sync-cluster-config-schema` whenever the schema changes on the
generator's default branch. Hand edits here are not merged upstream and put the
two copies out of step: the generator's `schema_guard` job fails the
**generator's** pipelines when the copies diverge outside an open sync pull
request, so the red light for a local edit shows up over there, not here.

To change the schema, change it in the generator and let the sync pull request
bring the new copy in.

The initial copy was taken verbatim from the generator branch of
sf-platform-generator!178 at commit `aae04f74`, ahead of the first automatic sync,
so that validation and the test gate are active from the start. The sync pull
request owns every update from there on.

## What this repository does with it

The cluster resolver validates `$SPARK_K8S_CONFIG` against this copy before
parsing it, and fails the job on any violation. See the multi-cluster section of
the root `README.md` for the resolver contract, and
`test/cluster-resolver/run.sh` for the schema gate that checks every fixture
against this copy in both directions, so a breaking schema change fails a
pipeline here rather than a deploy later.

The schema must stay self-contained. A remote `$ref` would be fetched at
validation time, and a deploy job cannot be assumed to have egress to
`sparkfabrik.com`. The `$id` is an identifier, not a fetch target.
