// LLM stream decoding: SSE frames to typed event maps.
//
// The event vocabulary matches the Rust bridge so Mica apps are unchanged:
//
//   {:type -> :started, :provider -> "openrouter"}
//   {:type -> :text_delta, :delta -> "...", :item_id?, :output_index?, :content_index?}
//   {:type -> :tool_arguments_delta, :call_id?, :name?, :delta?, :output_index?}
//   {:type -> :tool_call_ready, :call_id?, :item_id?, :name?, :arguments?}
//   {:type -> :completed | :incomplete, :response?, :usage?, :text?, :stop_reason?}
//   {:type -> :error, :message -> "..."}
//   {:type -> :batch, :events -> [...]}
//
// Consecutive small events are coalesced into `:batch` messages. Delivery
// thresholds match the Rust batcher: the first text delta, a terminal event, a
// ready tool call, 128 delta bytes, or 40 ms.
package mica_external

import "core:mem"
import "core:strings"
import "core:time"
import r "../runtime"
import v "../var"

@(private)
BATCH_DELTA_BYTES :: 128
@(private)
BATCH_MILLIS :: 40

@(private)
stream_sender :: proc(payload: v.Value) -> (v.Value, bool) {
	sender, found := lookup(payload, "stream_to")
	if !found {
		return v.Value(0), false
	}
	return sender, true
}

// --- Event construction ----------------------------------------------------

@(private)
event_value :: proc(
	allocator: mem.Allocator,
	kind: string,
	fields: []v.Map_Entry,
	raw: v.Value,
	has_raw: bool,
) -> v.Value {
	entries := make([dynamic]v.Map_Entry, 0, len(fields) + 2, context.temp_allocator)
	append(&entries, symbol_entry("type", v.value_symbol(v.symbol_intern(kind))))
	append(&entries, ..fields)
	if has_raw {
		append(&entries, symbol_entry("raw", raw))
	}
	return v.value_map(allocator, entries[:])
}

@(private)
copy_field :: proc(
	fields: ^[dynamic]v.Map_Entry,
	json: v.Value,
	source: string,
	target: string,
) {
	if value, found := lookup(json, source); found {
		append(fields, symbol_entry(target, value))
	}
}

@(private)
lookup_text :: proc(value: v.Value, name: string) -> (string, bool) {
	field, found := lookup(value, name)
	if !found {
		return "", false
	}
	return v.value_as_string(field)
}

@(private)
lookup_symbol_name :: proc(value: v.Value, name: string) -> (string, bool) {
	field, found := lookup(value, name)
	if !found {
		return "", false
	}
	symbol, is_symbol := v.value_as_symbol(field)
	if !is_symbol {
		return "", false
	}
	return v.symbol_name(symbol)
}

@(private)
none_event :: proc(allocator: mem.Allocator) -> v.Value {
	return v.value_map(allocator, nil)
}

// --- Decoder ---------------------------------------------------------------

@(private)
Tool_Call_Accumulator :: struct {
	id:        string,
	name:      string,
	arguments: [dynamic]u8,
}

@(private)
Event_Decoder :: struct {
	sse:              Sse_Decoder,
	wire_api:         Wire_API,
	provider:         string,
	started:          bool,
	terminal:         bool,
	chat_tool_calls:  map[int]^Tool_Call_Accumulator,
	ready_tool_calls: map[string]bool,
	allocator:        mem.Allocator,
}

@(private)
event_decoder_init :: proc(
	decoder: ^Event_Decoder,
	wire_api: Wire_API,
	provider: string,
	allocator: mem.Allocator,
) {
	decoder.wire_api = wire_api
	decoder.provider = strings.clone(provider, allocator)
	decoder.allocator = allocator
	decoder.chat_tool_calls = make(map[int]^Tool_Call_Accumulator, allocator)
	decoder.ready_tool_calls = make(map[string]bool, allocator)
	sse_decoder_init(&decoder.sse, allocator)
}

@(private)
event_decoder_destroy :: proc(decoder: ^Event_Decoder) {
	sse_decoder_destroy(&decoder.sse)
	delete(decoder.provider, decoder.allocator)
	for _, accumulator in decoder.chat_tool_calls {
		delete(accumulator.arguments)
		free(accumulator, decoder.allocator)
	}
	delete(decoder.chat_tool_calls)
	delete(decoder.ready_tool_calls)
}

