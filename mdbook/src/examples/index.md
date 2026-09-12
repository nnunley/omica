# Running the Examples

The examples in this part are complete Mica fileins checked into `apps/examples/`. They are loaded
by the runtime test suite and can be exercised through the same runner used for other Mica source.

They use three familiar operational domains:

- the shared equipment service models assets, maintenance, sites, and projects;
- the approval workflow models requests, thresholds, decisions, and domain eligibility;
- the dependency planner models service dependencies and outage impact with recursive rules.

Together they cover the central language model without requiring one large application.

## Run from the Repository Root

The commands assume your working directory is the Mica repository root. Build the runner once:

```sh
odin build tools/filein
```

Each walkthrough creates a temporary store directory:

```sh
export MICA_EXAMPLE_STORE="$(mktemp -d)"
```

The shell variable is intentionally specific to these examples. It keeps the commands readable and
prevents the examples from writing a store into the source tree.

Use a new temporary directory for each example. The fileins use straightforward unnamespaced
relation names so their domain model is easy to read; they are not intended to be combined in one
store.

## Why Use a Store Here?

An in-memory filein is enough to check that a file loads:

```sh
filein apps/examples/equipment-service.mica
```

The process exits after the filein, so a later `--eval` command would start a different empty
in-memory world. A store directory lets the walkthrough load the world in one command and interact
with the same committed state in later commands:

```sh
filein --store "$MICA_EXAMPLE_STORE" --eval 'return ReadyForUse(#sensor_17)'
```

The runner writes a checkpoint on clean shutdown, so the loaded definitions remain available after
the process ends.

That also demonstrates an essential Mica property: the identities, facts, rules, verbs, and policy
installed by the filein remain available after the original runner process ends.

## Filein Units

Each walkthrough gives its source a unit name:

```sh
filein --store "$MICA_EXAMPLE_STORE" --unit equipment \
  apps/examples/equipment-service.mica
```

The unit records the loaded source text so `fileout(:equipment)` can recover it. Units are load-time
labels, not a replacement model: changing a unit's definitions means loading a fresh store from the
edited sources.

See [Filein and Fileout](../runtime/filein-fileout.md) for the detailed model.

## Actor-Scoped Commands

After loading, the examples use `--actor`:

```sh
filein --store "$MICA_EXAMPLE_STORE" --actor alice \
  --eval 'return ReadyForUse(#sensor_17)'
```

Each filein contains a small effective `CanRead`, `CanWrite`, and `CanInvoke` policy sufficient for
its walkthrough. The bootstrap filein itself runs with root authority; subsequent tasks demonstrate
ordinary actor-derived authority.

These policy facts are intentionally compact. [Authority](../language/authority.md) explains how a
larger system derives the same effective relations from roles and policy surfaces.

## Reading Runner Output

An `--eval` command prints the returned value:

```text
:transferred
```

Relation results use a heading followed by a set of rows:

```text
[:dependency] {[#api_service], [#database]}
```

Headings are canonical rather than source-position order, and rows are unordered. Their printed
order is not an application contract.

## Automated Coverage

The runtime test suite loads the checked-in fileins and verifies their important transitions:

```sh
odin test mica/runtime
```

The tests cover rule results before and after mutations, verb dispatch, rejected workflow actions,
functional relation updates, and recursive dependency effects.

Continue with the [Shared Equipment Service](./equipment-service.md).
