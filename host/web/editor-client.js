// Browser editor client: input normalization, provisional display, and
// viewport painting.
//
// The host slice of the editor protocol. It sends one normalized item per
// request, in order, and repaints from the authoritative snapshot Mica
// returns. Typing is painted locally first and reconciled when the result
// arrives, so a slow link does not make the keyboard feel dead; provisional
// text is never authoritative and the authoritative snapshot always wins.
//
// What lives here and nowhere else: platform key events, the composition path,
// clipboard access after a user gesture, and painting text into DOM nodes.
// Keymaps, commands, modes, and buffer policy all live in Mica.
//
// The platform input target is a hidden textarea: the visible text lives in
// the viewport elements, and the textarea exists only so `beforeinput`,
// composition, and paste fire where input methods expect them.

const SNAPSHOT_LINES = 200;
const SNAPSHOT_SCALARS = 262144;
const REQUEST_TIMEOUT_MS = 15000;

const NAMED_KEYS = {
  ArrowLeft: "<left>",
  ArrowRight: "<right>",
  ArrowUp: "<up>",
  ArrowDown: "<down>",
  Enter: "<return>",
  Backspace: "<backspace>",
  Delete: "<delete>",
  Home: "<home>",
  End: "<end>",
  Escape: "<escape>",
  " ": "<space>",
  Tab: "<tab>",
};

// Keys that must not reach the browser even when unmodified.
const SWALLOWED = new Set([
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "ArrowDown",
  "Enter",
  "Backspace",
  "Tab",
]);

// The chord one keydown event denotes. Plain printable keys return null unless
// `force` asks for them: as text they must come from `beforeinput`, but as the
// next chord of a pending prefix they are keys.
export function chordFor(event, isMac, force = false) {
  const mods = [];
  if (event.ctrlKey) mods.push("C");
  if (event.altKey) mods.push("M");
  if (isMac && event.metaKey) mods.push("s");
  const named = NAMED_KEYS[event.key];
  let base = named;
  if (!base && event.key.length === 1) {
    base = event.key;
    if (event.ctrlKey || event.altKey) base = base.toLowerCase();
  }
  if (!base) return null;
  if (event.shiftKey && !named && base.length === 1 && base.toLowerCase() !== base.toUpperCase()) {
    mods.push("S");
    base = base.toLowerCase();
  }
  if (mods.length === 0 && !named && !force) return null;
  return mods.map((mod) => mod + "-").join("") + base;
}

// Scalars in `text` before UTF-16 offset `utf16`.
export function scalarPrefixLength(text, utf16) {
  let scalars = 0;
  for (let index = 0; index < utf16 && index < text.length; ) {
    const code = text.codePointAt(index);
    index += code > 0xffff ? 2 : 1;
    scalars += 1;
  }
  return scalars;
}

// Converts a Unicode scalar column to the UTF-16 offset JavaScript strings
// and DOM ranges use.
export function utf16OffsetForScalar(text, scalar) {
  let utf16 = 0;
  let count = 0;
  while (utf16 < text.length && count < scalar) {
    const code = text.codePointAt(utf16);
    utf16 += code > 0xffff ? 2 : 1;
    count += 1;
  }
  return utf16;
}

function scalarLength(text) {
  return Array.from(text).length;
}

function randomSessionId(cryptoImpl = globalThis.crypto) {
  if (cryptoImpl && typeof cryptoImpl.getRandomValues === "function") {
    const words = new Uint32Array(2);
    cryptoImpl.getRandomValues(words);
    // Keep the value within Mica's exact positive integer range.
    const value = (BigInt(words[0] & 0x001fffff) << 32n) | BigInt(words[1]);
    return String(value || 1n);
  }
  return String(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER) + 1);
}

// UTF-16 offset within a line element, by walking its child nodes. A click in
// the blank area to the right of the text belongs to the line element itself
// and resolves to the line's end.
export function utf16OffsetInLine(line, node, offset) {
  if (node === line) return line.textContent.length;
  let total = 0;
  for (const child of line.childNodes) {
    if (child === node) return total + offset;
    total += child.textContent.length;
  }
  return null;
}