// Appends the events encoded by `bytes`. Returns an error message when a frame
// is not valid UTF-8 JSON.
@(private)
event_decoder_push :: proc(
	decoder: ^Event_Decoder,
	bytes: []byte,
	events: ^[dynamic]v.Value,
) -> (
	string,
	bool,
) {
	frames: [dynamic]string
	frames = make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(frames)
	sse_decoder_push(&decoder.sse, bytes, &frames)
	return event_decoder_frames(decoder, frames[:], events)
}

// Flushes any trailing frame and, when the stream ended without a terminal
// event, appends an error event.
@(private)
event_decoder_finish :: proc(
	decoder: ^Event_Decoder,
	events: ^[dynamic]v.Value,
) -> (
	string,
	bool,
) {
	frames: [dynamic]string
	frames = make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(frames)
	sse_decoder_finish(&decoder.sse, &frames)
	if message, ok := event_decoder_frames(decoder, frames[:], events); !ok {
		return message, false
	}
	if !decoder.terminal {
		append(
			events,
			event_value(
				decoder.allocator,
				"error",
				[]v.Map_Entry {
					symbol_entry(
						"message",
						v.value_string(
							decoder.allocator,
							"LLM stream ended without a terminal event",
						),
					),
				},
				v.Value(0),
				false,
			),
		)
		decoder.terminal = true
	}
	return "", true
}

@(private)
event_decoder_frames :: proc(
	decoder: ^Event_Decoder,
	frames: []string,
	events: ^[dynamic]v.Value,
) -> (
	string,
	bool,
) {
	for data in frames {
		if strings.trim_space(data) == "[DONE]" {
			if decoder.wire_api == .Chat_Completions && !decoder.terminal {
				append(events, event_value(decoder.allocator, "completed", nil, v.Value(0), false))
				decoder.terminal = true
			}
			continue
		}
		json, message, parsed := r.json_decode_text(decoder.allocator, data)
		if !parsed {
			return fmt_aprintf_temp("invalid LLM SSE data: %s", message), false
		}
		if !decoder.started {
			append(
				events,
				event_value(
					decoder.allocator,
					"started",
					[]v.Map_Entry {
						symbol_entry(
							"provider",
							v.value_string(decoder.allocator, decoder.provider),
						),
					},
					v.Value(0),
					false,
				),
			)
			decoder.started = true
		}
		normalized: [dynamic]v.Value
		normalized = make([dynamic]v.Value, 0, 4, context.temp_allocator)
		defer delete(normalized)
		switch decoder.wire_api {
		case .Responses:
			if error_message, ok := normalize_responses_event(
				decoder,
				json,
				&normalized,
			); !ok {
				return error_message, false
			}
		case .Chat_Completions:
			normalize_chat_event(decoder, json, &normalized)
		}
		for event in normalized {
			if kind, is_symbol := lookup_symbol_name(event, "type"); is_symbol &&
			   kind == "tool_call_ready" {
				call_id, has_call_id := lookup_text(event, "call_id")
				if has_call_id {
					if decoder.ready_tool_calls[call_id] {
						continue
					}
					decoder.ready_tool_calls[call_id] = true
				}
			}
			append(events, event)
		}
	}
	return "", true
}

// --- Normalizers -----------------------------------------------------------

