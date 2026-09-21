# A Mica Emacs in the web framework

Status: design proposal.

Date: 2026-09-20.

Scope: a programmable browser editor with Emacs behavior and Mica-owned policy.

This document is an implementation contract. It gives concrete data models, protocols, invariants,
algorithms, limits, file locations, and acceptance criteria.

## 1. Product contract

The product is a Mica environment with the Emacs interaction model. It is not an Emacs skin on a
web form. It is also not an implementation of Emacs Lisp.

The first user is a Mica developer. This user edits files and world objects, evaluates Mica code,
inspects results, and changes the editor while it runs.

The editor must support these core user stories:

- The user opens several buffers and switches between them.
- The user splits a frame into windows and shows one buffer in several windows.
- The user uses familiar Emacs key sequences, including prefix keys and numeric arguments.
- The user invokes commands by name through a minibuffer.
- The user defines commands, modes, hooks, and keymaps in Mica.
- The user edits large text without a complete text copy or complete DOM replacement.
- The user continues to type while a server result is in transit.
- The user recovers unsaved text after a host restart.
- The user grants file, process, and buffer access through Mica authority.

The design targets the default Emacs interaction model. Exact Emacs rendering and Emacs Lisp
package compatibility are not goals.

Browser and operating-system shortcuts can override some key events. The editor must document each
unsupported default binding and provide a configurable alternative.

## 2. Design decisions

These decisions are requirements:

1. Mica owns all editor semantics and durable editor state.
2. Browser JavaScript owns platform input, provisional display, focus, measurement, and clipboard
   access.
3. Odin host code transports values and provides capability-gated platform services.
4. The synchronized DOM path renders editor chrome and window layout.
5. A separate editor path carries ordered input, buffer results, and viewport data.
6. The browser never treats provisional text as authoritative text.
7. The web host never accepts an arbitrary command selector from the browser.
8. Every text position in a Mica protocol uses a Unicode scalar offset.
9. Every browser boundary converts explicitly between UTF-16 offsets and scalar offsets.
10. Every queue, message, viewport, and retained result has a fixed bound.

The design does not put keymap policy or command implementations in JavaScript. JavaScript contains
only a fixed interpreter for Mica-produced browser operations.

## 3. Terms

| Term | Meaning |
| --- | --- |
| Editor app | The Mica files under `apps/editor/`. |
| Browser client | The JavaScript input and viewport code. |
| Web host | The Odin HTTP and SSE host under `host/web/`. |
| Session | One authenticated editor connection and its transient state. |
| Frame | The complete editor area in one browser page. |
| Window | One viewport that shows one buffer. |
| Buffer | A transactional Mica text object. |
| Point | The insertion position for one window. |
| Mark | A saved buffer position for a session. |
| Region | The scalar range between point and mark. |
| Viewport | The bounded text range that one window displays. |
| Command | A named Mica operation that changes editor state. |
| Key sequence | One or more normalized key chords that select a command. |
| Authoritative state | State from a committed Mica transaction. |
| Provisional state | Browser state that predicts pending Mica results. |

One browser page contains one frame. This rule keeps the first frame model independent from browser
tabs and browser windows.

## 4. Existing foundation

The buffer runtime already provides these required properties:

- persistent piece-tree storage.
- scalar positions and slices.
- transactional edits.
- atomic buffer and relation commits.
- durable and volatile text.
- revisions and revision-checked client edits.
- bounded change delivery.
- bounded line projections.
- marker rebasing.
- conflict policies.
- bounded history and whole-buffer reversion.

The synchronized web framework already provides these properties:

- authenticated sessions.
- Mica-owned DOM trees.
- structural DOM patches.
- relation subscriptions.
- bounded session output.
- browser-to-Mica actions.
- HTTP input and SSE output.

The existing DOM event path is not the editor input path. It serializes form-style events and can
coalesce pending input values. It also rerenders a complete Mica DOM tree after a relevant change.

The editor path must preserve every command in order. It must also show text before a network result
arrives. Therefore, the editor path extends the web session without changing ordinary DOM actions.

## 5. Component ownership

### 5.1 Mica ownership

Mica owns these items:

- buffer creation, retirement, names, kinds, and file bindings.
- commands and command dispatch.
- keymaps and keymap precedence.
- prefix keys and numeric arguments.
- major modes, minor modes, and hooks.
- frame and window trees.
- selected windows and selected buffers.
- point, mark, regions, and viewport starts.
- the kill ring, registers, bookmarks, and command history.
- minibuffer requests and completion policy.
- undo groups and redo groups.
- authority policy.
- file conflict policy.
- browser-operation plans.
- all authoritative editor results.

### 5.2 Browser ownership

The browser client owns these items:

- `keydown`, `beforeinput`, `compositionstart`, `compositionupdate`, and `compositionend` handling.
- focus and hidden input control state.
- clipboard API calls after a user gesture.
- pointer, wheel, drag, and resize events.
- font and viewport measurement.
- UTF-16 and scalar offset conversion for visible text.
- provisional text, point, selection, and scroll state.
- application of authoritative editor results.
- application of Mica-produced browser operations.

The browser client must not invent key bindings, command names, mode behavior, or file policy.

### 5.3 Web host ownership

The web host owns these items:

- message decoding and size limits.
- session authentication.
- ordered input queues for each session.
- duplicate and gap detection for client sequence numbers.
- Mica task submission as the session actor.
- editor result delivery through SSE.
- bounded result retention for reconnects.
- file, process, clock, and environment services.
- cleanup after disconnect or shutdown.

The web host must not implement editor commands. It calls fixed Mica selectors and transports their
results.

## 6. High-level data flow

The browser uses two paths:

```text
                     control path
Mica relations  -> sync_view_tree -> DOM diff -> browser chrome

                      editor path
browser input -> /editor/input -> ordered session queue -> Mica command
browser text  <- editor SSE result <- committed buffer and window state
```

The control path renders these items:

- the frame container.
- split containers.
- window containers.
- mode lines.
- the minibuffer container.
- menus, popups, inspectors, and status panels.

The editor path renders these items:

- visible text lines.
- text faces and decorations.
- point and region geometry.
- provisional edits.
- authoritative buffer deltas.
- viewport snapshots after resynchronization.

Text content must not occur as thousands of children in `sync_view_tree`. A buffer change must not
cause a complete editor DOM diff.

## 7. Repository layout

The implementation uses these files:

| Path | Responsibility |
| --- | --- |
| `apps/editor/schema.mica` | Relations, identities, and authority surfaces. |
| `apps/editor/session.mica` | Session creation, cleanup, and active input state. |
| `apps/editor/buffers.mica` | Buffer metadata, naming, creation, and retirement. |
| `apps/editor/windows.mica` | Frame tree, splits, selection, point, and viewport state. |
| `apps/editor/keymaps.mica` | Keymap definitions, precedence, prefixes, and browser plans. |
| `apps/editor/commands.mica` | Command protocol and common editing commands. |
| `apps/editor/undo.mica` | Undo journal and inverse edit handling. |
| `apps/editor/minibuffer.mica` | Prompts, command completion, and histories. |
| `apps/editor/files.mica` | Visit, save, external-change, and recovery policy. |
| `apps/editor/modes.mica` | Major modes, minor modes, hooks, and local values. |
| `apps/editor/ui.mica` | Frame chrome and `sync_view_*` verbs. |
| `apps/editor/http.mica` | Initial editor document route. |
| `apps/editor/defaults.mica` | Default Emacs-style bindings. |
| `apps/editor/tests/` | Mica scenarios for editor behavior. |
| `host/web/editor_protocol.odin` | Editor message decoder and encoder. |
| `host/web/editor_session.odin` | Ordered queues, replay results, and task dispatch. |
| `host/web/editor_files.odin` | Capability-gated file service. |
| `host/web/editor_process.odin` | Bounded child-process service and mailbox delivery. |
| `host/web/editor_runtime.odin` | Evaluation and unit-replacement service. |
| `host/web/editor-client.js` | Browser input, provisional replica, and viewport renderer. |
| `host/web/editor-client.test.mjs` | Browser protocol and replica tests. |
| `host/web/editor.odin` | Current input admission, result replay, and worker dispatch. |
| `host/web/sync_json.odin` | Tagged session output and editor replay state. |
| `host/web/sync.odin` | Mixed SSE event writer. |
| `host/web/view.odin` | Buffer dependency registration and resynchronization. |
| `host/web/routes.odin` | Static editor client route. |
| `tools/webhost/` | Editor service configuration and lifecycle. |

