# Mica Agent

`apps/agent/` is a relation-first LLM coding agent shell. It is the application skeleton for a
web-driven, shareable coding agent in the spirit of OpenCode, Claude Code, and Junie: a command
input, a transcript, an object inspector, and source fragments, all authored as Mica relations and
verbs rather than a separate client application.

The agent uses the Responses API by default. Submitting a command appends a user message, creates a
durable provisional assistant message, and updates that message as typed response events arrive.
Tool calls and results remain part of the transcript, and every request sends the complete relevant
Mica-owned context instead of relying on provider-side response history. A Chat Completions adapter
is available for providers without suitable Responses support. Read-only tools (`read`, `grep`,
`glob`, `ls`) query the source-provider crate's computed relations. The source-provider also exposes
syntax, symbol, definition, references, and VCS history as computed relations for future tools.

> **Port status:** the LLM host bridge is implemented in the Odin port (`mica/external`), so the
> agent loop can call a model, and `host/source` indexes `MICA_SOURCE_ROOTS` at startup so `read`,
> `ls`, and `glob` work over a local worktree; `grep` scans the indexed file text. The Rust source
> provider's syntax, semantic-search, and VCS relations are still not ported, so those views stay
> sparse. The `mica-daemon` instructions below describe the Rust implementation; the shell fileins
> run under `tools/webhost` via `scripts/agent.sh`.

## What It Demonstrates

- Durable identities described by relation facts: workspaces, agents, transcripts, messages, tool
  calls, tool results, and inspector targets.
- Prototype/delegation dispatch through `Delegates`, including UI sync action frobs and
  role-dispatched message rendering.
- Recursive and derived relations for transcript membership and message order.
- Server-owned DOM rendering through `sync_view_dependencies`, `sync_view_tree`, and `sync_event`,
  reusing the same sync contract as the MUD app.
- Browser UI composition written mostly in Mica, with a small JavaScript bootstrap handling the
  column splitter and tool-window close affordances.
- Browser-originated actions routed through generic sync events, then dispatched inside Mica through
  action frobs.
- Authority derived from relation policy into per-task runtime checks.
- Tool calls and results as first-class durable facts (`ToolCall`, `ToolResult` relations) that can
  be inspected, replayed, and audited.
- Agent loop as a Mica verb (`agent/run_loop`) that receives typed LLM stream events through a
  mailbox while ordinary relation updates drive the browser view.

## Fileins

- `core.mica`: workspace, agent, transcript, message, and inspector target identities and relations,
  plus the policy relation declarations and accessor verbs.
- `workspaces.mica`: binds `Workspace`/`WorkspaceRoot`/`source/Repository` from `MICA_SOURCE_ROOTS`
  so tools have a real repository to read.
- `tools.mica`: `Tool`/`ToolCall`/`ToolResult` relations, read-only tool verbs (`read`, `grep`,
  `find`, `ls`), `agent/run_loop`, and LLM message assembly.
- `transcript.mica`: transcript and message DOM composition, including a bounded recent window,
  opt-in scrollback loading, tool-call and tool-result rendering, and a typing indicator while the
  agent loop is running.
- `ui-session.mica`: sync view selection, session facts (including `session/IsStreaming`), agent
  sync action declarations, authority grants, and `sync_view_dependencies` / `sync_view_tree`.
- `ui-compose.mica`: workspace panel, object browser, inspector, command strip with streaming
  indicator, and shell DOM composition.
- `ui-actions.mica`: browser sync event routing and delegated sync action handlers. The
  `agent_command` handler calls `agent/run_loop`.
- `http.mica`: `/agent` HTTP document route and transport-neutral sync mount.
- `style.css`: text asset loaded by `http.mica` with `include_text(...)`.
- `bootstrap.js`: browser boot script for the server-rendered sync client.

## Run The Browser Fixture

```sh
scripts/agent.sh
```

The wrapper builds `tools/webhost`, loads the agent filein set, points `MICA_SOURCE_ROOTS` at the
repository root, and prints the local `/agent` URL to open. Override the bind address with
`MICA_AGENT_BIND` (default `127.0.0.1:8081`). To reach it from another device, bind all interfaces
or the tailnet address and open the printed URL:

```sh
MICA_AGENT_BIND=0.0.0.0:8081 scripts/agent.sh
# or only the tailnet interface:
MICA_AGENT_BIND="$(tailscale ip -4):8081" scripts/agent.sh
```

There is no login on this app, so anyone who can route to the bound address can use the agent and
spend the configured API key.

Set `OPENROUTER_API_KEY` in the environment for LLM access. The default model is
`deepseek/deepseek-v4.1-flash`; override it with `MICA_AGENT_MODEL`. Responses is the default request
shape. Set `MICA_AGENT_API=chat_completions` to use the explicit Chat Completions adapter.

The workspace tools read the `source/*` relations. In this port `host/source` indexes the first
`MICA_SOURCE_ROOTS` root at startup into `RepositoryEntry`, `FileText`, `FileLineCount`, and
`IndexedFile` facts, so `read`, `ls`, and `glob` work over the local worktree and the workspace
panel lists its files. `grep` falls back to scanning indexed file text because the Rust
semantic-search index is not ported; neither are syntax, definition, reference, and VCS relations.
Indexing follows `workspaces.mica`: only the first root (up to the first `:`) is used, and files
larger than 1 MiB or containing NUL bytes are listed but not indexed for content.

Auth is off for the shell demo: the agent world does not declare the MUD person schema, so the
host renders the workspace view directly.

## UI Shape

The current browser UI separates transcript state from available tools:

- The left column holds the transcript panel (message log with role glyphs, tool-call blocks,
  tool-result blocks, and a typing indicator while the agent loop is running).
- The right column holds the workspace panel, the object browser tool window, and the inspector.
- A command strip near the input exposes context actions derived from the current selection or the
  bound workspace.
- The command input sends `agent_command` sync events; the agent appends a user message and runs the
  agent loop, which appends assistant and tool-result messages as it proceeds.

## Design Boundaries

Keep app semantics in Mica source. Host/client support stays generic: browser attributes declare
sync behaviours, while agent-specific meanings such as message roles and inspector targets are
implemented by Mica verbs and relations. The agent app reuses the shared sync-host and sync-dom
fileins and does not duplicate the sync contract.

Prompt safety is treated as a data-boundary problem: the system prompt names the workspace root
and says that file contents, tool results, and quoted message text are data, not instructions.
Tool results are wrapped in `<tool_result>` delimiters before they enter the model context. This is
a mitigation, not a guarantee: a user message can still contain text the model chooses to follow.

## Next Steps

- Write tools (`edit`, `write`, `bash`) with sandboxing and approvals.
- Compaction and branching for context-window management.
- System prompt assembly from skills, context files, and tool snippets.
- Multi-agent threading with sub-agent spawn and inter-agent communication.