@(private)
normalize_responses_event :: proc(
	decoder: ^Event_Decoder,
	json: v.Value,
	events: ^[dynamic]v.Value,
) -> (
	string,
	bool,
) {
	event_type, has_type := lookup_text(json, "type")
	if !has_type {
		return "", true
	}
	allocator := decoder.allocator
	switch event_type {
	case "response.created":
		// The `started` event already covers this.

	case "response.output_text.delta", "response.refusal.delta":
		fields: [dynamic]v.Map_Entry
		fields = make([dynamic]v.Map_Entry, 0, 4, context.temp_allocator)
		copy_field(&fields, json, "delta", "delta")
		copy_field(&fields, json, "item_id", "item_id")
		copy_field(&fields, json, "output_index", "output_index")
		copy_field(&fields, json, "content_index", "content_index")
		append(events, event_value(allocator, "text_delta", fields[:], v.Value(0), false))

	case "response.output_item.added":
		item, found := lookup(json, "item")
		if !found {
			return "", true
		}
		item_type, _ := lookup_text(item, "type")
		if item_type != "function_call" {
			return "", true
		}
		event, ok := tool_event(allocator, "tool_call_started", json)
		if !ok {
			return "", true
		}
		append(events, event)

	case "response.function_call_arguments.delta":
		fields: [dynamic]v.Map_Entry
		fields = make([dynamic]v.Map_Entry, 0, 4, context.temp_allocator)
		copy_field(&fields, json, "delta", "delta")
		copy_field(&fields, json, "item_id", "item_id")
		copy_field(&fields, json, "output_index", "output_index")
		append(
			events,
			event_value(allocator, "tool_arguments_delta", fields[:], v.Value(0), false),
		)

	case "response.function_call_arguments.done":
		event, ok := tool_event(allocator, "tool_call_ready", json)
		if ok {
			append(events, event)
		}

	case "response.output_item.done":
		item, found := lookup(json, "item")
		if !found {
			return "", true
		}
		item_type, _ := lookup_text(item, "type")
		if item_type != "function_call" {
			return "", true
		}
		event, ok := tool_event(allocator, "tool_call_ready", json)
		if ok {
			append(events, event)
		}

	case "response.completed":
		response, found := lookup(json, "response")
		if found {
			if output, is_list := lookup(response, "output"); is_list {
				items, _ := v.value_as_list(output)
				for item in items {
					item_type, _ := lookup_text(item, "type")
					if item_type != "function_call" {
						continue
					}
					event, ok := tool_event(allocator, "tool_call_ready", item)
					if ok {
						append(events, event)
					}
				}
			}
		}
		event, ok := response_terminal_event(allocator, "completed", json)
		if ok {
			append(events, event)
		}
		decoder.terminal = true

	case "response.incomplete":
		event, ok := response_terminal_event(allocator, "incomplete", json)
		if ok {
			append(events, event)
		}
		decoder.terminal = true

	case "response.failed", "error":
		message := "Responses API stream failed"
		if error_value, found := lookup(json, "error"); found {
			if text, has_text := lookup_text(error_value, "message"); has_text {
				message = text
			}
		} else if response, found := lookup(json, "response"); found {
			if error_value, has_error := lookup(response, "error"); has_error {
				if text, has_text := lookup_text(error_value, "message"); has_text {
					message = text
				}
			}
		} else if text, has_text := lookup_text(json, "message"); has_text {
			message = text
		}
		append(
			events,
			event_value(
				allocator,
				"error",
				[]v.Map_Entry {
					symbol_entry("message", v.value_string(allocator, message)),
				},
				json,
				true,
			),
		)
		decoder.terminal = true
	}
	return "", true
}