The generic `sync-client.js` remains usable without the editor client.

## 8. Buffer identity and lifecycle

The catalogue name of a buffer is an internal name. It is not the name that the user sees.

The current runtime fixes catalogue names at creation. It also retains a tombstone after buffer
retirement. Therefore, the editor must never use a display name as a catalogue name.

An internal name has this form:

```text
editor/buffer/<world-counter>
```

The counter is durable and monotonic. The editor converts the complete string to a symbol with
`to_symbol` before it calls `make_buffer`.

The editor stores display names in relations:

```mica
make_relation(:editor/Buffer, 1)
make_functional_relation(:editor/BufferCounter, 2, [0])
make_functional_relation(:editor/BufferName, 2, [0])
make_functional_relation(:editor/LiveBufferName, 2, [0])
make_functional_relation(:editor/BufferOwner, 2, [0])
make_functional_relation(:editor/BufferKind, 2, [0])
make_functional_relation(:editor/BufferMajorMode, 2, [0])
make_functional_relation(:editor/BufferReadOnly, 2, [0])
make_functional_relation(:editor/BufferSavedRevision, 2, [0])
```

`BufferName(buffer, name)` maps an internal symbol to a display string.
`LiveBufferName(name, buffer)` enforces one live buffer for each display name.
`BufferCounter(:world, next)` stores the next internal number.

`BufferOwner(buffer, actor)` records the creating actor. Shared access uses the standard `CanRead`
and `CanWrite` policy relations. Display names remain unique across the world.

The buffer creation verb performs these actions in one transaction:

1. It reserves the next internal counter.
2. It creates the catalogue buffer.
3. It asserts all editor metadata.
4. It inserts initial text.
5. It returns the internal symbol.

The retirement verb rejects a modified file buffer until the user confirms. It also rejects the
active minibuffer. Before retirement, it gives each affected window another live buffer.

In the retirement transaction, it removes buffer-local values, undo groups, overlays, markers, and
file bindings. It detaches bookmarks but preserves their file paths. It then calls `kill_buffer`.
It does not reuse the internal symbol.

Killing a process buffer requests process termination first. The buffer retires after the process
exit event or the configured termination timeout.

The editor disambiguates a duplicate display name with `<2>`, `<3>`, and later suffixes. The
internal name does not change after a display-name change.

Default durability is:

| Buffer kind | Durability |
| --- | --- |
| Scratch and user-created text | `:durable` |
| File buffer with unsaved recovery | `:durable` |
| Process output | `:volatile` |
| Search and completion result | `:volatile` |
| Minibuffer | `:volatile` |

The editor uses the `:reject` conflict policy for file and scratch buffers. Two sessions can still
edit one buffer. A stale writer receives `resync` and must reconcile before another edit.

The editor command path does not attach to a `:span` buffer. Span merging can transform edits during
publication, after Mica has planned marker changes. Supporting it requires an ordered post-commit
marker rebase design that this document does not specify.

## 9. Session state

Editor session state is volatile. A closed session must not remain after a host restart.

```mica
make_relation(:editor/Session, 1, :volatile)
make_functional_relation(:editor/SessionActor, 2, [0], :volatile)
make_functional_relation(:editor/SessionFrame, 2, [0], :volatile)
make_functional_relation(:editor/SelectedWindow, 2, [0], :volatile)
make_functional_relation(:editor/PendingKeys, 2, [0], :volatile)
make_functional_relation(:editor/PrefixArgument, 2, [0], :volatile)
make_functional_relation(:editor/LastCommand, 2, [0], :volatile)
make_functional_relation(:editor/ThisCommand, 2, [0], :volatile)
make_functional_relation(:editor/KeymapGeneration, 2, [0], :volatile)
make_functional_relation(:editor/FrameNodeCounter, 3, [0, 1], :volatile)
make_functional_relation(:editor/FrameGeneration, 3, [0, 1], :volatile)
make_functional_relation(:editor/MarkerCounter, 2, [0], :volatile)
```

The session id is the decimal `u64` from the web session. The host binds the session to one actor.
The host rejects a request with a different actor before it calls Mica.

The session creation verb is idempotent. It creates one frame, one window, and one minibuffer
context. It also selects the initial scratch buffer.

Session cleanup retracts all volatile session, frame, window, and prompt facts. It does not retire
user buffers.

## 10. Frame and window model

A frame contains a binary split tree. Internal nodes describe splits. Leaf nodes describe editor
windows.

Window and node ids are integers allocated from a counter in each session. A compound key includes
the session id, so ids only need session-local uniqueness.

```mica
make_relation(:editor/Frame, 2, :volatile)
make_functional_relation(:editor/FrameRoot, 3, [0, 1], :volatile)

make_functional_relation(:editor/NodeKind, 3, [0, 1], :volatile)
make_functional_relation(:editor/SplitAxis, 3, [0, 1], :volatile)
make_functional_relation(:editor/SplitRatio, 3, [0, 1], :volatile)
make_functional_relation(:editor/SplitFirst, 3, [0, 1], :volatile)
make_functional_relation(:editor/SplitSecond, 3, [0, 1], :volatile)

make_functional_relation(:editor/WindowBuffer, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowPointMarker, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowStartMarker, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowHorizontalOffset, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowHeightLines, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowWidthColumns, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowWrapMode, 3, [0, 1], :volatile)
make_functional_relation(:editor/WindowGoalColumn, 3, [0, 1], :volatile)
```

`NodeKind` is `:split` or `:window`. A split axis is `:horizontal` or `:vertical`. A ratio is an
integer from 1 through 999 and represents thousandths.

The following invariants apply:

- Each frame has exactly one root.
- Each node has exactly one kind.
- Each split has exactly two different children.
- A child has exactly one parent.
- The tree contains no cycle.
- Each leaf has exactly one buffer, point marker, and start marker.
- The selected window is a leaf in the session frame.
- Each ratio is from 1 through 999.
- A frame always contains at least one window.
- The frame generation increases after each published tree or layout change.

`WindowWrapMode` is `:truncate` or `:soft`. The default is `:truncate`.

Window commands must validate the complete proposed tree before they publish it. A rejected command
must leave the old tree unchanged.

`split-window-below` and `split-window-right` replace one leaf with one split and two leaves. The old
leaf becomes the first child. The new leaf shows the same buffer and gets independent markers.

`delete-window` replaces the parent split with the sibling subtree. It rejects deletion of the only
window.

`other-window` walks leaves in stable depth-first order. A positive argument moves forward. A
negative argument moves backward.

A frame snapshot includes the node id of each split. The browser uses this id during a divider
drag. The browser changes the visible ratio during the drag. On release, it sends one
`resize_split` item with the split id and ratio. Mica stores the ratio and increases the frame
generation.

## 11. Point, mark, and viewport positions

Each point and viewport start uses the existing marker relations. A session marker id is the
structural value `[session, local_marker_id]`. `MarkerCounter` supplies the local integer.

This composite value is the key in the shared `Marker` relation. It prevents marker collisions
between sessions without interning an unbounded number of symbols.

Point uses `:stick_after`. Viewport start uses `:stick_before`. The mark insertion type depends on
the command that creates the mark.

The mark belongs to a session and buffer, not to a window:

```mica
make_functional_relation(:editor/BufferMarkMarker, 3, [0, 1], :volatile)
make_functional_relation(:editor/BufferMarkActive, 3, [0, 1], :volatile)
```

Two windows that show one buffer keep independent point markers. They share the session mark for
that buffer.

Every successful text command rebases these positions in the same transaction:

- all point markers for the changed buffer.
- all viewport-start markers for the changed buffer.
- the active mark for the changed buffer.
- overlay and diagnostic markers that the application owns.

The command calls `buffers/markers_rebase` once for the changed buffer. Marker movement must visit
all stored markers for that buffer. This cost follows the existing marker design.

Viewport rendering uses bounded `BufferMarkers` queries. It must not request the complete marker
table merely to paint one window.

The buffer revision and each marker revision must match after publication. A mismatch is an editor
state error and forces a viewport resynchronization.

## 12. Required buffer navigation additions

The current line projection can return complete lines. A long logical line can still create an
unbounded result. Cursor movement also needs direct line and column conversion.

Add these builtins:

| Builtin | Result |
| --- | --- |
| `buffer_line_span(buffer, line)` | `{:start, :stop}` without line text, or `none`. |
| `buffer_position_line_column(buffer, offset)` | `{:line, :column}` for a scalar offset. |
| `buffer_line_column_offset(buffer, line, column)` | Scalar offset clamped to the logical line. |
| `buffer_viewport(buffer, first, lines, max_scalars)` | Bounded relation of line fragments. |

`buffer_viewport` has this heading:

```text
[:buffer, :line, :start, :stop, :text, :complete]
```

The operation returns at most `lines` rows and at most `max_scalars` total scalars. When the scalar
limit truncates text, the last row has `:complete -> false`.

The runtime must not materialize text outside the requested scalar budget.

## 13. Commands

A command is a stable identity with a display name and a Mica selector.

```mica
make_relation(:editor/Command, 1)
make_functional_relation(:editor/CommandName, 2, [0])
make_functional_relation(:editor/LiveCommandName, 2, [0])
make_functional_relation(:editor/CommandSelector, 2, [0])
make_functional_relation(:editor/CommandPredictor, 2, [0])
make_functional_relation(:editor/CommandBarrier, 2, [0])
make_functional_relation(:editor/CommandRepeatable, 2, [0])
```

`CommandPredictor` is one fixed browser operation or `:none`. If a command can change the selected
frame, window, buffer, mode, or keymap, `CommandBarrier` is `true`.

The browser sends normalized input. It does not send a command selector. Mica resolves the command
from the active keymaps and invokes `CommandSelector` with fixed roles.

`LiveCommandName(name, command)` enforces one live command for each `M-x` name. The command loop
uses Mica `invoke(selector, roles)` for dynamic dispatch.

Each command receives these roles:

```text
session, frame, window, buffer, point, mark, prefix_argument, input
```

Each command returns a map:

```mica
{
  :status -> :ok,
  :edits -> [],
  :message -> none,
  :browser_operations -> [],
  :barrier -> false
}
```

An editing command must calculate its complete edit list before it changes the buffer. It applies
the list through `editor/apply_edits`. The host supplies a unique buffer client token.

`editor/apply_edits` performs these actions:

1. It compares the input revision with `buffer_revision`.
2. It reads text that the inverse edits require.
3. It calls `buffer_apply` once with the client token.
4. It rebases editor markers through the edit list.
5. It records one undo group.
6. It returns the forward edits, predicted revision, and client token.

This return value is staged, not authoritative. The commit can still fail. The host must read
`buffer_apply_result` after the task reaches a terminal outcome.

An interactive command can change text in one buffer. A command that needs several buffers must
call a separate noninteractive transaction workflow.

Custom commands must use editor wrappers for text changes. If a custom command changes a buffer
through raw builtins, the host sends `:resync` instead of an incremental result.

## 14. Command loop

The host preserves input order for each session. Mica processes one normalized input item at a time.

The command loop performs these operations:

1. It validates the session, frame, window, and input shape.
2. It validates the selected window and expected buffer revision.
3. It updates the pending key sequence.
4. It resolves a prefix or a complete command.
5. It resolves the numeric prefix argument.
6. It sets `ThisCommand`.
7. It invokes pre-command hooks.
8. It invokes the command selector.
9. It invokes post-command hooks.
10. It copies `ThisCommand` to `LastCommand`.
11. It clears completed prefix state.
12. It returns the authoritative result.

A prefix key returns `:prefix` and does not run a command. The browser shows the pending sequence in
the echo area.

`C-g` always invokes `keyboard-quit`. It clears the pending sequence, prefix argument, transient
keymap, active mark, and minibuffer request that permits cancellation.

An unknown complete sequence returns `:undefined`. It clears prefix state and rings the browser
bell through a browser operation.

The numeric argument state is `none`, a sign, or an integer. `C-u` starts with 4. Repeated `C-u`
multiplies the value by 4. `M--` starts a negative argument. Digits replace the initial `C-u` value
and extend the current integer.

The command receives `none` if no numeric argument exists. It receives the signed integer in every
other case. The command loop clears the argument after a complete command or `C-g`.

Expected command errors return a value and commit no text change. The host result advances the
client sequence and contains `:rejected`, an error code, and an authoritative state summary.

`editor_input` catches application errors at its outer boundary. The host converts an unexpected
runtime abort to `:rejected`. The host must never wait forever after it admits a sequence.

## 15. Key representation and normalization

A normalized key chord is a string. These examples define the syntax:

```text
a
C-a
M-x
C-M-f
S-<left>
<f5>
<escape>
```

Modifier order is `C-`, `M-`, `S-`, and `s-`. The lowercase `s-` prefix means the Super modifier.
Named keys use angle brackets.

Printable text does not come from `keydown`. It comes from `beforeinput` or the composition path.
This rule preserves keyboard layouts, dead keys, and input methods.

The browser handles key events with these rules:

- It ignores command routing while `event.isComposing` is true.
- It treats `AltGraph` as text input, not as `C-M-`.
- It uses `event.key` for logical keys.
- It retains `event.code` only for optional physical-key bindings.
- It sends `repeat` for repeated command keys.
- It calls `preventDefault` only for a known active binding or prefix.
- It does not call `preventDefault` for an unbound browser shortcut.

One browser action must create one input item. For a known command key, `keydown` sends a `key`
item and prevents the default action. Its related `beforeinput` event must not create another item.

For an ordinary printable key, `keydown` sends nothing. The later `beforeinput` event sends one
`input` item. A `paste` event sends one `paste` item and suppresses its related `beforeinput` event.

Mobile input can produce `beforeinput` without `keydown`. The browser sends that edit intent through
the same `input` item path.

The default modifier mapping is configurable by platform. On macOS, Option maps to Meta and Command
maps to Super. On other platforms, Alt maps to Meta.

## 16. Keymaps

Keymaps are Mica data:

```mica
make_relation(:editor/Keymap, 1)
make_functional_relation(:editor/KeyBinding, 3, [0, 1])
make_relation(:editor/KeyPrefix, 2)
make_functional_relation(:editor/GlobalKeymap, 2, [0])
make_functional_relation(:editor/BufferMinorMode, 3, [0, 1])
make_functional_relation(:editor/TransientKeymap, 2, [0], :volatile)
make_functional_relation(:editor/SessionPlatformProfile, 2, [0], :volatile)
make_relation(:editor/PlatformReservedKey, 2)
make_functional_relation(:editor/CommandAlternative, 3, [0, 1])
make_functional_relation(:editor/InputCommand, 2, [0])
```

`KeyBinding(keymap, sequence, command)` maps one normalized sequence to one command.
`KeyPrefix(keymap, sequence)` records a valid prefix. `GlobalKeymap(:default, keymap)` selects the
global map. `BufferMinorMode(buffer, mode, priority)` records an active minor mode and its order.

