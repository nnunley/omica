# A Program That Keeps Its State

Most programs begin with source code and reconstruct their working state each time they start. They
may load rows from a database into records, recreate service objects, register request handlers, and
rebuild caches. Source code is primary; the running process is temporary.

Mica still has source files and a process, but its centre of gravity is different. The live world is
the primary environment. Source can install identities, relation definitions, rules, and verbs into
that world. With a store attached, those definitions and the durable facts they govern survive a
process restart.

This is a _persistent programming model_: the programmer changes a continuing environment instead of
treating every process start as the birth of a new application.

## Two Kinds of Source Activity

Mica source does two related jobs.

Some source changes what the world knows or can do:

```mica
make_identity(:sensor_17)
make_relation(:Instrument, 1)
assert Instrument(#sensor_17)
```

This creates a named identity, creates a unary relation, and records a fact. Once committed to a
store, later tasks can refer to `#sensor_17` and query `Instrument`.

Other source runs an action against the current world:

```mica
return Instrument(#sensor_17)
```

This task asks whether the fact is present and returns a boolean-like relational result. A verb
invocation, an HTTP request, or work resumed from a mailbox is also a task running against the
current world.

The boundary is not “schema code versus application code.” Both definitions and actions are Mica
source. The distinction is whether the source installs something for future tasks or performs work
now.

## Fileins Bootstrap and Evolve a World

A _filein_ loads source into a world. It can create definitions before later statements depend on
them, so one file may contain this sequence:

```mica
make_identity(:alice)
make_identity(:sensor_17)
make_relation(:ResponsibleFor, 2)
assert ResponsibleFor(#alice, #sensor_17)
```

Run a filein against an in-memory world while experimenting:

```sh
filein path/to/example.mica
```

Use a store directory when the world must survive the command:

```sh
filein --store equipment-db --unit equipment path/to/example.mica
```

The command loads the source and exits. A clean shutdown writes a checkpoint, so later commands
boot the same world:

```sh
filein --store equipment-db --eval 'return Instrument(#sensor_17)'
```

The `--unit equipment` form gives the loaded source a filein unit name so `fileout(:equipment)` can
recover it. The [Filein and Fileout](../runtime/filein-fileout.md) reference gives the unit and
export rules.

## What Persists and What Does Not

Persistence does not mean Mica freezes a process and resumes its memory image later. Durable state
consists of world information such as named relations, facts, identities, rules, verbs, and policy.
Runtime-only mechanisms stay runtime-only:

- an open network connection is not a durable fact;
- a live capability token is not stored as policy;
- a mailbox and its queued wakeups are not ordinary world data;
- volatile relations keep their definition across a restart but start with no stored rows, which is
  how endpoint and session state behaves.

This separation keeps durable meaning inspectable while allowing the process to rebuild ephemeral
machinery safely.

## Durability Is Tunable

Which kinds of facts survive is separate from how quickly they are made durable. A store commit is
published to other tasks as soon as the store's byte budget admits it, and a writer thread appends
the change to a log without blocking the commit path. The `--durability` flag selects when writes
reach stable storage:

| Mode     | When writes are durable                       |
| -------- | --------------------------------------------- |
| `none`   | the host decides when to flush                |
| `group`  | one fsync per writer drain batch; the default |
| `strict` | one fsync per record                          |

Stores also checkpoint: the runtime writes the changed parts of the current world as immutable pages
plus a manifest, then truncates the log. Checkpoints happen automatically once the log passes a byte
threshold and on clean shutdown, so rebuilding a world after a restart reads a compact image instead
of replaying every change.

## Definitions Can Change While the World Lives

A running world is not frozen by its store. Tasks can create relations, assert and retract facts,
and change policy. Suppose the equipment service begins with direct responsibility facts:

```mica
ResponsibleFor(#alice, #sensor_17)
```

Later, the organization decides responsibility should follow project assignment. A rule can derive
responsibility from `AssignedTo` and `WorksOn`. Existing facts do not need to be copied into new
records, and callers can continue asking the same relational question.

Definitions themselves are installed at load time, so changing a rule or verb means editing the
sources and loading a fresh store. Changing facts, policy, and schema through tasks does not require
a restart. Both paths are live world changes; they differ only in whether they introduce new
definitions.

That flexibility has a cost: definitions are live state and must be maintained deliberately. Filein
units, fileout, tests, and review are part of programming in Mica, not afterthoughts for an
operations team.

## Changes Still Happen in Discrete Steps

A persistent world does not mean every expression becomes visible immediately. Each submitted action
runs as a task with a transaction. The task reads a consistent snapshot, prepares changes in
private, and commits them as one transition. Other tasks observe the world before or after that
transition, not halfway through it.

Persistence answers “what continues to exist?” Transactions answer “when does a change become
visible?” The tutorial treats them separately because both matter.

## A Useful Comparison

| Conventional service                            | Mica world                                           |
| ----------------------------------------------- | ---------------------------------------------------- |
| rows persist; application objects are rebuilt   | identities, facts, and installed definitions persist |
| handlers are registered when the process starts | verbs can be installed in the world                  |
| authorization rules often live in middleware    | policy can be expressed as durable relations         |
| background code updates cached conclusions      | rules derive conclusions from their causes           |
| a deployment replaces the running program       | fileins can evolve a continuing world                |

This is not a claim that every external integration belongs in durable state. Hosts still own
network protocols and operating-system resources. Mica's model is about keeping domain meaning and
live behaviour together, while making the boundary to ephemeral host machinery explicit.

## Continue

The next chapter, [Identities, Facts, and Relations](./facts-identities-relations.md), explains the
basic pieces that make up the durable world.