@(private)
normalize_chat_event :: proc(
	decoder: ^Event_Decoder,
	json: v.Value,
	events: ^[dynamic]v.Value,
) {
	allocator := decoder.allocator
	if error_value, found := lookup(json, "error"); found {
		message := "Chat Completions stream failed"
		if text, has_text := lookup_text(error_value, "message"); has_text {
			message = text
		}
		append(
			events,
			event_value(
				allocator,
				"error",
				[]v.Map_Entry {
					symbol_entry("message", v.value_string(allocator, message)),
				},
				json,
				true,
			),
		)
		decoder.terminal = true
		return
	}

	choices_value, found := lookup(json, "choices")
	if !found {
		return
	}
	choices, is_list := v.value_as_list(choices_value)
	if !is_list {
		return
	}
	for choice in choices {
		delta, found := lookup(choice, "delta")
		if !found {
			continue
		}
		if content, has_content := lookup_text(delta, "content"); has_content {
			append(
				events,
				event_value(
					allocator,
					"text_delta",
					[]v.Map_Entry {
						symbol_entry("delta", v.value_string(allocator, content)),
					},
					v.Value(0),
					false,
				),
			)
		}
		if tool_calls_value, has_tool_calls := lookup(delta, "tool_calls"); has_tool_calls {
			tool_calls, is_tool_list := v.value_as_list(tool_calls_value)
			if is_tool_list {
				for call in tool_calls {
					index := 0
					if index_value, has_index := lookup(call, "index"); has_index {
						if parsed, is_int := v.value_as_int(index_value); is_int {
							index = int(parsed)
						}
					}
					accumulator, has_accumulator := decoder.chat_tool_calls[index]
					if !has_accumulator {
						accumulator = new(Tool_Call_Accumulator, allocator)
						accumulator.arguments = make(
							[dynamic]u8,
							0,
							64,
							allocator,
						)
						decoder.chat_tool_calls[index] = accumulator
					}
					if id, has_id := lookup_text(call, "id"); has_id {
						accumulator.id = strings.clone(id, allocator)
					}
					function, has_function := lookup(call, "function")
					if has_function {
						if name, has_name := lookup_text(function, "name"); has_name {
							accumulator.name = strings.clone(name, allocator)
						}
						if arguments, has_arguments := lookup_text(
							function,
							"arguments",
						); has_arguments {
							append(&accumulator.arguments, ..transmute([]byte)arguments)
						}
					}
					fields: [dynamic]v.Map_Entry
					fields = make([dynamic]v.Map_Entry, 0, 4, context.temp_allocator)
					copy_field(&fields, call, "index", "output_index")
					copy_field(&fields, call, "id", "call_id")
					if has_function {
						copy_field(&fields, function, "name", "name")
						copy_field(&fields, function, "arguments", "delta")
					}
					append(
						events,
						event_value(
							allocator,
							"tool_arguments_delta",
							fields[:],
							v.Value(0),
							false,
						),
					)
				}
			}
		}
		if reason, has_reason := lookup_text(choice, "finish_reason"); has_reason {
			for index, accumulator in decoder.chat_tool_calls {
				index_value, _ := v.value_int(i64(index))
				append(
					events,
					event_value(
						allocator,
						"tool_call_ready",
						[]v.Map_Entry {
							symbol_entry("output_index", index_value),
							symbol_entry("call_id", v.value_string(allocator, accumulator.id)),
							symbol_entry("name", v.value_string(allocator, accumulator.name)),
							symbol_entry(
								"arguments",
								v.value_string(
									allocator,
									string(accumulator.arguments[:]),
								),
							),
						},
						json,
						true,
					),
				)
			}
			append(
				events,
				event_value(
					allocator,
					"completed",
					[]v.Map_Entry {
						symbol_entry("stop_reason", v.value_string(allocator, reason)),
					},
					json,
					true,
				),
			)
			decoder.terminal = true
		}
	}
}

@(private)
tool_event :: proc(
	allocator: mem.Allocator,
	kind: string,
	json: v.Value,
) -> (
	v.Value,
	bool,
) {
	item := json
	if nested, found := lookup(json, "item"); found {
		item = nested
	}
	fields: [dynamic]v.Map_Entry
	fields = make([dynamic]v.Map_Entry, 0, 5, context.temp_allocator)
	copy_field(&fields, item, "id", "item_id")
	if _, has_call_id := lookup(item, "call_id"); has_call_id {
		copy_field(&fields, item, "call_id", "call_id")
	} else {
		copy_field(&fields, item, "id", "call_id")
	}
	copy_field(&fields, item, "name", "name")
	copy_field(&fields, item, "arguments", "arguments")
	copy_field(&fields, json, "output_index", "output_index")
	return event_value(allocator, kind, fields[:], json, true), true
}

@(private)
response_terminal_event :: proc(
	allocator: mem.Allocator,
	kind: string,
	json: v.Value,
) -> (
	v.Value,
	bool,
) {
	fields: [dynamic]v.Map_Entry
	fields = make([dynamic]v.Map_Entry, 0, 3, context.temp_allocator)
	response, has_response := lookup(json, "response")
	if has_response {
		append(&fields, symbol_entry("response", response))
		if usage, has_usage := lookup(response, "usage"); has_usage {
			append(&fields, symbol_entry("usage", usage))
		}
		text := responses_output_text(response)
		if text != "" {
			append(&fields, symbol_entry("text", v.value_string(allocator, text)))
		}
	}
	return event_value(allocator, kind, fields[:], json, true), true
}

