# MUD Follow-ups

This document records issues found while reading `apps/mud/` end to end. They
are not blocking; each is small and independently actionable. Update this file
when an item is fixed or reclassified.

- Revision: `5655273`
- Date: 2026-09-20
- Scope: `apps/mud/`, the `apps/*` docs and scripts it depends on, and the
  host paths those docs describe.

## Summary

| ID | Item | Area | Severity | Status |
| --- | --- | --- | --- | --- |
| MUD-1 | MUD and apps docs document the Rust daemon, telnet, and WebTransport | docs | P2 | Open |
| MUD-2 | `scripts/mud-github-auth.sh` is referenced but does not exist | docs | P3 | Open |
| MUD-3 | "Create Player" tab posts to `/auth/create`, which the port rejects | app/web | P2 | Open |
| MUD-4 | GitHub sign-in links are rendered against a disabled, unrouted provider | app/web | P3 | Open |
| MUD-5 | `ui-narrative-scenarios.mica` is not run by any harness | tests | P2 | Open |
| MUD-6 | Telnet "routed effects" assume `emit`, which is a no-op in this port | docs/runtime | P2 | Open |
| MUD-7 | `apps/README.md` says the LLM bridge is not implemented | docs | P3 | Open |
| MUD-8 | `lsp-design-doc.md` is untracked at the repository root | housekeeping | P3 | Open |

---

## MUD-1: Docs describe the Rust implementation, not this port

`apps/mud/README.md` and `apps/README.md` were carried over from the Rust
implementation. They tell the reader to run `cargo run --bin mica-daemon`, use a
telnet fixture, and configure a WebTransport host. None of that exists in the
Odin port.

Evidence:

- `apps/mud/README.md:5` lists "HTTP host, WebTransport host" as things the MUD
  exercises.
- `apps/mud/README.md:66` and `:93` give `cargo run --bin mica-daemon` telnet
  and SSE fixtures.
- `apps/mud/README.md:115-141` documents a WebTransport fixture with
  `transport=webtransport`, a WebTransport `url`, and a `certHash`.
- `apps/README.md:14`, `:18`, `:40` describe "live WebTransport DOM sync".
- `apps/README.md:73`, `:95`, `:120-123` use `cargo run`.
- `mdbook/src/runtime/implementation-notes.md:22-24` states the port serves
  HTTP/1.1 + SSE from `host/web` and has no WebTransport or ZeroMQ transport.
- `scripts/mud.sh` is the real entry point; `tools/webhost/main.odin` takes
  `--filein`, `--bind`, `--store`, `--durability`, and `--sync-client`, and has
  no telnet or WebTransport flag.

Impact: the primary "how do I run the flagship example" documentation points at
commands that fail immediately on a fresh checkout.

Suggested action: rewrite the two fixture sections against `scripts/mud.sh` and
`tools/webhost`, drop the WebTransport and telnet instructions (or move them to
a "differences from the Rust implementation" note that links
`implementation-notes.md`), and replace the `cargo` examples with their
`odin run tools/filein --` and `odin run tools/repl --` equivalents.

## MUD-2: `scripts/mud-github-auth.sh` does not exist

`apps/mud/README.md:151` tells the reader to run
`scripts/mud-github-auth.sh`. `scripts/` contains only `kernel-bench.sh`,
`mica-bench.sh`, `mud.sh`, `test.sh`, and `tsan.supp`.

Impact: a copy-pasted command fails, and it implies OAuth is a supported path
when it is not (see MUD-4).

Suggested action: delete the GitHub OAuth section, or replace it with a note
that GitHub OAuth is not implemented in this port.

## MUD-3: "Create Player" posts to a disabled route

The login document renders a "Create Player" tab and a create form whose action
is `/auth/create`. The host answers that route with a 400 and a message saying
creation is disabled.

Evidence:

- `apps/mud/http.mica:89-95` renders the create form with
  `action="/auth/create"`, and `apps/mud/http.mica:129` links the create tab to
  `/auth/login?return=%2Fmud&mode=create`.
- `host/web/auth.odin:277-284` responds `400` with
  `"user creation is not enabled in this port"`.
- `mdbook/src/runtime/implementation-notes.md:50-54` records the same: there is
  no account-creation route and no OAuth provider.

Impact: a visible, primary login affordance always fails. A new user has no way
to obtain an account except the seeded `alice`/`bob` users.

Suggested action: pick one. Either hide the create tab when creation is
disabled (gate it on a config fact the way the GitHub button is gated), or
implement creation. The config-fact route matches the existing
`mud/RuntimeConfig` pattern in `apps/mud/auth.mica`.

## MUD-4: GitHub sign-in links target an unrouted provider

The login document renders a GitHub button when
`mud/RuntimeConfig(#mud/config_github_auth, true)` holds. The host publishes
that flag as `false`, and no handler serves the target path.

Evidence:

- `apps/mud/http.mica:76-83` reads the flag and renders
  `href="/auth/start/github..."` when it is true.
- `tools/webhost/main.odin:136` calls `webhost_configure_auth(world, true, false)`,
  so the local password provider is on and GitHub is off.
