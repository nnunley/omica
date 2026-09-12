# Runtime Overview

The Mica runtime executes compiled tasks against a live relation store. The runtime is responsible
for making the language feel direct while preserving the transactional rules that keep a shared
world coherent.

The core runtime concepts are:

- a relation kernel that stores facts, relation metadata, and rules;
- tasks that run bytecode over a transaction;
- a scheduler that owns workers, timers, mailboxes, and suspended tasks;
- a world API that starts a world, submits work, resumes suspended tasks, and checkpoints;
- hosts that translate protocol traffic into work submissions, input, and effects;
- retrieval helpers that use ordinary relations plus computed search relations to record embeddings,
  retrieved context, and answer artefacts.

The runtime is transactional by default. Code can feel direct and live while still committing state
changes and mailbox sends at explicit boundaries.

A typical flow looks like this:

1. A host or REPL submits source or a verb invocation.
2. The compiler produces bytecode for a task.
3. The task runs against a transaction and authority context.
4. If the task commits, relation writes become visible and effects are routed.
5. If the task suspends, the scheduler records why and resumes it later.

The runtime does not require all state to be durable. Endpoint state, capabilities, and mailboxes
are runtime concerns. Durable state stores the world's facts, rules, definitions, and policy.

[Tasks and Transactions](./tasks-and-transactions.md) and [Task Control](./task-control.md) specify
execution boundaries. [Subscriptions](./subscriptions.md) covers settled change delivery, while
[Catalogue and Introspection](./catalogue-and-introspection.md) describes the live schema and
runtime observation surfaces.

## Hosting a Live Runtime

A host starts a world over an initialized kernel:

```odin
world, start := runtime.world_start(
    &kernel,
    sources,                    // paths to fileins, empty when booting a store
    allocator,
    runtime.World_Config {
        actor      = "alice",   // declared identity for submitted tasks
        workers    = 4,
        store_path = "world-db",
        durability = .Group,
    },
)
```

| Entry point                | Responsibility                                                  |
| -------------------------- | --------------------------------------------------------------- |
| `world_start`              | Load sources or boot a store, start the scheduler                |
| `world_call`               | Invoke a verb and wait for its outcome                           |
| `world_submit_call`        | Submit a verb and return a task id                               |
| `world_wait` / `world_release` | Observe a terminal outcome, then free the task entry        |
| `world_eval`               | Compile and run source against the live world                    |
| `world_resume`             | Deliver input to a task suspended on `read`                      |
| `world_task_request`       | Inspect the metadata of a `read` suspension                      |
| `world_checkpoint`         | Write a chunk-page checkpoint                                    |
| `world_mailbox_create`     | Create a mailbox receiver/sender capability pair                 |
| `world_subscribe_changes`  | Observe settled relation changes                                 |
| `world_destroy`            | Stop the scheduler, checkpoint, and close the store              |

The `tools/repl` binary wraps this API for interactive use: it starts or boots
a world and evaluates each line with `world_eval`.

Supplying an `actor` role to an individual call changes a dispatch argument; it does not replace the
endpoint's authority. When `World_Config.actor` is set, submitted tasks run as that identity and
authority is enforced from current policy.

An invocation returns a `Task_Outcome`: `Complete` with a value, `Aborted` with an error, or
`Pending` with a suspend reason. A suspended task resumes when its condition is met: a timer, a
mailbox message, an external request, or host input delivered with `world_resume`.

The host owns delivery of committed effects. `emit` records committed intent; a telnet host, HTTP
host, browser bridge, or tool runner decides how to deliver it.

## Lifecycle and Shutdown

Closing a world stops its scheduler, which cancels suspended tasks and joins worker threads. A
clean shutdown then writes a checkpoint if a store is attached and closes the store, releasing its
lock. Hosts should call `world_destroy` once work has stopped; the web host also handles SIGINT and
SIGTERM so an interrupted process checkpoints instead of leaving stale state.

Capabilities, subscriptions, and mailboxes are process-lifetime machinery. They are not recovered as
durable authority after a restart; policy facts and durable relations are.

## Bytecode Execution

Compilation produces a register program. Instructions load values, calculate results, branch, query
relations, and request operations from the host. The VM owns the active frames and registers; the
task layer owns transaction boundaries, retries, limits, and delivery of committed effects. This
separation lets an embedding supply its own host while using the same language execution rules.

The interpreter is the only execution path in this implementation; there is no native-code
compilation tier. Task instruction budgets and depth limits still apply to every task, so stored
programs behave the same wherever they run.
