// Tests for the browser editor client: key normalization and the input paths
// that decide where typed text lands (text items, not swallowed key chords).
//
// Run with: node --test host/web/editor-client.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import {
  chordFor,
  scalarPrefixLength,
  utf16OffsetForScalar,
  replayInsertions,
  createEditor,
} from "./editor-client.js";

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

// --- A DOM small enough to drive the real client event paths ---------------

function makeTextNode(text) {
  return { nodeType: 3, textContent: text, data: text, parentElement: null };
}

function makeElement(tag) {
  const listeners = new Map();
  const element = {
    tagName: tag.toUpperCase(),
    children: [],
    childNodes: [],
    style: {},
    dataset: {},
    className: "",
    value: "",
    parentElement: null,
    offsetTop: 0,
    offsetLeft: 0,
    offsetHeight: 18,
    clientHeight: 400,
    scrollTop: 0,
    addEventListener(type, handler) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(handler);
    },
    dispatch(type, event) {
      if (!event.target) event.target = this;
      for (const handler of listeners.get(type) || []) handler(event);
      if (this.parentElement) this.parentElement.dispatch(type, event);
    },
    appendChild(child) {
      this._raw = undefined;
      if (child.nodeType !== 3) this.children.push(child);
      this.childNodes.push(child);
      child.parentElement = this;
      return child;
    },
    append(...nodes) {
      for (const node of nodes) this.appendChild(node);
    },
    replaceChildren(...nodes) {
      this.children = [];
      this.childNodes = [];
      for (const node of nodes) this.appendChild(node);
    },
    setAttribute() {},
    focus() {},
    querySelector(selector) {
      const wanted = selector.replace(/^\./, "");
      const visit = (node) => {
        for (const child of node.children) {
          if (child.className.split(" ").includes(wanted)) return child;
          const found = visit(child);
          if (found) return found;
        }
        return null;
      };
      return visit(this);
    },
    closest(selector) {
      const wanted = selector.replace(/^\./, "");
      let node = this;
      while (node) {
        if (node.className && node.className.split(" ").includes(wanted)) return node;
        node = node.parentElement;
      }
      return null;
    },
    contains(node) {
      let current = node;
      while (current) {
        if (current === this) return true;
        current = current.parentElement;
      }
      return false;
    },
  };
  Object.defineProperty(element, "textContent", {
    get() {
      if (this._raw !== undefined) return this._raw;
      return this.childNodes.map((child) => child.textContent).join("");
    },
    set(value) {
      this._raw = value;
      this.children = [];
      this.childNodes = [];
    },
  });
  return element;
}

function makeDocument(session) {
  const root = makeElement("div");
  root.dataset.session = session;
  const doc = {
    root,
    getElementById: (id) => (id === "mica-editor" ? root : null),
    createElement: (tag) => makeElement(tag),
    createTextNode: (text) => makeTextNode(text),
    caretRangeFromPoint: null,
  };
  return doc;
}

function baseSnapshot(overrides = {}) {
  return {
    session: "41",
    buffer_name: "*scratch*",
    modified: false,
    revision: 1,
    first_line: 0,
    rows: [{ line: 0, start: 0, stop: 0, text: "", complete: true }],
    point: 0,
    point_line: 0,
    point_column: 0,
    mark: null,
    mark_active: false,
    pending: "",
    minibuffer_active: false,
    minibuffer_prompt: "",
    minibuffer_text: "",
    ...overrides,
  };
}

// A fetch double that records requests and serves queued snapshots.
function makeTransport(initial, responses = []) {
  const requests = [];
  const fetch = async (url, options = {}) => {
    if (options && options.method === "POST") {
      requests.push(JSON.parse(options.body));
      const snapshot = responses.length > 0 ? responses.shift() : initial;
      return { ok: true, json: async () => ({ result: { status: "ok" }, snapshot }) };
    }
    return { ok: true, json: async () => initial };
  };
  return { fetch, requests };
}

function keyEvent(overrides = {}) {
  return {
    key: "",
    isComposing: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    metaKey: false,
    canceled: false,
    preventDefault() {
      this.canceled = true;
    },
    ...overrides,
  };
}

async function installEditor(snapshot, transport) {
  const doc = makeDocument("41");
  const editor = createEditor({
    document: doc,
    window: {},
    navigator: { platform: "Linux" },
    fetch: transport.fetch,
    root: doc.root,
  });
  await tick();
  return { editor, doc };
}

// --- Pure normalization -----------------------------------------------------