// Applies not-yet-acknowledged insertions to a copy of `rows`, returning the
// text and caret the server state will settle at. Only used for display.
export function replayInsertions(rows, line, column, texts) {
  const copy = rows.map((row) => ({ ...row }));
  for (const text of texts) {
    const index = copy.findIndex((row) => row.line === line);
    if (index < 0) return { rows: copy, line, column };
    if (text.includes("\n")) {
      const parts = text.split("\n");
      const utf16 = utf16OffsetForScalar(copy[index].text, column);
      const before = copy[index].text.slice(0, utf16);
      const after = copy[index].text.slice(utf16);
      copy[index].text = before + parts[0];
      let insertAt = index + 1;
      for (let part = 1; part < parts.length; part += 1) {
        const last = part === parts.length - 1;
        copy.splice(insertAt, 0, {
          line: line + part,
          start: 0,
          stop: 0,
          text: last ? parts[part] + after : parts[part],
          complete: true,
        });
        insertAt += 1;
      }
      const added = parts.length - 1;
      for (let rest = insertAt; rest < copy.length; rest += 1) copy[rest].line += added;
      line += parts.length - 1;
      column = scalarLength(parts[parts.length - 1]);
      continue;
    }
    const current = copy[index];
    const utf16 = utf16OffsetForScalar(current.text, column);
    current.text = current.text.slice(0, utf16) + text + current.text.slice(utf16);
    column += scalarLength(text);
  }
  return { rows: copy, line, column };
}