`PlatformReservedKey(profile, sequence)` comes from host configuration.
`CommandAlternative(command, profile, sequence)` records the Mica-owned fallback.
`InputCommand(input_type, command)` maps a browser edit intent to a Mica command.

The binding helper rejects these errors:

- one sequence bound to two commands in one keymap.
- a sequence that is both a complete binding and a prefix in one keymap.
- an unknown command.
- an invalid normalized chord.
- a sequence with more than sixteen chords.

The active maps use this precedence:

1. the session transient keymap.
2. active minor-mode maps, in explicit priority order.
3. the selected buffer major-mode map.
4. the global map.

Mica increments `KeymapGeneration` after each change that affects the active maps. The browser plan
includes this generation.

The browser can predict only a binding from the current plan. The server resolves the same raw key
sequence again. A generation mismatch disables prediction and returns a new plan.

## 17. Default command set

The initial default map must contain these command families:

| Family | Commands and bindings |
| --- | --- |
| Character movement | `C-f`, `C-b`, `<right>`, `<left>` |
| Line movement | `C-n`, `C-p`, `<down>`, `<up>` |
| Line bounds | `C-a`, `C-e`, `<home>`, `<end>` |
| Word movement | `M-f`, `M-b` |
| Buffer movement | `M-<`, `M->`, `M-g g` |
| Scrolling | `C-v`, `M-v`, `C-l` |
| Deletion | `C-d`, Backspace, `M-d`, `M-Backspace` |
| Kill and yank | `C-k`, `C-w`, `M-w`, `C-y`, `M-y` |
| Mark | `C-<space>`, `C-x C-x` |
| Undo | `C-/`, `C-_`, `C-x u` |
| Newlines and quoting | `C-j`, `C-m`, `C-o`, `C-q` |
| Transpose and case | `C-t`, `M-t`, `M-l`, `M-u`, `M-c` |
| Files | `C-x C-f`, `C-x C-s`, `C-x C-w` |
| Buffers | `C-x b`, `C-x k`, `C-x C-b` |
| Windows | `C-x 0`, `C-x 1`, `C-x 2`, `C-x 3`, `C-x o` |
| Commands | `M-x`, `C-g`, `C-u`, `M-0` through `M-9` |
| Search | `C-s`, `C-r` |
| Help | `C-h k`, `C-h f`, `C-h b` |
| Session | `C-x C-c` |

`C-x C-c` prompts for modified buffers, ends the editor session, and shows a closed-session page.
It does not claim that JavaScript can close a browser tab.

The browser compatibility document must list keys that the browser or operating system reserves.
The initial list must test `C-n`, `C-p`, `C-q`, `C-r`, `C-s`, `C-t`, `C-w`, and `C-l` on each
supported platform.

Mica stores alternative bindings for each supported platform profile. Host configuration reports
unavailable chords. JavaScript does not select the alternative command.

### 17.1 Core command behavior

Movement commands use scalar positions. A positive numeric argument repeats forward movement. A
negative argument uses the opposite direction. A missing argument means one.

Vertical movement stores the initial logical column in `WindowGoalColumn`. Repeated vertical
movement uses that column and clamps on shorter lines. A nonvertical command clears the goal
column.

`beginning-of-line` moves after the previous newline. `end-of-line` moves before the next newline.
Buffer-bound commands move to scalar zero or `buffer_len(buffer)`.

Fundamental-mode words contain Unicode letters, Unicode numbers, and underscore. A major mode can
provide a different word predicate through its command selectors.

`self-insert-command` inserts the input text once for each positive argument. A negative or zero
argument rejects the command. Newline commands insert `"\n"` into the normalized buffer text.

Backward and forward deletion remove a scalar or word in the requested direction. If the region is
active, a region-aware deletion command removes the region instead.

`kill-line` without an argument kills text through the logical line end. At the line end, it kills
the newline. Consecutive forward kills append, and consecutive backward kills prepend.

`set-mark-command` stores point as the mark and activates it. `exchange-point-and-mark` exchanges
the two positions and activates the mark. A text command deactivates the mark unless its command
metadata says to keep it active.

Every text command checks `BufferReadOnly` before it creates an edit plan. A read-only failure is a
`rejected` result and changes no point, mark, undo, or kill-ring state.

`keyboard-quit` is always available, including during a prefix, search, or minibuffer request. It
does not modify buffer text.

## 18. Browser operation plans

Mica sends a plan for the active keymaps. A plan contains normalized sequences, command identities,
predictors, barriers, and its generation.

The browser supports only these predictors:

```text
:insert_text
:delete_backward_scalar
:delete_forward_scalar
:move_backward_scalar
:move_forward_scalar
:move_logical_line_up
:move_logical_line_down
:move_line_start
:move_line_end
:set_point
:extend_selection
:scroll_lines
:none
```

A predictor changes provisional state only. It never changes the authoritative buffer.

The browser must wait for a result after a barrier command. It queues later input without applying
predictions until that result arrives.

The browser must also stop prediction after any error, sequence gap, revision mismatch, keymap
generation mismatch, or unsupported operation.

## 19. Editor input protocol

The browser posts editor input to `/editor/input`. The request content type is
`application/json`. The existing HTTP body limit also applies.

One request contains one or more ordered input items:

```json
{
  "type": "editor_input",
  "session": "41",
  "frame": "1",
  "items": [
    {
      "sequence": "93",
      "depends_on": "92",
      "window": "3",
      "buffer": "editor/buffer/17",
      "base_revision": "28",
      "keymap_generation": "6",
      "kind": "text",
      "text": "a"
    }
  ]
}
```

The protocol uses decimal strings for every `u64`. The buffer field contains an interned symbol
name. The host rejects unknown buffer symbols before dispatch.

Scalar offsets are JSON integers from zero through `9007199254740991`. The host rejects larger
values. This limit keeps every scalar position exact in JavaScript.

An item kind is one of:

| Kind | Required payload |
| --- | --- |
| `text` | `text` |
| `key` | `key`, `code`, `modifiers`, `repeat` |
| `input` | `input_type`, optional `text` |
| `paste` | `text` |
| `pointer` | `scalar_offset`, `extend` |
| `select_window` | `window` |
| `resize_split` | `split`, `ratio` |
| `viewport` | `first_line`, `line_count`, `width`, `height` |
| `focus` | `focused` |

Each item represents one input intent or one key chord. A request batch is a transport batch only.
The host invokes Mica separately for each item and does not combine their transactions.

A `text` item routes to `self-insert-command`. A `paste` item routes to
`clipboard-yank-command`. A `key` item enters keymap resolution.

An `input` item carries a browser edit intent from `beforeinput` or composition. Supported values
include `insertText`, `insertCompositionText`, `deleteContentBackward`,
`deleteContentForward`, and `insertLineBreak`. Mica maps each value to a command. It rejects an
unknown value.

`depends_on` is the preceding client sequence that the item assumes. It is zero for the first item
after a full synchronization.

`base_revision` is the last authoritative revision that the client knew before its pending chain.
Later pending items can retain that revision and depend on earlier sequence numbers.

The host validates the complete batch before admission. New sequences must be contiguous inside the
batch. If all new items fit, the host enqueues them atomically and returns `202 Accepted`.

Completed duplicates use retained results, and admitted duplicates add no queue entry. If any new
item fails validation or capacity checks, the host admits none of the new items. Mica results arrive
through SSE.

Protocol limits are:

| Limit | Value |
| --- | --- |
| Request body | 256 KiB |
| Items in one request | 256 |
| Text in one item | 64 KiB UTF-8 |
| Pending items in one session | 1024 |
| Pending text in one session | 1 MiB UTF-8 |
| Retained result messages | 256 per session |
| Key chords in one sequence | 16 |

The host returns `413` for a body limit. It returns `429` for a session queue limit. Neither error
changes Mica state.

## 20. Editor result protocol

The existing `/sync/events` connection carries a second SSE event type:

```text
event: editor
data: {...}
```

