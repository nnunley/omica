# draft-ndn-live-collaboration-00: Live Collaboration — Gesture State, Stream Operators, and Presence

**Status:** DRAFT
**Corpus:** red (the evidence uses fractional-second durations, which need rdaum/omica#138)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

Several people editing one live Mica world produce streams of fast, small
changes: drags, resizes, cursor positions. This document specifies how a
world absorbs them: live state lives in volatile relations and reaches
readers through an effective-state rule; stream operators written in Mica
consolidate a stream before it reaches a transaction; a gesture ends in
one durable write; and presence expires when its heartbeat stops. All of
it is built from existing language features, with no new runtime
mechanism.

## Motivation

Livelymerge, a Lively-style live object world stored in an Automerge
document, reports the costs of treating every pointer move as a durable
change: about 120 operations a second per drag, document growth
proportional to drag length, and visible stutter for collaborators. Its
fix splits state into ephemeral and persistent parts, broadcasts the
ephemeral part, and commits once when the gesture ends. Its authors name
two abstractions they still lack: gesture state without per-property
boilerplate, and shared objects that are never persisted.

Mica already has the parts those abstractions need: volatile relations,
rules, subscriptions, mailboxes, and timed suspension. What is absent is
the contract that composes them, so each application would rebuild it
differently. Transaction cost is not the obstacle: on omica, one task
commits 12,000 single-row changes to a volatile relation with three
subscribers in 0.10 s (about 120,000 commits a second). The costs that
remain are durable history and fan-out to clients, and both are reduced
by consolidating a stream before it reaches a durable write.

This document provides that composition as requirements with runnable
evidence.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **gesture** — a burst of changes to one piece of state from one user,
  such as a drag, ending when the user stops.
- **live state** — the in-progress value of a gesture, held in a volatile
  relation.
- **effective state** — the value readers see: live state when present,
  otherwise durable state.
- **stream operator** — a task that reads messages from one mailbox and
  sends consolidated messages to another.
- **presence** — a shared, never-persisted fact about a participant, such
  as a cursor (a "hand" in Livelymerge).

## Specification

This document defines how live state, stream operators, gesture
completion, and presence compose from existing Mica features. It does
NOT define transport to clients (draft-ndn-hosts-00), replication
between worlds (Out of Scope), or authority over the relations involved
(draft-ndn-authority-00).

**Readers never choose between live and durable state.** Code that
displays or reasons about a value queries its effective-state relation;
only the gesture's writer knows live state exists.

**Consolidation happens before the transaction boundary.** Operators
reduce a stream in task-local values and write the reduced result, so
history and fan-out scale with the consolidation rate, not the input
rate.

### Data model

```
RELATION Transform(subject, value)        -- durable, functional on subject
RELATION LiveTransform(subject, value)    -- volatile, functional on subject
RELATION IsLive(subject)                  -- derived: subject has live state
RELATION EffectiveTransform(subject, value)
                                          -- derived: live value, else durable
RELATION Hand(participant)                -- volatile presence
```

`Transform` stands for any durable, functional state a gesture edits.
Each such relation gets its own live and effective relations.

### Configuration

| Parameter | Type | Default | Description |
|---|---|---|---|
| `period` | seconds | `0.05` | sample interval; 20 updates a second is below the display rate and above the rate at which motion looks discontinuous |
| `quiet` | seconds | `0.25` | silence that ends a gesture; longer than the gap between input events, short enough that the durable write follows release promptly |
| `lease` | seconds | `4` | presence lifetime without a heartbeat, as in Livelymerge |

All durations are seconds, integer or float, as `suspend` and
`mailbox_recv` take them.

### Behavior

**Effective state.** An implementation MUST support the effective-state
pattern: a volatile relation overrides a durable one through rules, and
retracting the live row restores the durable value with no other write.
[R-effective-override]

Negated body atoms cannot contain holes, so the override goes through a
helper relation, `IsLive`, rather than `not LiveTransform(m, _)`.

```mica mode=eval @R-effective-override
make_functional_relation(:Transform, 2, [0])
make_functional_relation(:LiveTransform, 2, [0], :volatile)
make_relation(:IsLive, 1)
make_relation(:EffectiveTransform, 2)
IsLive(m) :- LiveTransform(m, t)
EffectiveTransform(m, t) :- LiveTransform(m, t)
EffectiveTransform(m, t) :- Transform(m, t), not IsLive(m)
assert Transform(:box, 0)
commit()
let before = EffectiveTransform(:box, ?t)
assert LiveTransform(:box, 7)
commit()
let during = EffectiveTransform(:box, ?t)
retract LiveTransform(:box, _)
commit()
let settled = EffectiveTransform(:box, ?t)
return [before, during, settled]
```

```expect
[[:t] {[0]}, [:t] {[7]}, [:t] {[0]}]
```

**Stream operators.** Operators are ordinary verbs, run as spawned tasks
and connected by mailboxes. They take their parameters as values and
capabilities, because function values cannot cross into a spawned task.

```mica id=streams
verb sample(source, sink, period)
  let running = true
  while running
    suspend(period)
    let latest = {}
    for group in mailbox_recv([source], 0)
      let [receiver, messages] = group
      for message in messages
        if message == :done
          running = false
        else
          let [key, value] = message
          latest[key] = value
        end
      end
    end
    if len(latest) > 0
      mailbox_send(sink, map_pairs(latest))
    end
  end
  mailbox_send(sink, :done)
end

verb debounce(source, sink, quiet)
  let running = true
  while running
    let ready = mailbox_recv([source], quiet)
    if ready == []
      running = false
    end
    for group in ready
      let [receiver, messages] = group
      for message in messages
        mailbox_send(sink, message)
      end
    end
  end
  mailbox_send(sink, :done)
end
```

`sample` MUST forward at most one batch per period, holding the latest
value per key, so the number of downstream messages depends on the
period, not the input rate. [R-sample-coalesces]

```mica mode=eval uses=streams @R-sample-coalesces
make_relation(:Batch, 1)
verb record(source)
  let count = 0
  let running = true
  while running
    for group in mailbox_recv([source])
      let [receiver, messages] = group
      for message in messages
        if message == :done
          running = false
        else
          count = count + 1
          assert Batch(message)
        end
      end
    end
  end
end
let [raw_rx, raw_tx] = mailbox()
let [out_rx, out_tx] = mailbox()
spawn :sample(source: raw_rx, sink: out_tx, period: 0.05)
spawn :record(source: out_rx)
commit()
let i = 1
while i <= 50
  mailbox_send(raw_tx, [:box, i])
  suspend(0.004)
  i = i + 1
end
mailbox_send(raw_tx, :done)
suspend(0.2)
let batches = Batch(?b)
require len(batches) < 50
require Batch([[:box, 50]])
return len(batches) < 50
```

```expect
true
```

**Gesture completion.** A gesture that ends without an explicit end
message MUST be detected by `debounce` after `quiet` seconds of silence.
It then MUST produce exactly one durable write of the final value, and
MUST retract its live state. [R-gesture-single-write]

The pipeline is `debounce` then `sample` then the application's writer.
Forty input moves become a few live batches and one durable write.

```mica mode=eval uses=streams @R-gesture-single-write
make_functional_relation(:Transform, 2, [0])
make_functional_relation(:LiveTransform, 2, [0], :volatile)
make_relation(:Writes, 1)
verb apply_live(source)
  let running = true
  while running
    for group in mailbox_recv([source])
      let [receiver, messages] = group
      for message in messages
        if message == :done
          running = false
        else
          for pair in message
            let [key, value] = pair
            retract LiveTransform(key, _)
            assert LiveTransform(key, value)
          end
        end
      end
    end
  end
  for row in LiveTransform(?key, ?value)
    let key = row[:key]
    let value = row[:value]
    retract LiveTransform(key, value)
    retract Transform(key, _)
    assert Transform(key, value)
    assert Writes(key)
  end
end
assert Transform(:box, 0)
let [raw_rx, raw_tx] = mailbox()
let [quiet_rx, quiet_tx] = mailbox()
let [out_rx, out_tx] = mailbox()
spawn :debounce(source: raw_rx, sink: quiet_tx, quiet: 0.25)
spawn :sample(source: quiet_rx, sink: out_tx, period: 0.02)
spawn :apply_live(source: out_rx)
commit()
let i = 1
while i <= 40
  mailbox_send(raw_tx, [:box, i])
  suspend(0.005)
  i = i + 1
end
suspend(0.8)
return [Transform(:box, ?t), LiveTransform(:box, ?t), Writes(?k)]
```

```expect
[[:t] {[40]}, [:t] {}, [:k] {[:box]}]
```

**Presence.** A presence fact MUST hold while heartbeats arrive within
`lease` seconds of each other, and MUST be retracted once `lease`
seconds pass without one. It lives in a volatile relation, so it never
reaches the store. [R-presence-lease]

```mica mode=eval @R-presence-lease
make_relation(:Hand, 1, :volatile)
verb presence(hand, heartbeats, lease)
  assert Hand(hand)
  let alive = true
  while alive
    alive = mailbox_recv([heartbeats], lease) != []
  end
  retract Hand(hand)
end
let [beat_rx, beat_tx] = mailbox()
spawn :presence(hand: :alice, heartbeats: beat_rx, lease: 0.3)
commit()
let i = 1
while i <= 5
  mailbox_send(beat_tx, :beat)
  suspend(0.03)
  i = i + 1
end
let while_beating = Hand(:alice)
suspend(0.8)
return [while_beating, Hand(:alice)]
```

```expect
[true, false]
```

### Errors

| Error | Example | Recovery |
|---|---|---|
| `E_TYPE` | a negative or non-numeric `period`, `quiet` or `lease` | The operator task aborts. Validate parameters before spawning. |
| `E_FUNCTIONAL_KEY` | asserting a second `LiveTransform` row for a subject without retracting the first | Retract, then assert, in the same task, as the writer above does. |

## Out of Scope

**Local-first replication.** Each participant holds a replica of the
world and merges concurrent edits instead of conflicting, as Automerge
does. It is also a candidate bridge between developers' git branches and
the live image. Extension point: the durable relations this document
names would carry operation identifiers (a counter and an actor), with
effective state derived by rules, as it is here for live state.

**Transport to clients.** How consolidated updates reach browser or
terminal clients belongs to the host protocol. Extension point:
draft-ndn-hosts-00; a host can subscribe to the effective-state relation.

## Alternatives Considered

**Why not send live updates as mailbox messages that bypass transactions?**
It is fast, but live state would not be in the world, so no rule, query
or subscription could see another user's gesture in progress. The
benchmark in Motivation shows the transaction path is cheap enough.

**Why not declare a coalescing policy on the relation, with the runtime
merging writes?** It adds a runtime mechanism for what Mica verbs already
express, and a new mechanism is a new thing every implementation,
including a self-hosted one, must build. Operators as verbs are
inspectable and replaceable.

**Why not consolidate in the client, with RxJS or signals?** Every client
would reimplement it, and non-browser clients would not have it. Mica's
rules and subscriptions already play the role of signals' computed
values and effects; only the time-based operators were missing.

**Why not commit every move durably?** History grows with gesture length,
which is the cost Livelymerge measured.

**Why not a general `scan` operator?** A fold needs a step function, and
function values cannot be passed to a spawned task. `sample` covers the
latest-value fold that gestures need. A general `scan` waits on a way to
name a step verb as a value.

## Security Considerations

A mailbox's send capability lets its holder inject messages into the
consumer. An operator that receives raw input MUST only be given
capabilities for its own input and output, so a participant cannot
write another participant's live state through a shared mailbox.
Presence is spoofable by anyone who can send heartbeats for a
participant; the heartbeat mailbox belongs to that participant's
connection. Volatile relations are still relations: writing them
requires write authority, as for durable ones.

## Compatibility

No language change. The evidence relies on durations in seconds with
fractional values, as the book specifies; at the time of writing
(September 2026), omica accepts them only with rdaum/omica#138.

Known gaps this document records but does not fix:

- Mica has no clock builtin, so a leading-edge throttle, which needs
  elapsed time, cannot be written; `sample` and `debounce` do not need
  one.
- Not yet measured: commit contention between concurrent gesture
  writers, and fan-out cost to clients over a host.
- Each presence fact costs one task. Many participants may call for a
  single sweeper, which needs the clock above.

## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): effective state as named rules over claims.
- Ink & Switch, *Livelymerge notebook, entry 7*, <https://www.inkandswitch.com/livelymerge/notebook/lm-07/>: ephemeral gesture state, broadcast, and hands with leases.
- ReactiveX operators `sample` and `debounce`, <https://reactivex.io/documentation/operators.html>: the operator vocabulary adopted here.
- Automerge, <https://github.com/automerge/automerge>: the local-first model deferred to Out of Scope.
- draft-ndn-mica-snippets-00 — how the `mica` evidence blocks run.
- draft-ndn-transactions-changelog-00 — commit boundaries at `suspend` and `mailbox_recv`.
- `mdbook/src/runtime/task-control.md` and `mdbook/src/runtime/subscriptions.md` — suspension, mailboxes and subscriptions.
- rdaum/omica#138 — durations in seconds, integer or float.