// Installs the editor into `root`. Everything the client touches is injected,
// so a DOM stub can drive the real event paths in tests.
export function createEditor(options = {}) {
  const doc = options.document ?? globalThis.document;
  const win = options.window ?? globalThis.window;
  const nav = options.navigator ?? globalThis.navigator ?? {};
  const fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);
  const root = options.root ?? doc.getElementById("mica-editor");
  if (!root) return null;
  const debug = options.debug === true && typeof console !== "undefined" && !!console.debug;

  const session = String(options.session || root.dataset.session || randomSessionId(options.crypto));
  const platform =
    (nav.userAgentData && nav.userAgentData.platform) || nav.platform || "";
  const isMac = /Mac|iPhone|iPad/.test(platform);

  const state = {
    session,
    nextSequence: 1,
    authoritativePending: "",
    pending: "",
    inFlight: false,
    inFlightItem: null,
    queue: [],
    composing: false,
    composingText: "",
    message: "",
    error: false,
    baseRows: [],
    basePoint: { line: 0, column: 0 },
    snapshot: null,
    pointLine: 0,
    pointColumn: 0,
    provisionalText: "",
  };

  let viewport;
  let modeline;
  let echo;
  let inputTarget;
  let frameRoot;

  function buildChrome() {
    frameRoot = doc.createElement("div");
    frameRoot.className = "editor-frame";
    const panel = doc.createElement("div");
    panel.className = "editor-window selected";
    viewport = doc.createElement("pre");
    viewport.className = "editor-viewport";
    viewport.setAttribute("role", "textbox");
    viewport.setAttribute("aria-multiline", "true");

    modeline = doc.createElement("div");
    modeline.className = "editor-modeline";
    panel.append(viewport, modeline);
    frameRoot.appendChild(panel);

    echo = doc.createElement("div");
    echo.className = "editor-echo";

    inputTarget = doc.createElement("textarea");
    inputTarget.className = "editor-input";
    inputTarget.autocapitalize = "off";
    inputTarget.autocomplete = "off";
    inputTarget.spellcheck = false;
    inputTarget.setAttribute("autocorrect", "off");
    inputTarget.setAttribute("aria-label", "editor input");

    root.replaceChildren(frameRoot, echo, inputTarget);
    inputTarget.focus();
  }

  function snapshotUrl() {
    return (
      `/editor/snapshot?session=${encodeURIComponent(state.session)}` +
      `&lines=${SNAPSHOT_LINES}&max=${SNAPSHOT_SCALARS}`
    );
  }

  function send(item) {
    state.queue.push({ sequence: state.nextSequence, item });
    state.nextSequence += 1;
    updatePredictedPending();
    if (debug) console.debug("mica editor item", item);
    paintProvisional();
    pump();
  }

  async function pump() {
    if (state.inFlight || (state.inFlightItem === null && state.queue.length === 0)) return;
    state.inFlight = true;
    const queued = state.inFlightItem || state.queue.shift();
    state.inFlightItem = queued;
    const url =
      `/editor/input?session=${encodeURIComponent(state.session)}&frame=1` +
      `&sequence=${queued.sequence}&lines=${SNAPSHOT_LINES}&max=${SNAPSHOT_SCALARS}`;
    try {
      const response = await request(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(queued.item),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (debug) console.debug("mica editor result", data.result && data.result.status, data.snapshot);
      state.inFlightItem = null;
      applyResult(data.result);
      if (data.snapshot) render(data.snapshot);
      else paintProvisional();
    } catch (error) {
      state.message = `connection lost: ${error}`;
      state.error = true;
      renderEcho();
      state.inFlight = false;
      // Keep the item and its sequence. A retry is safe because the host
      // replays a completed result or resumes an incomplete finalization.
      await resync();
      pump();
      return;
    }
    state.inFlight = false;
    pump();
  }

  // A fetch with a deadline: a dropped connection must not wedge the queue.
  async function request(url, init) {
    if (typeof AbortController === "undefined") return fetchImpl(url, init);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      return await fetchImpl(url, { ...init, signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
  }

  async function resync() {
    try {
      const response = await request(snapshotUrl(), {});
      if (response.ok) render(await response.json());
    } catch {
      // Stay quiet: the echo area already reports the lost connection.
    }
  }

  function applyResult(result) {
    if (!result) return;
    state.error = result.status === "rejected" || result.status === "resync";
    if (result.message && result.message !== "none") {
      state.message = result.message;
    } else if (result.status === "undefined") {
      state.message = "undefined key sequence";
    } else if (result.status === "ok") {
      state.message = "";
    }
  }

  function predictedPendingAfter(pending, item) {
    if (!item || item.kind !== "key") return "";
    const sequence = pending ? `${pending} ${item.key}` : item.key;
    const plan = (state.snapshot && state.snapshot.keymap_plan) || [];
    const prefix = `${sequence} `;
    if (plan.some((row) => String(row.sequence || "").startsWith(prefix))) return sequence;
    return "";
  }

  function updatePredictedPending() {
    let pending = state.authoritativePending;
    if (state.inFlightItem) pending = predictedPendingAfter(pending, state.inFlightItem.item);
    for (const queued of state.queue) pending = predictedPendingAfter(pending, queued.item);
    state.pending = pending;
  }

  // The items that are sent but not yet acknowledged, if they are all plain
  // text insertions. Anything else disables replay until the queue drains.
  function pendingText() {
    const items = [];
    if (state.inFlightItem !== null) {
      if (state.inFlightItem.item.kind !== "text") return null;
      items.push(state.inFlightItem.item);
    }
    for (const queued of state.queue) {
      if (queued.item.kind !== "text") return null;
      items.push(queued.item);
    }
    return items.map((item) => String(item.text || ""));
  }

  function paintProvisional() {
    const texts = pendingText() ?? [];
    const inMinibuffer = !!(state.snapshot && state.snapshot.minibuffer_active);
    // Text typed at a prompt belongs to the prompt, not the buffer behind it.
    state.provisionalText = inMinibuffer ? texts.join("") : "";
    let rows = state.baseRows;
    let line = state.basePoint.line;
    let column = state.basePoint.column;
    if (!inMinibuffer && texts.length > 0) {
      const replayed = replayInsertions(rows, line, column, texts);
      rows = replayed.rows;
      line = replayed.line;
      column = replayed.column;
    }
    state.pointLine = line;
    state.pointColumn = column;
    paint(rows, line, column);
  }

  function render(snapshot) {
    state.session = snapshot.session || state.session;
    state.authoritativePending = snapshot.pending || "";
    state.baseRows = snapshot.rows || [];
    state.basePoint = {
      line: snapshot.point_line || 0,
      column: snapshot.point_column || 0,
    };
    state.snapshot = snapshot;
    updatePredictedPending();
    renderFrame(snapshot);
    paintProvisional();
  }

  function paintRows(targetViewport, targetModeline, windowSnapshot, rows, pointLine, pointColumn) {
    targetViewport.replaceChildren();
    for (const row of rows) {
      const line = doc.createElement("div");
      line.className = "editor-line";
      line._row = row;
      line._window = windowSnapshot.window;
      const text = row.text || "";
      if (row.line === pointLine) {
        const utf16 = utf16OffsetForScalar(text, pointColumn);
        line.appendChild(doc.createTextNode(text.slice(0, utf16)));
        const caret = doc.createElement("span");
        caret.className = "editor-caret";
        line.appendChild(caret);
        line.appendChild(doc.createTextNode(text.slice(utf16)));
      } else {
        line.textContent = text;
      }
      targetViewport.appendChild(line);
    }
    if (rows.length === 0) {
      const line = doc.createElement("div");
      line.className = "editor-line";
      line._window = windowSnapshot.window;
      const caret = doc.createElement("span");
      caret.className = "editor-caret";
      line.appendChild(caret);
      targetViewport.appendChild(line);
    }
    const name = windowSnapshot.buffer_name || "*scratch*";
    const modified = windowSnapshot.modified ? " **" : "";
    const mark = windowSnapshot.mark_active ? "  mark" : "";
    targetModeline.textContent =
      `-UUU:----F1  ${name}${modified}  L${pointLine + 1} C${pointColumn}  (Fundamental)${mark}`;
  }

  function renderFrame(snapshot) {
    if (!snapshot.frame_tree || !Array.isArray(snapshot.windows)) return;
    const windows = new Map(snapshot.windows.map((entry) => [String(entry.window), entry]));
    let selectedViewport = null;
    let selectedModeline = null;

    function build(node) {
      if (node && node.kind === "split") {
        const split = doc.createElement("div");
        split.className = `editor-split ${node.axis || "horizontal"}`;
        const first = build(node.first);
        const second = build(node.second);
        const ratio = Math.max(1, Math.min(999, Number(node.ratio) || 500));
        first.style.flexGrow = String(ratio);
        second.style.flexGrow = String(1000 - ratio);
        split.append(first, second);
        return split;
      }
      const data = windows.get(String(node && node.window)) || snapshot;
      const panel = doc.createElement("div");
      const selected = String(data.window) === String(snapshot.selected_window || snapshot.window);
      panel.className = selected ? "editor-window selected" : "editor-window";
      panel.dataset.window = String(data.window);
      const view = doc.createElement("pre");
      view.className = "editor-viewport";
      view.setAttribute("role", "textbox");
      view.setAttribute("aria-multiline", "true");
      const mode = doc.createElement("div");
      mode.className = "editor-modeline";
      panel.append(view, mode);
      paintRows(view, mode, data, data.rows || [], data.point_line || 0, data.point_column || 0);
      if (selected) {
        selectedViewport = view;
        selectedModeline = mode;
      }
      return panel;
    }

    frameRoot.replaceChildren(build(snapshot.frame_tree));
    if (selectedViewport) {
      viewport = selectedViewport;
      modeline = selectedModeline;
    }
  }

  function paint(rows, pointLine, pointColumn) {
    const snapshot = state.snapshot || {};
    paintRows(viewport, modeline, snapshot, rows, pointLine, pointColumn);

    renderEcho();
    placeInputTarget();
  }

  function renderEcho() {
    const snapshot = state.snapshot || {};
    echo.className = state.error ? "editor-echo error" : "editor-echo";
    echo.replaceChildren();
    if (snapshot.minibuffer_active) {
      const prompt = doc.createElement("span");
      prompt.textContent = snapshot.minibuffer_prompt || "";
      const text = doc.createElement("span");
      text.textContent = (snapshot.minibuffer_text || "") + state.provisionalText;
      echo.append(prompt, text, doc.createTextNode("▏"));
      if (state.message) {
        const note = doc.createElement("span");
        note.className = "editor-note";
        note.textContent = "  " + state.message;
        echo.appendChild(note);
      }
      return;
    }
    if (state.pending) {
      const pending = doc.createElement("span");
      pending.className = "pending";
      pending.textContent = state.pending + "-";
      echo.appendChild(pending);
      return;
    }
    if (state.message) echo.textContent = state.message;
  }

  // Moves the hidden input target near the caret so input methods compose in
  // the right place, and keeps the caret visible.
  function placeInputTarget() {
    const caret = viewport.querySelector(".editor-caret");
    if (!caret) return;
    const line = caret.parentElement;
    const top = line.offsetTop;
    const bottom = top + line.offsetHeight;
    if (top < viewport.scrollTop) viewport.scrollTop = top;
    else if (bottom > viewport.scrollTop + viewport.clientHeight) {
      viewport.scrollTop = bottom - viewport.clientHeight;
    }
    inputTarget.style.top = `${top - viewport.scrollTop}px`;
    inputTarget.style.left = `${caret.offsetLeft}px`;
  }

  function keyItem(chord) {
    return { kind: "key", key: chord };
  }

  function textItem(text) {
    return { kind: "text", text };
  }

  function inputItem(inputType, text) {
    return { kind: "input", input_type: inputType, text: text || "" };
  }

  function attachInput() {
    inputTarget.addEventListener("keydown", (event) => {
      if (event.isComposing || state.composing) return;
      if (event.key === "AltGraph") return;
      const chord = chordFor(event, isMac, state.pending !== "");
      if (!chord) return;
      const named = NAMED_KEYS[event.key];
      const modified = event.ctrlKey || event.altKey || (isMac && event.metaKey);
      const printable = event.key.length === 1;
      // Printable text comes from `beforeinput`, unless a prefix is pending:
      // then the key is the next chord of the sequence (C-x 2, C-x o, ...).
      if (printable && !modified && !state.pending) return;
      if (modified || named || printable || SWALLOWED.has(event.key)) {
        event.preventDefault();
        send(keyItem(chord));
      }
    });

    inputTarget.addEventListener("beforeinput", (event) => {
      if (state.composing) return;
      event.preventDefault();
      switch (event.inputType) {
        case "insertText":
        case "insertCompositionText":
          if (event.data) send(textItem(event.data));
          break;
        case "insertLineBreak":
          send(inputItem("insertLineBreak", ""));
          break;
        case "deleteContentBackward":
          send(inputItem("deleteContentBackward", ""));
          break;
        case "deleteContentForward":
          send(inputItem("deleteContentForward", ""));
          break;
        default:
          break;
      }
      inputTarget.value = "";
    });

    inputTarget.addEventListener("paste", (event) => {
      event.preventDefault();
      const text = event.clipboardData ? event.clipboardData.getData("text/plain") : "";
      if (text) send({ kind: "paste", text });
      inputTarget.value = "";
    });

    inputTarget.addEventListener("compositionstart", () => {
      state.composing = true;
      state.composingText = "";
    });
    inputTarget.addEventListener("compositionupdate", (event) => {
      state.composingText = event.data || "";
    });
    inputTarget.addEventListener("compositionend", (event) => {
      state.composing = false;
      const text = event.data || state.composingText;
      state.composingText = "";
      inputTarget.value = "";
      if (text) send(textItem(text));
    });

    frameRoot.addEventListener("mousedown", (event) => {
      event.preventDefault();
      inputTarget.focus();
      if (!event.target || typeof event.target.closest !== "function") return;
      const line = event.target.closest(".editor-line");
      if (!line || !line._row) return;
      const row = line._row;
      let utf16 = null;
      if (doc.caretRangeFromPoint) {
        const range = doc.caretRangeFromPoint(event.clientX, event.clientY);
        if (range && line.contains(range.startContainer)) {
          utf16 = utf16OffsetInLine(line, range.startContainer, range.startOffset);
        }
      } else if (doc.caretPositionFromPoint) {
        const position = doc.caretPositionFromPoint(event.clientX, event.clientY);
        if (position && line.contains(position.offsetNode)) {
          utf16 = utf16OffsetInLine(line, position.offsetNode, position.offset);
        }
      }
      if (utf16 === null) return;
      const pointer = {
        kind: "pointer",
        scalar_offset: (row.start || 0) + scalarPrefixLength(row.text || "", utf16),
        extend: event.shiftKey,
      };
      if (line._window !== undefined && line._window !== null) pointer.window = line._window;
      send(pointer);
    });

    // Keystrokes only reach the editor while the hidden input has focus. Click
    // anywhere in the editor to restore it, and never let focus drift away.
    if (doc.addEventListener) {
      doc.addEventListener("mousedown", (event) => {
        if (!root.contains || !root.contains(event.target)) return;
        if (event.target !== inputTarget) event.preventDefault();
        inputTarget.focus();
      });
    }
    if (win && win.addEventListener) {
      win.addEventListener("focus", () => inputTarget.focus());
    }
  }

  async function boot() {
    buildChrome();
    attachInput();
    try {
      const response = await request(snapshotUrl(), {});
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      render(await response.json());
    } catch (error) {
      state.message = `cannot reach the editor: ${error}`;
      state.error = true;
      renderEcho();
    }
  }

  boot();

  return {
    state,
    elements: {
      get viewport() { return viewport; },
      get modeline() { return modeline; },
      get frameRoot() { return frameRoot; },
      echo,
      inputTarget,
    },
    chordFor: (event) => chordFor(event, isMac),
    send,
    boot,
  };
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  // Exposed for DevTools: `__micaEditor.state` and the queued items.
  window.__micaEditor = createEditor({ debug: true });
}
