# Web host memory

Each HTTP request runs in its own arena. `web_connection_respond`
(`host/web/server.odin`) creates the arena, installs it as
`context.temp_allocator`, and destroys it when the response has been sent, the
send has failed, or a stream has ended. Keep-alive requests on one connection
each get a new arena. `context.allocator` is unchanged.

Handlers may put response headers, bodies and intermediate values in
`context.temp_allocator`. Anything a world, task or session keeps after the
request must be copied into that owner's allocator.

The connection owns the parser and the reusable response builder; neither
allocates from the request arena. Parse-error responses are built with the
server's allocator.

## Streams

A stream handler (the SSE endpoint in `host/web/sync.odin`) returns only when
the stream ends, so its request arena lives until then. The stream reuses two
builders allocated there, resetting them between events; they grow to the size
of the largest event sent. Queued envelopes and payloads stay session-owned,
and the stream frees each one after sending it, including the unsent rest of a
batch when a send fails. Per-event data must not be allocated from
`context.temp_allocator`, because it would stay until disconnect.

## Scoping in Odin

A `context` assignment and a `defer` both end with the block that contains
them. Installing an arena inside an `if` block therefore removes it and
destroys it before the next statement runs:

```odin
if virtual.arena_init_growing(&arena) == nil {
	context.temp_allocator = virtual.arena_allocator(&arena) // undone at `}`
	defer virtual.arena_destroy(&arena)                      // runs at `}`
}
```

Install the arena at the scope that uses it, as `web_connection_respond` does.
