// Tests for the sync client endpoint resolution.
//
// Run with: node --test host/web/sync-client.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { resolveSyncEndpoints } from "./sync-client.js";

const params = (search) => new URLSearchParams(search);

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