test("chords normalize modifier order and named keys", () => {
  assert.equal(chordFor(keyEvent({ key: "f", ctrlKey: true }), false), "C-f");
  assert.equal(chordFor(keyEvent({ key: "F", ctrlKey: true, shiftKey: true }), false), "C-S-f");
  assert.equal(chordFor(keyEvent({ key: "ArrowLeft" }), false), "<left>");
  assert.equal(chordFor(keyEvent({ key: "Enter" }), false), "<return>");
  assert.equal(chordFor(keyEvent({ key: "x", altKey: true }), false), "M-x");
  assert.equal(chordFor(keyEvent({ key: "x", metaKey: true }), true), "s-x");
});

test("plain printable keys are not chords", () => {
  assert.equal(chordFor(keyEvent({ key: "a" }), false), null);
  assert.equal(chordFor(keyEvent({ key: "A", shiftKey: true }), false), "S-a");
  assert.equal(chordFor(keyEvent({ key: " " }), false), "<space>");
});

test("scalar prefix length converts UTF-16 offsets", () => {
  assert.equal(scalarPrefixLength("hello", 3), 3);
  assert.equal(scalarPrefixLength("h\u00e9llo", 2), 2);
  // An emoji is two UTF-16 units and one scalar.
  assert.equal(scalarPrefixLength("a\ud83d\ude00b", 3), 2);
  assert.equal(scalarPrefixLength("a\ud83d\ude00b", 4), 3);
});

test("scalar columns convert back to UTF-16 offsets", () => {
  assert.equal(utf16OffsetForScalar("a\ud83d\ude00b", 0), 0);
  assert.equal(utf16OffsetForScalar("a\ud83d\ude00b", 2), 3);
  assert.equal(utf16OffsetForScalar("a\ud83d\ude00b", 3), 4);
});

test("replay applies queued insertions to a copy", () => {
  const rows = [{ line: 0, start: 0, stop: 2, text: "ab", complete: true }];
  const replayed = replayInsertions(rows, 0, 1, ["X", "Y"]);
  assert.equal(replayed.rows[0].text, "aXYb");
  assert.equal(replayed.line, 0);
  assert.equal(replayed.column, 3);
  assert.equal(rows[0].text, "ab", "the authoritative rows are not mutated");
});

test("replay splits inserted newlines into lines", () => {
  const rows = [{ line: 9, start: 20, stop: 22, text: "ab", complete: true }];
  const replayed = replayInsertions(rows, 9, 1, ["\n"]);
  assert.equal(replayed.rows[0].text, "a");
  assert.equal(replayed.rows[1].text, "b");
  assert.equal(replayed.rows[0].line, 9);
  assert.equal(replayed.rows[1].line, 10);
  assert.equal(replayed.line, 10);
  assert.equal(replayed.column, 0);
});

test("replay uses scalar columns around astral characters", () => {
  const rows = [{ line: 0, start: 0, stop: 3, text: "a\ud83d\ude00b", complete: true }];
  const replayed = replayInsertions(rows, 0, 2, ["X"]);
  assert.equal(replayed.rows[0].text, "a\ud83d\ude00Xb");
  assert.equal(replayed.column, 3);
});

// --- Input paths ------------------------------------------------------------

test("plain letters are sent as text items, not key chords", async () => {
  const transport = makeTransport(baseSnapshot());
  const { editor } = await installEditor(baseSnapshot(), transport);
  const input = editor.elements.inputTarget;

  input.dispatch("keydown", keyEvent({ key: "a" }));
  await tick();
  assert.equal(transport.requests.length, 0, "keydown for a letter sends nothing");

  input.dispatch("beforeinput", {
    inputType: "insertText",
    data: "a",
    preventDefault() {},
  });
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "text", text: "a" });
});

test("space and capitals go through beforeinput", async () => {
  const transport = makeTransport(baseSnapshot());
  const { editor } = await installEditor(baseSnapshot(), transport);
  const input = editor.elements.inputTarget;

  input.dispatch("keydown", keyEvent({ key: " " }));
  await tick();
  assert.equal(transport.requests.length, 0, "space keydown sends nothing");

  input.dispatch("beforeinput", { inputType: "insertText", data: " ", preventDefault() {} });
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "text", text: " " });

  input.dispatch("keydown", keyEvent({ key: "A", shiftKey: true }));
  await tick();
  assert.equal(transport.requests.length, 1, "shift-A keydown sends nothing");

  input.dispatch("beforeinput", { inputType: "insertText", data: "A", preventDefault() {} });
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "text", text: "A" });
});

test("control chords and named keys are sent as key items", async () => {
  const transport = makeTransport(baseSnapshot());
  const { editor } = await installEditor(baseSnapshot(), transport);
  const input = editor.elements.inputTarget;

  input.dispatch("keydown", keyEvent({ key: "f", ctrlKey: true }));
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "key", key: "C-f" });

  input.dispatch("keydown", keyEvent({ key: "Enter" }));
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "key", key: "<return>" });

  input.dispatch("keydown", keyEvent({ key: "Backspace" }));
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "key", key: "<backspace>" });
});