@(private)
responses_output_text :: proc(response: v.Value) -> string {
	output_value, found := lookup(response, "output")
	if !found {
		return ""
	}
	output, is_list := v.value_as_list(output_value)
	if !is_list {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for item in output {
		content_value, has_content := lookup(item, "content")
		if !has_content {
			continue
		}
		content, is_content_list := v.value_as_list(content_value)
		if !is_content_list {
			continue
		}
		for part in content {
			if text, has_text := lookup_text(part, "text"); has_text {
				strings.write_string(&builder, text)
				continue
			}
			if refusal, has_refusal := lookup_text(part, "refusal"); has_refusal {
				strings.write_string(&builder, refusal)
			}
		}
	}
	return strings.to_string(builder)
}

// --- Batching --------------------------------------------------------------

@(private)
Event_Batcher :: struct {
	events:       [dynamic]v.Value,
	delta_bytes:  int,
	last_flush:   time.Tick,
	text_started: bool,
	allocator:    mem.Allocator,
}

@(private)
Delivery :: struct {
	ctx:    r.External_Context,
	sender: v.Value,
}

@(private)
batcher_init :: proc(batcher: ^Event_Batcher, allocator: mem.Allocator) {
	batcher.allocator = allocator
	batcher.events = make([dynamic]v.Value, 0, 16, allocator)
	batcher.last_flush = time.tick_now()
}

@(private)
batcher_destroy :: proc(batcher: ^Event_Batcher) {
	delete(batcher.events)
}

// Adds an event, flushing when a delivery boundary is reached. Returns false
// when the mailbox is gone.
@(private)
batcher_accept :: proc(
	batcher: ^Event_Batcher,
	event: v.Value,
	delivery: Delivery,
) -> bool {
	kind, _ := lookup_symbol_name(event, "type")
	if delta, has_delta := lookup_text(event, "delta"); has_delta {
		batcher.delta_bytes += len(delta)
	}
	first_text := kind == "text_delta" && !batcher.text_started
	if kind == "text_delta" {
		batcher.text_started = true
	}
	append(&batcher.events, event)
	terminal := kind == "completed" || kind == "incomplete" || kind == "error"
	boundary := kind == "tool_call_ready"
	if first_text ||
	   terminal ||
	   boundary ||
	   batcher.delta_bytes >= BATCH_DELTA_BYTES ||
	   time.tick_since(batcher.last_flush) >= BATCH_MILLIS * time.Millisecond {
		return batcher_flush(batcher, delivery)
	}
	return true
}

@(private)
batcher_flush :: proc(batcher: ^Event_Batcher, delivery: Delivery) -> bool {
	if len(batcher.events) == 0 {
		return true
	}
	event: v.Value
	if len(batcher.events) == 1 {
		event = batcher.events[0]
	} else {
		events := make([]v.Value, len(batcher.events), context.temp_allocator)
		copy(events, batcher.events[:])
		event = event_value(
			batcher.allocator,
			"batch",
			[]v.Map_Entry {
				symbol_entry("events", v.value_list(batcher.allocator, events)),
			},
			v.Value(0),
			false,
		)
	}
	clear(&batcher.events)
	batcher.delta_bytes = 0
	batcher.last_flush = time.tick_now()
	return delivery.ctx.deliver(delivery.ctx.user, delivery.sender, event)
}

// --- Streaming driver ------------------------------------------------------

@(private)
Stream_Job :: struct {
	ctx:       r.External_Context,
	sender:    v.Value,
	spec:      Request_Spec,
	wire_api:  Wire_API,
	allocator: mem.Allocator,
}

@(private)
Stream_Outcome :: enum {
	Complete,
	Retryable,
	Failed,
}

// Starts a stream for a payload that carries `stream_to`. The task is resumed
// with `{:started -> true}` immediately; events arrive on the mailbox as they
// are decoded.
@(private)
handle_stream :: proc(
	ctx: r.External_Context,
	wire_api: Wire_API,
	payload: v.Value,
	sender: v.Value,
) -> v.Value {
	spec, message, ok := build_spec(payload, wire_api, true, ctx.allocator)
	if !ok {
		return error_value(ctx, message)
	}
	job := new(Stream_Job, ctx.allocator)
	job^ = Stream_Job {
		ctx       = ctx,
		sender    = sender,
		spec      = spec,
		wire_api  = wire_api,
		allocator = ctx.allocator,
	}
	job.sender = v.value_deep_copy(ctx.allocator, sender)
	if !ctx.spawn(ctx.user, stream_worker, job) {
		free(job, ctx.allocator)
		return error_value(ctx, "cannot start the LLM stream worker")
	}
	return v.value_map(ctx.allocator, []v.Map_Entry {
		symbol_entry("started", v.value_bool(true)),
	})
}

@(private)
stream_worker :: proc(data: rawptr) {
	job := (^Stream_Job)(data)
	defer free(job, job.allocator)

	attempt := 0
	for {
		attempt += 1
		outcome, message := attempt_stream(job)
		switch outcome {
		case .Complete:
			return
		case .Retryable:
			if attempt < 3 {
				time.sleep(time.Duration(250 * attempt) * time.Millisecond)
				continue
			}
		case .Failed:
		}
		deliver_error_event(job, message)
		return
	}
}

@(private)
deliver_error_event :: proc(job: ^Stream_Job, message: string) {
	event := event_value(
		job.allocator,
		"error",
		[]v.Map_Entry {
			symbol_entry("message", v.value_string(job.allocator, message)),
		},
		v.Value(0),
		false,
	)
	_ = job.ctx.deliver(job.ctx.user, job.sender, event)
}

// One HTTP attempt. A 2xx response is streamed to the mailbox to completion;
// non-2xx and transport failures before the response headers are retryable.
@(private)
attempt_stream :: proc(job: ^Stream_Job) -> (Stream_Outcome, string) {
	// Decoded events are delivered to a mailbox and may be read after this
	// thread ends, so they belong to the world allocator.
	decoder: Event_Decoder
	event_decoder_init(&decoder, job.wire_api, job.spec.provider, job.ctx.allocator)
	defer event_decoder_destroy(&decoder)
	batcher: Event_Batcher
	batcher_init(&batcher, job.ctx.allocator)
	defer batcher_destroy(&batcher)

	attempt := Stream_Attempt {
		job       = job,
		decoder   = &decoder,
		batcher   = &batcher,
		delivery  = Delivery{ctx = job.ctx, sender = job.sender},
		allocator = context.temp_allocator,
	}
	attempt.error_body = make([dynamic]u8, 0, 1024, context.temp_allocator)
	defer delete(attempt.error_body)

	result, curl_message := curl_perform_stream(
		job.spec.request,
		Stream_Sink{user = &attempt, on_status = stream_on_status, on_data = stream_on_data},
		context.temp_allocator,
	)
	if attempt.aborted {
		return .Failed, attempt.failure
	}
	if curl_message != "" {
		if attempt.status != 0 && attempt.status >= 200 && attempt.status < 300 {
			// Headers arrived, then the body failed: not retryable.
			return .Failed, curl_message
		}
		return .Retryable, curl_message
	}
	if result.status < 200 || result.status >= 300 {
		message := fmt_aprintf_temp(
			"LLM stream failed with HTTP %d: %s",
			result.status,
			string(attempt.error_body[:]),
		)
		if is_retryable_llm_status(result.status) {
			return .Retryable, message
		}
		return .Failed, message
	}

	events: [dynamic]v.Value
	events = make([dynamic]v.Value, 0, 16, context.temp_allocator)
	defer delete(events)
	if message, ok := event_decoder_finish(&decoder, &events); !ok {
		return .Failed, message
	}
	for event in events {
		if !batcher_accept(&batcher, event, attempt.delivery) {
			return .Failed, "LLM stream receiver closed"
		}
	}
	return .Complete, ""
}

@(private)
Stream_Attempt :: struct {
	job:        ^Stream_Job,
	decoder:    ^Event_Decoder,
	batcher:    ^Event_Batcher,
	delivery:   Delivery,
	allocator:  mem.Allocator,
	status:     u16,
	error_body: [dynamic]u8,
	aborted:    bool,
	failure:    string,
}

@(private)
stream_on_status :: proc(user: rawptr, status: u16) -> bool {
	attempt := (^Stream_Attempt)(user)
	attempt.status = status
	return true
}

@(private)
stream_on_data :: proc(user: rawptr, data: []byte) -> bool {
	attempt := (^Stream_Attempt)(user)
	if attempt.aborted {
		return false
	}
	if attempt.status < 200 || attempt.status >= 300 {
		// Buffer an error body for the retry decision and error message.
		if len(attempt.error_body) < 64 * 1024 {
			append(&attempt.error_body, ..data)
		}
		return true
	}
	events: [dynamic]v.Value
	events = make([dynamic]v.Value, 0, 16, context.temp_allocator)
	defer delete(events)
	message, ok := event_decoder_push(attempt.decoder, data, &events)
	if !ok {
		attempt.aborted = true
		attempt.failure = message
		return false
	}
	for event in events {
		if !batcher_accept(attempt.batcher, event, attempt.delivery) {
			attempt.aborted = true
			attempt.failure = "LLM stream receiver closed"
			return false
		}
	}
	return true
}

@(private)
is_retryable_llm_status :: proc(status: u16) -> bool {
	return status == 408 || status == 409 || status == 429 || status >= 500
}
