# Implementation Notes

This guide describes the Mica language and runtime. This implementation is the
Odin port in this repository. A few details differ from the original Rust
implementation; they are collected here.

## Language

- A relation call with no named query variables is a boolean predicate test.
  Bound values and wildcards participate in matching and do not appear in a
  result heading; only named query variables do.
- `suspend()` without a duration is a cooperative yield: the task crosses a
  transaction boundary and is rescheduled immediately. Use `read()` to wait
  for host input. `suspend(seconds)` parks on a timer.
- Relation values canonicalize their heading order internally. Consume rows by
  column symbol rather than visual order.

## Runtime and Hosts

- There is one execution tier: a register interpreter. There is no native-code
  compilation tier.
- The HTTP/1.1 + SSE host in `host/web` serves the browser client. There is no
  WebTransport or ZeroMQ transport.
- Committed effects are recorded; delivery is the host's responsibility.
- `world_eval` compiles source against a live world for command-line use, which
  recompiles the stored sources with their top-level expressions removed.

## Persistence

- A store directory contains a write-ahead log, chunk pages, and manifests.
  Durability is `none`, `group` (default), or `strict`; checkpoints run
  automatically past a log-byte threshold and on clean shutdown.
- Filein units are load-time labels. There is no unit replacement model and
  the `SourceOwns*` ownership relations are not populated. `fileout(:unit)`
  returns the loaded (expanded) source text.
- Grant blocks and `include_text(...)` are expanded at load time, so fileout
  emits the expanded form.
- Point-in-time reads use `Store_Options.version` and restore a retained
  checkpoint at that boundary; the log is truncated at each checkpoint.
- A store takes an exclusive lock file. A process killed without a clean
  shutdown leaves the lock behind; remove it by hand.

## Authentication

The HTTP host uses Argon2id password hashing, opaque session tokens, and
cookie sessions for the seeded demo users. There is no account-creation route
and no OAuth provider in this implementation.

## Built-ins

Every built-in documented in [Built-in Functions](../language/builtins.md) is
installed. Where no embedding provider is configured, `embed_text` returns a
deterministic hash-based vector so retrieval plans stay reproducible.