test("a printable key completes a pending prefix as a chord", async () => {
  const snapshot = baseSnapshot({ pending: "C-x" });
  const transport = makeTransport(snapshot);
  const { editor } = await installEditor(snapshot, transport);
  const input = editor.elements.inputTarget;

  assert.equal(editor.state.pending, "C-x", "the client tracks the server's pending sequence");

  input.dispatch("keydown", keyEvent({ key: "2" }));
  await tick();
  assert.deepEqual(transport.requests.at(-1), { kind: "key", key: "2" });
});

test("a fast printable key completes an in-flight prefix", async () => {
  const initial = baseSnapshot({
    keymap_plan: [{ sequence: "C-x 2" }, { sequence: "C-x o" }],
  });
  let resolvePrefix;
  const requests = [];
  const transport = {
    fetch: async (url, options = {}) => {
      if (!options.method) return { ok: true, json: async () => initial };
      requests.push(JSON.parse(options.body));
      if (requests.length === 1) {
        return new Promise((resolve) => {
          resolvePrefix = () => resolve({
            ok: true,
            json: async () => ({ result: { status: "prefix" }, snapshot: { ...initial, pending: "C-x" } }),
          });
        });
      }
      return { ok: true, json: async () => ({ result: { status: "ok" }, snapshot: initial }) };
    },
  };
  const { editor } = await installEditor(initial, transport);
  const input = editor.elements.inputTarget;
  input.dispatch("keydown", keyEvent({ key: "x", ctrlKey: true }));
  input.dispatch("keydown", keyEvent({ key: "2" }));
  assert.equal(editor.state.queue[0].item.kind, "key");
  assert.equal(editor.state.queue[0].item.key, "2");
  resolvePrefix();
  await tick();
  await tick();
  await tick();
  assert.deepEqual(requests, [{ kind: "key", key: "C-x" }, { kind: "key", key: "2" }]);
});

test("an ambiguous failure retries the same sequenced item", async () => {
  const initial = baseSnapshot();
  const postUrls = [];
  let attempts = 0;
  const transport = {
    fetch: async (url, options = {}) => {
      if (!options.method) return { ok: true, json: async () => initial };
      attempts += 1;
      postUrls.push(url);
      if (attempts === 1) throw new Error("lost response");
      return { ok: true, json: async () => ({ result: { status: "ok" }, snapshot: initial }) };
    },
  };
  const { editor } = await installEditor(initial, transport);
  editor.elements.inputTarget.dispatch("beforeinput", {
    inputType: "insertText",
    data: "x",
    preventDefault() {},
  });
  await tick();
  await tick();
  await tick();
  assert.equal(attempts, 2);
  assert.match(postUrls[0], /sequence=1/);
  assert.equal(postUrls[0], postUrls[1]);
});

test("the frame tree renders every visible window", async () => {
  const first = { ...baseSnapshot(), window: 1, buffer_name: "one" };
  const second = {
    ...baseSnapshot(),
    window: 3,
    buffer_name: "two",
    rows: [{ line: 0, start: 0, stop: 3, text: "two", complete: true }],
  };
  const snapshot = {
    ...second,
    selected_window: 3,
    windows: [first, second],
    frame_tree: {
      kind: "split",
      axis: "vertical",
      ratio: 500,
      first: { kind: "window", window: 1 },
      second: { kind: "window", window: 3 },
    },
  };
  const transport = makeTransport(snapshot);
  const { editor } = await installEditor(snapshot, transport);
  const split = editor.elements.frameRoot.children[0];
  assert.equal(split.className, "editor-split vertical");
  assert.equal(split.children.length, 2);
  assert.ok(editor.elements.frameRoot.textContent.includes("one"));
  assert.ok(editor.elements.frameRoot.textContent.includes("two"));
});