- `host/web/auth.odin:243-303` serves only `POST /auth/login`,
  `POST /auth/create`, and `POST /auth/logout`. There is no `/auth/start`
  handler, and `apps/mud/http.mica:40-53` falls through to `404` for it.

Impact: currently latent because the flag is false, but flipping the flag would
render a dead button rather than a working provider. The flag reads like a
supported toggle.

Suggested action: document `mud/config_github_auth` as unimplemented, or remove
the GitHub branch from `http_login_document` so the login surface matches the
host. If OAuth is wanted later, it needs a route handler, not just a flag.

## MUD-5: The narrative DOM scenario suite is never executed

`apps/mud/tests/ui-narrative-scenarios.mica` defines two scenario verbs that
exercise narrative windowing, per-viewer structured rendering, command
suggestions, object browsing, and the inspector. No harness loads it.

Evidence:

- The only referenced suite is `apps/mud/tests/event-scenarios.mica`, at
  `mica/runtime/runtime_test.odin:4823` and
  `tools/appconformance/main.odin:102`, `:115`, `:128`.
- A repository-wide search for `ui-narrative-scenarios` finds only the file
  itself.
- `ui-narrative-scenarios.mica` also depends on `test/assert_equal` and
  `test/assert_true`, which are defined in `event-scenarios.mica`, so it cannot
  be loaded standalone.

Impact: the largest UI-rendering test surface in the app is dead code. Changes
to `ui-narrative.mica`, `ui-compose.mica`, `ui-retrieval.mica`,
`ui-mica-inspect.mica`, or `event-substitutions.mica` can regress rendering
without any test noticing.

Suggested action: add a `mud ui scenarios` case to `tools/appconformance/main.odin`
(and a matching `runtime_test.odin` entry) that loads the full MUD filein set
plus both scenario files, and calls
`test/ui_narrative_renders_recent_event_window` and
`test/ui_narrative_renders_structured_events`.

## MUD-6: Telnet "routed effects" depend on a no-op `emit`

Several docs and code comments describe command execution as routing effects to
endpoints. In this port `emit` is a no-op, so nothing is delivered to an
endpoint; the browser narrative works only because `event/record_source` writes
`event/Delivery` facts that the sync view reads.

Evidence:

- `mica/runtime/builtins.odin:42` registers `{"emit", 2, builtin_noop}`.
- `mdbook/src/runtime/implementation-notes.md:30-31` states that `emit` is a
  no-op and committed effects are not recorded, and that delivery is future
  work.
- `apps/mud/core.mica:948-957` (`event/notify_to`) calls both
  `event/record_source` and `emit`; the visible half is `record_source`.
- `apps/mud/README.md:30` lists "Transactional command execution and routed
  effects over telnet endpoints" as demonstrated.

Impact: readers may believe endpoint delivery is wired. It is not, so the telnet
fixture cannot work even if a telnet host existed, and `emit`-based behaviour is
untestable in this port.

Suggested action: keep the browser path as the documented one, and note
explicitly that `emit` is inert here and that `event/Delivery` is the working
delivery mechanism. When telnet or another endpoint host is added, revisit the
`emit` call sites rather than assuming they already deliver.

## MUD-7: `apps/README.md` understates the LLM bridge

The agent section says the LLM host bridge does not exist, so the shell cannot
call a model and those verbs raise `E_NOT_IMPLEMENTED`. The bridge is
implemented.

Evidence:

- `apps/README.md:58-64` claims `llm_responses_stream` /
  `llm_chat_stream_to` do not exist here and raises `E_NOT_IMPLEMENTED`.
- `mica/runtime/builtins.odin:132-135` installs `openai_chat_completion`,
  `openai_chat_completion_with_options`, `llm_chat_stream_to`, and
  `llm_responses_stream`.
- `mica/external/` contains the implementation (`curl.odin`, `events.odin`,
  `external.odin`, `openai.odin`, `sse.odin`) and `mica/external/external_test.odin`
  covers it.
- `mdbook/src/runtime/implementation-notes.md:24-29` now says the bridge is
  implemented, and notes the Rust source-provider computed relations its tools
  use are still not ported.

Impact: the agent example is described as non-functional when the model path
exists; only the Rust-specific source-provider relations are missing. This is
the same class of drift as MUD-1 and should move together with it.

Suggested action: update the agent section to say the LLM bridge is implemented
and that the missing piece is the source-provider computed relations, linking
the implementation notes.

## MUD-8: `lsp-design-doc.md` is untracked

`git status` reports `lsp-design-doc.md` as untracked at the repository root,
alongside the tracked `README.md` and `LICENSE`. It looks like an in-progress
design document that belongs in `docs/` or under the editor tooling area.

Impact: minor, but it is a repository-root stray and untracked work.

Suggested action: move it into `docs/` (or `editors/`) and add it, or remove it
if it is scratch.

---

## Maintenance

1. Close an item only when the fix lands and is verified.
2. Note the fix and the revision in this file rather than deleting the row.
3. Add new items as they are found; keep the summary table in sync.
