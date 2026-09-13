// Tests for the sync client endpoint resolution.
//
// Run with: node --test host/web/sync-client.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { resolveSyncEndpoints, applyAttributes } from "./sync-client.js";

const params = (search) => new URLSearchParams(search);

// Minimal element stub for attribute reconciliation.
function fakeElement() {
    const attrs = new Map();
    return {
        attrs,
        getAttribute: (name) => (attrs.has(name) ? attrs.get(name) : null),
        setAttribute: (name, value) => attrs.set(name, String(value)),
        hasAttribute: (name) => attrs.has(name),
        removeAttribute: (name) => attrs.delete(name),
        getAttributeNames: () => [...attrs.keys()],
    };
}

test("reconcile drops custom attributes removed from the snapshot", () => {
    const element = fakeElement();
    applyAttributes(element, { "data-custom": "one", "aria-label": "x" });
    assert.equal(element.attrs.get("data-custom"), "one");
    assert.equal(element.attrs.get("aria-label"), "x");

    applyAttributes(element, {});
    assert.equal(element.attrs.has("data-custom"), false);
    assert.equal(element.attrs.has("aria-label"), false);
});

test("reconcile keeps wanted attributes and leaves unmanaged ones alone", () => {
    const element = fakeElement();
    applyAttributes(element, { "data-custom": "one" });
    element.attrs.set("style", "color:red");
    applyAttributes(element, { "data-custom": "two" });
    assert.equal(element.attrs.get("data-custom"), "two");
    assert.equal(element.attrs.get("style"), "color:red");
});

test("production ignores query endpoint overrides", () => {
    const endpoints = resolveSyncEndpoints(
        { syncUrl: "/sync" },
        params(
            "?syncUrl=https://evil.invalid/sync&url=https://evil.invalid/wt&transport=webtransport&certHash=abc",
        ),
        false,
    );
    assert.equal(endpoints.syncUrl, "/sync");
    assert.equal(endpoints.url, "");
    assert.equal(endpoints.transport, "sse");
    assert.equal(endpoints.certificateHash, "");
});

test("production uses the host-rendered dataset configuration", () => {
    const endpoints = resolveSyncEndpoints(
        { syncUrl: "/mud-sync", syncTransport: "sse" },
        params("?syncUrl=https://evil.invalid"),
        false,
    );
    assert.equal(endpoints.syncUrl, "/mud-sync");
    assert.equal(endpoints.transport, "sse");
});

test("protocol-relative override is ignored in production", () => {
    const endpoints = resolveSyncEndpoints(
        {},
        params("?syncUrl=//evil.invalid/sync"),
        false,
    );
    assert.equal(endpoints.syncUrl, "/sync");
});

test("development honors query overrides", () => {
    const endpoints = resolveSyncEndpoints(
        { syncUrl: "/sync" },
        params(
            "?syncUrl=https://dev.invalid/sync&url=https://dev.invalid/wt&transport=webtransport&certHash=deadbeef",
        ),
        true,
    );
    assert.equal(endpoints.syncUrl, "https://dev.invalid/sync");
    assert.equal(endpoints.url, "https://dev.invalid/wt");
    assert.equal(endpoints.transport, "webtransport");
    assert.equal(endpoints.certificateHash, "deadbeef");
});