test("typing paints provisionally before the result arrives", async () => {
  const authoritative = baseSnapshot({
    revision: 1,
    rows: [{ line: 0, start: 0, stop: 1, text: "a", complete: true }],
    point: 1,
    point_column: 1,
  });
  let resolveInput;
  const requests = [];
  const transport = {
    fetch: async (url, options = {}) => {
      if (options && options.method === "POST") {
        requests.push(JSON.parse(options.body));
        return new Promise((resolve) => {
          resolveInput = () =>
            resolve({ ok: true, json: async () => ({ result: { status: "ok" }, snapshot: authoritative }) });
        });
      }
      return { ok: true, json: async () => baseSnapshot() };
    },
  };
  const { editor } = await installEditor(baseSnapshot(), transport);
  const input = editor.elements.inputTarget;

  input.dispatch("beforeinput", { inputType: "insertText", data: "a", preventDefault() {} });
  await tick();
  assert.equal(editor.elements.viewport.textContent, "a", "the character is painted before the result");
  assert.equal(editor.state.pointColumn, 1, "the provisional caret advanced");

  resolveInput();
  await tick();
  assert.equal(editor.elements.viewport.textContent, "a", "the authoritative render agrees");
  assert.equal(requests.length, 1, "the item is sent exactly once");
});

test("typing at a prompt echoes provisionally without touching the buffer", async () => {
  const promptSnapshot = baseSnapshot({
    minibuffer_active: true,
    minibuffer_prompt: "M-x ",
    minibuffer_text: "",
  });
  let resolveInput;
  const transport = {
    fetch: async (url, options = {}) => {
      if (options && options.method === "POST") {
        return new Promise((resolve) => {
          resolveInput = () =>
            resolve({
              ok: true,
              json: async () => ({
                result: { status: "ok" },
                snapshot: { ...promptSnapshot, minibuffer_text: "e" },
              }),
            });
        });
      }
      return { ok: true, json: async () => promptSnapshot };
    },
  };
  const { editor } = await installEditor(promptSnapshot, transport);
  const input = editor.elements.inputTarget;

  input.dispatch("beforeinput", { inputType: "insertText", data: "e", preventDefault() {} });
  await tick();
  assert.equal(editor.elements.viewport.textContent, "", "the buffer is untouched");
  assert.ok(editor.elements.echo.textContent.includes("M-x e"), "the prompt echoes the key");

  resolveInput();
  await tick();
  assert.ok(editor.elements.echo.textContent.includes("M-x e"), "the authoritative echo agrees");
});

test("a prompt result message stays visible while the prompt is open", async () => {
  const promptSnapshot = baseSnapshot({
    minibuffer_active: true,
    minibuffer_prompt: "M-x ",
    minibuffer_text: "bogus",
  });
  const transport = {
    fetch: async (url, options = {}) => {
      if (options && options.method === "POST") {
        return {
          ok: true,
          json: async () => ({
            result: { status: "ok", message: "No match: bogus (C-g or Esc cancels)" },
            snapshot: promptSnapshot,
          }),
        };
      }
      return { ok: true, json: async () => promptSnapshot };
    },
  };
  const { editor } = await installEditor(promptSnapshot, transport);
  editor.elements.inputTarget.dispatch("keydown", keyEvent({ key: "Enter" }));
  await tick();
  const echoText = editor.elements.echo.textContent;
  assert.ok(echoText.includes("No match"), `the message is visible: ${echoText}`);
  assert.ok(echoText.includes("C-g"), "the escape hint is visible");
});

test("a click sends a pointer item with the clicked scalar offset", async () => {
  const snapshot = baseSnapshot({
    rows: [{ line: 0, start: 0, stop: 5, text: "hello", complete: true }],
    point_column: 5,
    point: 5,
  });
  const transport = makeTransport(snapshot);
  const { editor, doc } = await installEditor(snapshot, transport);
  const viewport = editor.elements.viewport;
  const line = viewport.querySelector(".editor-line");
  assert.ok(line, "the rendered line exists");
  const textNode = line.childNodes[0];
  doc.caretRangeFromPoint = () => ({ startContainer: textNode, startOffset: 3 });

  viewport.dispatch("mousedown", {
    clientX: 10,
    clientY: 10,
    shiftKey: false,
    target: line,
    preventDefault() {},
  });
  await tick();
  assert.deepEqual(transport.requests.at(-1), {
    kind: "pointer",
    scalar_offset: 3,
    extend: false,
  });
});

test("shift-click extends the region", async () => {
  const snapshot = baseSnapshot({
    rows: [{ line: 0, start: 0, stop: 5, text: "hello", complete: true }],
    point_column: 5,
    point: 5,
  });
  const transport = makeTransport(snapshot);
  const { editor, doc } = await installEditor(snapshot, transport);
  const line = editor.elements.viewport.querySelector(".editor-line");
  doc.caretRangeFromPoint = () => ({ startContainer: line.childNodes[0], startOffset: 1 });

  editor.elements.viewport.dispatch("mousedown", {
    clientX: 5,
    clientY: 5,
    shiftKey: true,
    target: line,
    preventDefault() {},
  });
  await tick();
  assert.deepEqual(transport.requests.at(-1), {
    kind: "pointer",
    scalar_offset: 1,
    extend: true,
  });
});
