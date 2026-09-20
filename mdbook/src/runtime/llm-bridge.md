# The LLM Host Bridge

Mica tasks can call OpenAI-compatible LLM APIs. The bridge is an external
request service: the compiler lowers the host-request built-ins to an
`external_request`, the parked task hands the request to a host worker, and
the worker answers by resuming the task or by streaming typed events to a
mailbox.

The implementation lives in `mica/external` and uses libcurl for transport, so
HTTPS endpoints such as OpenRouter and the OpenAI API work directly.

> **Build requirement.** On Linux the build links the system libcurl, so the
> development packages must be installed
> (`libcurl4-openssl-dev libmbedtls-dev` on Debian/Ubuntu). macOS links the
> SDK copy and needs nothing extra.

## Calling a model

```mica
let [receiver, sender] = mailbox()

llm/chat_stream(
  "deepseek/deepseek-v4-pro",
  [llm/user_message("Say hello in one short sentence.")],
  {:stream -> true},
  [],          // tools
  sender
)

while true
  let ready = mailbox_recv([receiver], 500)
  if ready == []
    break
  end
  for group in ready
    for event in group[1]
      // Handle :started, :text_delta, :tool_call_ready, :completed, ...
    end
  end
end
mailbox_close(receiver)
```

`llm/chat_stream` and `llm/responses_stream` live in
`apps/shared/llm.mica`. The underlying built-ins are:

| Built-in | Service | Arguments |
| --- | --- | --- |
| `llm_chat_stream_to(model, messages, options, tools, stream_to)` | `openai` | streams Chat Completions events to the mailbox sender |
| `llm_responses_stream(model, input, instructions, options, tools, stream_to)` | `openai_responses` | streams Responses API events |
| `openai_chat_completion(model, messages)` | `openai` | one blocking Chat Completions call |
| `openai_chat_completion_with_options(model, messages, options)` | `openai` | the same, plus request options |

A streaming call returns `{:started -> true}` immediately. The caller drains
events from its mailbox; the stream keeps running on a host worker thread.
Events batched to keep up with a fast provider arrive as
`{:type -> :batch, :events -> [...]}`; expand them before dispatching.

## Event vocabulary

| `:type` | Fields |
| --- | --- |
| `:started` | `:provider` |
| `:text_delta` | `:delta`, and Responses API ids |
| `:tool_arguments_delta` | `:call_id`, `:name`, `:delta`, `:output_index` |
| `:tool_call_ready` | `:call_id`, `:name`, `:arguments`, `:item_id` |
| `:completed`, `:incomplete` | `:response`, `:usage`, `:text`, `:stop_reason` |
| `:error` | `:message`, `:raw` when the provider sent one |
| `:batch` | `:events` |

Some OpenAI-compatible providers stream tool calls as DSML markup inside the
text instead of native tool-call deltas. The bridge recognizes both the
`< | DSML | ...>` and `<｜DSML｜...>` forms in streamed text, withholds the
markup from `:text_delta` events, and synthesizes `:tool_call_ready` before the
terminal event. The non-streaming path rewrites the response's `tool_calls`
instead.

`apps/examples/llm-chat.mica` is a complete streaming example that logs the
deltas and records the assembled answer as a fact.

## Configuration

| Variable | Meaning |
| --- | --- |
| `OPENROUTER_API_KEY` | API key for OpenRouter (checked first). |
| `OPENAI_API_KEY` | API key for the OpenAI API. |
| `MICA_OPENAI_BASE_URL` | Base URL, for example a local llama.cpp or vLLM server. Defaults to `https://openrouter.ai/api/v1`. |
| `MICA_OPENAI_TIMEOUT_SECS` | Total per-request timeout; `60` by default, `0` disables it. |
| `MICA_OPENROUTER_REFERER`, `OPENROUTER_HTTP_REFERER` | `HTTP-Referer` header. |
| `MICA_OPENROUTER_TITLE`, `OPENROUTER_TITLE` | `X-OpenRouter-Title` header. |

A payload field of the same name overrides the environment: `base_url`,
`path`, `api_key`, `headers`, `referer`, and `title` are all read from the
request map. The generic `http` and `embedding` services are also served by
the bridge for hosts that call `external_request` directly.

## Failure and cancellation

A failed request resumes the parked task with an `ExternalError` value; a
streamed failure delivers an `{:type -> :error}` event instead. Closing the
mailbox stops delivery and aborts the transfer. Without a configured handler
the task resumes with `ExternalUnavailable`.