The session output queue stores a tagged union of sync envelopes and editor results. The existing
queue bound applies to the combined traffic.

The host uses this concrete queue value:

```odin
Session_Output :: union {
    Sync_Envelope,
    Editor_Result,
}
```

A successful result has this shape:

```json
{
  "type": "editor_result",
  "status": "ok",
  "session": "41",
  "through_sequence": "93",
  "buffer": "editor/buffer/17",
  "base_revision": "28",
  "revision": "29",
  "edits": [{"at": 12, "remove": 0, "text": "a"}],
  "window": {
    "id": "3",
    "point": 13,
    "mark": null,
    "mark_active": false,
    "first_line": 0,
    "horizontal_offset": 0
  },
  "keymap_generation": "6",
  "browser_operations": []
}
```

Status values are:

| Status | Meaning |
| --- | --- |
| `ok` | Mica committed the command. |
| `prefix` | Mica accepted a prefix key and awaits another chord. |
| `undefined` | No active keymap contains the sequence. |
| `rejected` | The command returned an application or authority error. |
| `resync` | The client must remove provisional state and request a snapshot. |

Every result advances `through_sequence`. A rejected item does not block later sequence numbers.
Each `rejected` or `resync` result includes an error code and `retry_safe` boolean.

`retry_safe` is true only if the host knows that the original item changed no state. A sequence gap,
lost result ledger, or unknown task outcome sets it to false.

If its generation differs from the client generation, a result includes a new keymap plan. A
barrier result also includes the current frame tree, frame generation, and selected window.

The host calls the fixed Mica selector `editor_input_json`. It supplies the endpoint, session,
actor, frame, input text, client token, and known keymap generation.

For a text change, `editor_input_json` commits the staged change. It then calls
`editor_input_result` before the Mica execution ends. This selector reads
`buffer_apply_result(client_token)` and creates the authoritative editor result. Thus, one input
item needs one Mica execution.

The finalizer maps buffer `ok` to the committed revision and authoritative `applied` delta. It maps
buffer `resync` and `conflict` to editor `resync`. It maps buffer `aborted` to editor `rejected`.
Each non-`ok` result contains the original buffer status as its error code.

For a command without a text change, the complete `editor_input_json` value is authoritative.
The host converts an unexpected task abort to `rejected`. It retains every result before it queues
the SSE event.

The host allocates client tokens from a process-wide `u64` counter. It never reuses a token during
the process lifetime. Client tokens do not come from the browser.

The browser never supplies a selector. It supplies only the normalized item and its expected
state. Mica performs all keymap lookup and command dispatch.

## 21. Ordered input and duplicate handling

Each session starts with client sequence one. The host records the last admitted sequence and the
last completed sequence.

The host handles a new item as follows:

- The next sequence enters the queue.
- A completed duplicate returns the retained result.
- An admitted duplicate receives no second execution.
- A sequence gap returns `resync`.
- An item with the wrong `depends_on` returns `resync`.
- An item after the queue limit receives `429`.

The host processes one item at a time for each session. Different sessions can process items in
parallel.

The host stores results before it publishes them to SSE. A reconnecting client sends its last
completed sequence. The host replays later retained results in order.

The reconnect URL is `/sync/events?session=<u64>&editor_sequence=<u64>`. The second value is zero if
the client has no completed editor result. Normal sync query fields remain unchanged.

When the result window no longer contains the requested sequence, the host sends a full editor
snapshot.

## 22. Provisional replica algorithm

The browser keeps these values for each visible buffer:

- the last authoritative viewport snapshot.
- the last authoritative buffer revision.
- an ordered list of pending input items.
- the predicted edits for each pending item.
- the resulting provisional text and positions.

The browser applies a predictable item with this algorithm:

1. It records the raw input item.
2. It calculates a prediction from the Mica plan.
3. It applies the prediction to the provisional viewport.
4. It paints the new viewport before it sends the request.
5. It appends the item to the pending chain.
6. It sends one request during the next animation frame.

The browser applies a result with this algorithm:

1. It finds all acknowledged items through `through_sequence`.
2. It saves uncommitted text from a failed chain in the recovery queue.
3. It removes the acknowledged items from the pending chain.
4. It applies authoritative edits to the authoritative replica.
5. It compares the result with the acknowledged prediction.
6. It replays remaining predictions from the new authoritative replica.
7. It paints the corrected provisional viewport.

When the authoritative result differs outside the predicted range, the browser requests a full
viewport snapshot. It must not guess a transformation.

For `resync`, the browser removes all dependent predictions and requests a full snapshot. It keeps
their raw input in a recovery queue. This rule prevents lost typing.

If `retry_safe` is true, the recovery UI can resubmit plain insertion and paste items with new
sequence numbers. It must ask before it resubmits deletion, command, or barrier items. If
`retry_safe` is false, it must not resubmit automatically.

The client keeps at most 4096 predicted edits or 1 MiB of predicted text. It stops prediction at
either limit.

## 23. Text input and IME

The editor uses a hidden `textarea` as the platform input target. The visible text remains in the
editor viewport elements.

The hidden control moves near the visible caret. This placement gives mobile and desktop input
methods a useful composition location.

The composition path follows these rules:

1. `compositionstart` begins a browser-only composition overlay.
2. `compositionupdate` changes only that overlay.
3. `beforeinput` events inside the composition do not enter the command path.
4. `compositionend` creates one `input` item with `insertCompositionText` and the final text.
5. A cancellation removes the overlay and sends no text.

Outside composition, `beforeinput` creates one `input` item. This rule applies to insertion,
deletion, and line-break intents. Paste creates one `paste` item and can contain newlines. The
browser must not generate one item for each pasted character.

The browser does not use `contenteditable` as an authoritative text store. Browser DOM mutation,
selection normalization, and spell-check mutation make that model nondeterministic.

## 24. Unicode coordinates

Mica buffer offsets count Unicode scalars. JavaScript string indices and DOM offsets count UTF-16
code units.

Each viewport line stores a conversion table between scalar offsets and UTF-16 offsets. The table
contains one entry for each surrogate-pair boundary and each line boundary.

The browser uses the table for these operations:

- pointer position to scalar position.
- scalar point to DOM range.
- selection bounds.
- provisional edit application.
- horizontal measurement.
- clipboard range extraction.

The browser never sends a UTF-16 offset to Mica. The Mica protocol never returns a UTF-16 offset.

Movement commands operate on scalars. Display code can group scalars into grapheme clusters for
caret painting. The buffer position remains a scalar boundary.

## 25. Viewport rendering

Each editor window has one viewport root with stable data attributes:

```html
<div class="editor-window" data-editor-window="3">
  <div class="editor-viewport" role="textbox" aria-multiline="true"></div>
  <div class="editor-mode-line"></div>
</div>
```

The synchronized DOM renderer creates the roots and mode line. The editor client owns children of
`editor-viewport`.

Each logical line is one stable element. Each face range is a child span. Text must enter through
`textContent`, not HTML.

The viewport requests visible logical lines plus ten overscan lines on each side. It also provides a
scalar budget. A normal request uses at most 400 lines and 256 KiB of UTF-8 text.

The default display uses a monospace font and preserves spaces. Horizontal scrolling is available.
Soft wrapping is a window option, not buffer state.

Logical line movement is authoritative in Mica. If current line measurements are complete, the
browser can predict vertical movement.

A viewport snapshot contains:

- the buffer symbol and revision.
- the first logical line.
- each line start, stop, text, and completion flag.
- face spans inside the returned text.
- point, mark, and active-region state.
- the keymap generation.
- the frame generation.

## 26. Faces, overlays, and diagnostics

Faces and overlays are relational state. They do not change buffer content.

```mica
make_relation(:editor/Face, 1)
make_functional_relation(:editor/FaceClass, 2, [0])
make_relation(:editor/Overlay, 1)
make_functional_relation(:editor/OverlayBuffer, 2, [0])
make_functional_relation(:editor/OverlayStartMarker, 2, [0])
make_functional_relation(:editor/OverlayStopMarker, 2, [0])
make_functional_relation(:editor/OverlayFace, 2, [0])
make_functional_relation(:editor/OverlayPriority, 2, [0])
```

The browser receives CSS class names from `FaceClass`. Mica source must not supply raw style text.
The host page defines the permitted classes.

A bounded computed relation supplies face spans for one viewport. It must require the buffer,
revision, start, stop, and span limit.

The renderer sorts spans by start, stop, priority, and stable overlay id. It clips every span to the
viewport range.

## 27. Undo and redo

Whole-buffer reversion is not editor undo. The editor keeps a separate command journal.

```mica
make_relation(:editor/UndoGroup, 2)
make_functional_relation(:editor/UndoAuthor, 3, [0, 1])
make_functional_relation(:editor/UndoBaseRevision, 3, [0, 1])
make_functional_relation(:editor/UndoNewRevision, 3, [0, 1])
make_functional_relation(:editor/UndoForwardEdits, 3, [0, 1])
make_functional_relation(:editor/UndoInverseEdits, 3, [0, 1])
make_functional_relation(:editor/UndoKind, 3, [0, 1])
make_functional_relation(:editor/UndoCursor, 2, [0])
```

The key is `(buffer, group)`. A group id increases monotonically for one buffer.

Before an edit, `editor/apply_edits` reads every removed range. For one forward edit
`{at, remove, text}`, the inverse edit has this form:

```text
{at, remove: scalar_length(text), text: removed_text}
```

For several view-relative edits, the inverse list uses reverse order. Each inverse position refers
to the view produced by later forward edits.

Adjacent `self-insert-command` operations from one session can share one undo group. A different
command closes that group. A barrier command also closes it.

Undo applies the newest eligible inverse group. Redo applies the corresponding forward group. A new
ordinary edit after undo removes the redo tail.

The normal editor uses `:reject`, so a concurrent change causes a revision mismatch before undo. The
editor then refuses incremental undo and shows a conflict message.

The editor command path rejects `:span` buffers. A future shared mode needs transformed selective
undo and ordered post-commit marker rebasing. It must add both contracts before it enables editing.

The undo journal uses a configurable byte limit and group limit. Defaults are 16 MiB and 1000 groups
for each buffer. The editor removes the oldest complete groups first.

## 28. Kill ring and registers

The kill ring is session state. A kill entry contains text and its source kind.

```mica
make_functional_relation(:editor/KillEntry, 3, [0, 1], :volatile)
make_functional_relation(:editor/KillHead, 2, [0], :volatile)
make_functional_relation(:editor/Register, 3, [0, 1])
make_relation(:editor/Bookmark, 1)
make_functional_relation(:editor/BookmarkOwner, 2, [0])
make_functional_relation(:editor/BookmarkName, 2, [0])
make_functional_relation(:editor/LiveBookmarkName, 3, [0, 1])
make_functional_relation(:editor/BookmarkBuffer, 2, [0])
make_functional_relation(:editor/BookmarkFilePath, 2, [0])
make_functional_relation(:editor/BookmarkMarker, 2, [0])
```

The key for `KillEntry` is `(session, index)`. The default ring keeps 60 entries.

Consecutive kill commands append to the current entry according to command direction. A non-kill
command closes the current entry.

`yank` inserts the head entry and records its inserted range. `yank-pop` is valid only after `yank`
or `yank-pop`. It replaces that range with the next entry.

Registers use `(actor, name, value)` and are durable. A register can contain text, a scalar
position, a file path, or a window configuration.

Bookmarks are durable. `LiveBookmarkName(actor, name, bookmark)` keeps each actor's names unique. A
bookmark stores a marker in a live buffer and can also store its canonical file path.

If its original buffer is not live, jumping to a file bookmark visits the file and creates a new
marker. A bookmark without a live buffer or file path reports `bookmark-target-missing`.

## 29. Minibuffer and completion

The minibuffer is a dedicated volatile buffer and a dedicated window area. It does not replace the
selected editor window in the frame tree.

```mica
make_relation(:editor/MinibufferRequest, 2, :volatile)
make_functional_relation(:editor/MinibufferPrompt, 3, [0, 1], :volatile)
make_functional_relation(:editor/MinibufferBuffer, 3, [0, 1], :volatile)
make_functional_relation(:editor/MinibufferContinuation, 3, [0, 1], :volatile)
make_functional_relation(:editor/MinibufferCompletionKind, 3, [0, 1], :volatile)
make_functional_relation(:editor/ActiveMinibuffer, 2, [0], :volatile)
make_functional_relation(:editor/HistoryEntry, 4, [0, 1, 2], :volatile)
make_functional_relation(:editor/HistoryHead, 3, [0, 1], :volatile)
```

Commands that need input create a request and return a barrier result. Later input uses the
minibuffer keymap.

`minibuffer-complete-and-exit` validates the input and invokes the stored continuation selector.
The continuation receives the request id and accepted value.

This model stores continuation data, not a suspended VM stack. A disconnect can therefore remove a
prompt without retaining a task.

Completion is a bounded computed relation. The request specifies a completion kind, query text,
limit, and cursor. Completion kinds include command, buffer, file, variable, and mode.

Minibuffer histories use `(session, kind, index, value)`. Each history retains 100 entries and 256
KiB of text. It removes the oldest complete entries first.

`M-x` queries command names and returns command identities. The browser never turns minibuffer text
directly into a selector.

## 30. Modes, hooks, and local values

A major mode and a minor mode are identities with Mica-owned behavior.

```mica
make_relation(:editor/MajorMode, 1)
make_relation(:editor/MinorMode, 1)
make_functional_relation(:editor/ModeName, 2, [0])
make_functional_relation(:editor/ModeParent, 2, [0])
make_functional_relation(:editor/ModeKeymap, 2, [0])
make_relation(:editor/ModeHook, 3)
make_functional_relation(:editor/BufferLocalValue, 3, [0, 1])
make_functional_relation(:editor/SessionLocalValue, 3, [0, 1], :volatile)
```

Hook order uses an explicit integer priority and a stable hook identity. The editor sorts by
priority and identity.

Required hooks are:

- before-command.
- after-command.
- buffer-created.
- buffer-killed.
- major-mode-changed.
- before-save.
- after-save.
- window-selection-changed.

Pre-command and post-command hooks must not call raw buffer mutation builtins. A hook that needs a
text change must add edits to the command edit plan.

Buffer-local values use `(buffer, variable, value)`. Session-local values use
`(session, variable, value)`.

The editor starts with `fundamental-mode`. File name rules and optional content rules select another
mode during file visitation.

### 30.1 Live Mica changes

The editor must support changing its Mica program from inside the editor. This support has two
surfaces with different safety rules.

`eval-expression` and `eval-region` call the capability-gated host service `editor_eval_source`.
The service calls the existing `world_eval` API as the session actor. It returns the complete value
or a structured compile and runtime error to an editor result buffer.

Ad hoc evaluation does not replace a loaded filein unit. The current runtime records unit source,
but it does not own and replace all definitions from that unit. Re-evaluating a package is not a
safe update mechanism.

Add a runtime operation named `world_replace_unit` for repeatable package updates. Its input is the
actor, unit identity, source text, and expected unit generation. It returns the new generation and
the compiler diagnostics.

`world_replace_unit` must provide these guarantees:

- It compiles and validates all new source before it changes the world.
- It records the executable rules and methods owned by the unit.
- It rejects an incompatible relation schema change.
- It removes the old owned definitions and installs the new definitions atomically.
- It updates `UnitSource` and the unit generation in the same commit.
- It leaves the old unit active after any compile, validation, or commit error.
- Existing tasks finish with their captured code generation.
- New dispatches use the new generation after the commit.

Schema and durable data migrations are separate named commands. A unit replacement must not erase
facts as an implicit side effect.

The Mica command `load-editor-unit` calls a capability-gated host wrapper around
`world_replace_unit`. Mica checks `CanReplaceUnit(actor, unit)` before it requests the operation.
The browser never submits source directly to the runtime API.

Each successful replacement increments the keymap generation for affected sessions. It also sends
a barrier result. This behavior prevents old browser plans from predicting new command behavior.

## 31. File service

File access is a host capability. Mica owns visit, save, conflict, and prompt policy.

The editor calls these external services:

```text
editor_file_read
editor_file_write_atomic
editor_file_stat
editor_file_list
editor_file_watch
```

`editor_file_read` returns:

```mica
{
  :path -> canonical_path,
  :text -> text,
  :stamp -> {:size, :modified_ns, :content_hash},
  :encoding -> "utf-8",
  :line_ending -> :lf
}
```

The first implementation accepts UTF-8 only. It reports a decoding error for invalid UTF-8. It
does not replace invalid input.

The reader detects LF and CRLF endings. It stores LF text in the buffer and records the detected
style in `BufferLineEnding`. The writer restores that style during save.

`editor_file_write_atomic` requires the expected stamp. The host writes a temporary file in the
same directory, flushes it, and renames it over the destination. It then flushes the parent
directory. For a new file, the expected stamp is `none`.

When the expected stamp does not match, the host returns `:changed`. Mica then asks the user before
it overwrites or reloads the file.

File metadata uses these relations:

```mica
make_functional_relation(:editor/BufferFilePath, 2, [0])
make_functional_relation(:editor/LiveFileBuffer, 2, [0])
make_functional_relation(:editor/BufferFileStamp, 2, [0])
make_functional_relation(:editor/BufferFileEncoding, 2, [0])
make_functional_relation(:editor/BufferLineEnding, 2, [0])
```

`LiveFileBuffer(canonical_path, buffer)` permits one live buffer for each canonical path. File
visitation checks this relation before it reads the file.

`BufferSavedRevision` records the revision from the last successful load or save. If the current
revision differs from this revision, the buffer is modified.

The host restricts paths to configured workspace roots. It resolves symbolic links before the
authority decision. It repeats the containment check before replacement. It never accepts a
browser-supplied root.

## 32. Clipboard and browser services

Clipboard access must occur after a browser user gesture. Mica returns one browser operation that
requests a clipboard read or write.

A clipboard read result returns as a new ordered input item. Mica then decides whether to insert its
text.

Browser operations use an allowlist:

```text
:focus_window
:focus_minibuffer
:clipboard_read
:clipboard_write
:set_document_title
:ring_bell
:download
:open_safe_url
```

The browser rejects every unknown operation. URL operations accept only schemes and origins from
host configuration.

## 33. Process service

Mica owns process policy and process-buffer behavior. Odin owns operating-system process handles and
nonblocking I/O.

The generic process service accepts a program, argument list, working directory, environment
allowlist, input mode, output limit, and timeout.

The service returns an unguessable process token bound to the actor and session. Output arrives
through a bounded mailbox as stdout, stderr, exit, and error events.

Each output event contains the token, a monotonic event number, a byte string, and a stream kind.
The exit event contains the process status. Duplicate event numbers are ignored.

Mica appends output to a volatile process buffer. It applies an output byte limit and retains a
truncation marker after it removes old text.

The process service does not accept a shell command string. It accepts a program and an argument
list.

Host configuration supplies the permitted programs, roots, environment names, process count, and
output limits. Session cleanup terminates its remaining processes after a configurable grace time.

## 34. Search

Incremental search uses an explicit session search state:

```mica
make_functional_relation(:editor/SearchBuffer, 2, [0], :volatile)
make_functional_relation(:editor/SearchQuery, 2, [0], :volatile)
make_functional_relation(:editor/SearchDirection, 2, [0], :volatile)
make_functional_relation(:editor/SearchOrigin, 2, [0], :volatile)
make_functional_relation(:editor/SearchMatch, 3, [0, 1], :volatile)
```

`C-s` and `C-r` enter a transient search keymap. Text input updates the query. The command uses
`buffer_find` with an explicit scalar limit.

The browser can show a provisional match only inside its current viewport. Mica remains the source
of the accepted match and point.

A failed search keeps the query and returns a bell operation. `C-g` restores the origin and exits
the search state.

## 35. Persistence and recovery

Durable buffers and durable editor metadata recover through the normal world store. Volatile
sessions, windows, prompts, and process buffers do not recover.

```mica
make_functional_relation(:editor/CleanShutdown, 2, [0])
```

`CleanShutdown(:editor, value)` stores the world-level shutdown marker.

The editor records a durable clean-shutdown marker. At startup, it reads and clears this marker in
one transaction. If the marker was absent, the editor lists modified buffers in a recovery view.

During an orderly shutdown, the host stops new input and drains admitted commands. It then writes
the marker and completes the normal world checkpoint.

Buffer catalogue entries and editor metadata remain durable even if buffer text is volatile. Before
it accepts a session, startup retires old process, search, completion, and minibuffer buffers.

The shared marker relations are also durable. Startup removes marker ids whose first structural
field names a session that no longer exists. Normal session cleanup performs the same removal.

File buffers compare their saved stamp with the current file stamp after restart. The editor uses
these rules:

- An equal stamp reopens the recovered buffer normally.
- A changed file and an unmodified buffer reload from disk.
- A changed file and a modified buffer open a conflict view.
- A missing file keeps the recovered text and marks the buffer as orphaned.

The editor does not silently replace recovered unsaved text.

Window configurations are session state by default. A separate desktop-save command can store a
serializable window tree and reopen it in a new session.

## 36. Authority and trust boundaries

The browser is untrusted. It can request an operation, but it cannot grant itself authority.

The host authenticates the web session before it admits editor input. It binds every Mica task to
the session actor.

The host exposes only these editor service selectors:

```text
editor_file_read
editor_file_write_atomic
editor_file_stat
editor_file_list
editor_file_watch
editor_process_start
editor_process_write
editor_process_signal
editor_eval_source
editor_replace_unit
```

Each service checks the task actor and its configured capability. A browser request cannot invoke
these services directly.

Mica validates these values again:

- the session id.
- the selected frame and window.
- the buffer shown in the window.
- the expected buffer revision.
- the keymap generation.
- command invocation authority.
- buffer read and write authority.

The client sends raw input, not command selectors. This rule prevents a forged message from
bypassing keymaps or command availability.

File roots, process programs, environment names, URL origins, and download sizes come from host
configuration. Mica policy can narrow those sets. Browser input cannot widen them.

The editor must escape all text through DOM text nodes. Face definitions select approved CSS
classes. They do not contain raw HTML or CSS.

## 37. Subscription integration

The sync view dependency format must accept the `:buffer` subject. A buffer dependency has this
shape:

```mica
{
  :subject -> :buffer,
  :relation -> some(buffer),
  :bindings -> []
}
```

The host registers it through the existing buffer change feed. A buffer change marks only windows
that show that buffer.

Editor viewport updates normally use editor results, not DOM rerenders. Buffer subscriptions cover
changes from other tasks and other sessions.

The host processes buffer changes in revision order. For a change outside an editor command, it
calls the fixed Mica selector `editor_buffer_changed`. The roles are `endpoint`, `buffer`,
`base_revision`, `new_revision`, and `edits`.

`editor_buffer_changed` calls `buffers/markers_rebase`. A marker already at `new_revision` makes
delivery idempotent. A marker at another revision reports a missed delta and forces
resynchronization.

When a buffer change has an unbroken delta chain, the host sends the delta through the editor SSE
path. When the chain is incomplete, the host sends `resync` for each affected window.

## 38. Backpressure and resource limits

All limits are configuration values with these defaults:

| Resource | Default |
| --- | --- |
| Sessions | 256 |
| Frames in one session | 1 |
| Windows in one frame | 64 |
| Live buffers in one world | 4096 |
| Markers for one buffer | 100000 |
| Session markers in one session | 10000 |
| Input items in one session queue | 1024 |
| Output messages in one session queue | 128 |
| Input request bytes | 256 KiB |
| One text item | 64 KiB |
| One viewport | 400 lines and 256 KiB |
| Pending provisional text | 1 MiB |
| Undo data for one buffer | 16 MiB |
| Undo groups for one buffer | 1000 |
| Kill-ring entries | 60 |
| Key chords in one sequence | 16 |
| Completion rows | 200 |

When an input queue is full, the host returns `429`. It does not remove an older input item.

When an output queue is full, the host replaces pending viewport deltas with one `resync` marker. It
does not remove command results that advance client sequence state.

When command results alone fill the output queue, the host closes the editor stream. The client
reconnects and requests replay or a full snapshot.

## 39. Error model

Protocol errors use HTTP status codes before queue admission:

| Status | Meaning |
| --- | --- |
| `400` | Invalid JSON or invalid field. |
| `401` | No valid session. |
| `403` | Actor or authority mismatch. |
| `409` | Session identity conflict. |
| `413` | Request exceeds a byte limit. |
| `429` | Session queue is full. |

Command errors use editor result status after admission. Each result contains an error code, a short
message, and an authoritative state summary.

The browser handles errors with these rules:

- `undefined` rings the bell and keeps authoritative text.
- `rejected` removes the rejected prediction and replays later safe predictions.
- `resync` moves dependent raw input to recovery, removes its predictions, and requests a snapshot.
- A disconnected stream stops new predictions after the pending limit.
- A protocol decoding error closes the editor stream.

The browser must not retry non-idempotent input with a new sequence number unless a result sets
`retry_safe`. Without that result, it reconnects and asks about the original sequence.

## 40. Observability

The host records bounded timing entries for these operations:

- input decode.
- queue wait.
- Mica command execution.
- transaction commit.
- result encode.
- SSE queue wait.
- browser result application.
- provisional paint.
- viewport paint.
- resynchronization.

Each entry includes the session, client sequence, command identity, buffer revision, byte count, and
result status. Logs must not contain buffer text or clipboard text by default.

The browser appends timing entries to the existing `__micaSyncTimings` buffer with an `editor_`
prefix. It retains at most 2000 combined entries.

Metrics include queue depth, rejected input count, resynchronization count, provisional correction
count, viewport bytes, command duration, and commit duration.

## 41. Performance requirements

The following requirements apply on a development workstation:

- Input capture to provisional paint has a 95th percentile below 16 ms.
- The browser does not wait for an HTTP response before provisional paint.
- A one-scalar insertion does not render the complete buffer.
- A viewport request does not read outside its scalar budget.
- Opening a 10 MiB buffer does not send 10 MiB to the browser.
- A 100 ms simulated network delay does not stop ordinary predictable typing.
- An editor window keeps at most one rendered viewport and bounded overscan.
- A hidden window does not receive viewport text.

Correctness has priority over prediction. When prediction is unsafe, the browser waits for Mica.

## 42. Required tests

### 42.1 Buffer and command tests

Tests must cover:

- display-name reuse with different internal buffer names.
- buffer retirement without catalogue-name reuse.
- point and mark rebasing after insert, delete, and replace.
- two windows with independent points on one buffer.
- split and deletion tree invariants.
- command dispatch and authority.
- prefix keys and undefined sequences.
- positive and negative numeric arguments.
- keymap precedence and generation changes.
- platform fallback bindings without JavaScript command policy.
- undo, redo, coalesced insertion, and redo-tail removal.
- kill append direction and `yank-pop` restrictions.
- minibuffer acceptance and cancellation.
- file stamp conflicts and recovery choices.
- successful live unit replacement and generation changes.
- failed live unit replacement with the old unit still active.

### 42.2 Protocol tests

Tests must cover:

- valid message decoding.
- every missing required field.
- invalid decimal integers.
- negative and overflowing numbers.
- scalar offsets above the exact JavaScript integer limit.
- body, item, text, and queue limits.
- duplicate sequence replay.
- admitted duplicate suppression.
- sequence gaps.
- incorrect `depends_on` values.
- buffer result finalization after commit, conflict, resync, and abort.
- reconnect replay.
- replay-window exhaustion.
- mixed sync and editor SSE output.
- output backpressure without lost command results.

### 42.3 Browser tests

Node tests with a fake DOM must cover:

- scalar and UTF-16 conversion.
- surrogate pairs and combining marks.
- provisional insertion, deletion, and movement.
- authoritative results that match predictions.
- authoritative results that correct predictions.
- replay of remaining predictions.
- recovery of raw input after `resync`.
- barrier behavior.
- IME commit and cancellation.
- paste as one item.
- key normalization on macOS and other platforms.
- `AltGraph` behavior.
- one input item for each key, paste, deletion, and composition action.
- focus retention after viewport patches.
- clipboard operation allowlists.

### 42.4 End-to-end tests

End-to-end scenarios must cover:

- typing with 100 ms simulated result delay.
- rapid input that spans several HTTP requests.
- server restart with unsaved durable text.
- two browser sessions on one buffer.
- a stale revision during a pending chain.
- a keymap change during pending input.
- a buffer change from a non-editor task.
- stream disconnect and replay.
- stream disconnect after replay-window exhaustion.
- a 10 MiB buffer with a small viewport.
- a one-line buffer larger than the viewport scalar budget.

Property tests must compare the provisional replica with a reference string after random edit and
acknowledgement sequences.

## 43. Acceptance criteria

The implementation is acceptable if all statements in this section are true:

- Mica source defines every default key binding and command selector.
- JavaScript contains no editor command table.
- Ordinary typing paints before the server result.
- An authoritative result can correct provisional text without data loss.
- Point, mark, and selection survive edits through scalar coordinates.
- Two windows can show one buffer with independent points.
- An edit updates every visible window that shows its buffer.
- Only the selected window shows the cursor.
- A click in an inactive window selects that window. A click outside its text does not move point.
- A divider drag updates its Mica split ratio.
- `C-x 2`, `C-x 3`, `C-x 0`, `C-x 1`, and `C-x o` update the Mica split tree.
- `C-x b` and `C-x k` use display names without catalogue-name reuse.
- `M-x` resolves only registered command identities.
- Live unit replacement is atomic and invalidates affected browser plans.
- Undo uses command groups and does not call `buffer_revert`.
- File save detects an external file change before replacement.
- The browser never sends UTF-16 offsets to Mica.
- Every input and output queue has a tested bound.
- A reconnect produces ordered replay or an explicit full resynchronization.
- The generic synchronized DOM apps continue to work without the editor client.

## 44. Dependency constraints

These are implementation dependencies, not product milestones:

- The browser replica depends on the ordered editor protocol and retained results.
- Cursor movement and viewport rendering depend on bounded buffer navigation builtins.
- Browser prediction depends on Mica keymap plans and authoritative command results.
- Window rendering depends on a valid Mica split tree and frame generation.
- File and process commands depend on capability-gated host services.
- Repeatable live package updates depend on `world_replace_unit`.

All work must preserve the contracts in this document. Missing Mica or host primitives do not
justify moving editor policy into JavaScript.

## 45. Explicit non-goals

The design does not include these features:

- Emacs Lisp evaluation or package compatibility.
- terminal rendering.
- pixel-identical GNU Emacs redisplay.
- unrestricted browser HTML or CSS from Mica.
- unbounded file, process, viewport, undo, or completion data.
- transparent selective undo across overlapping shared edits.
- a CRDT.
- browser ownership of commands, modes, or keymaps.
- one transaction that edits several text buffers interactively.
- arbitrary shell command strings.
- implicit replacement of recovered unsaved text.

These exclusions keep the language and authority boundary clear. They do not reduce the goal of a
Mica-programmable editor with Emacs behavior.
