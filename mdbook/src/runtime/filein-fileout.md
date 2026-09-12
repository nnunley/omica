# Filein and Fileout

Filein and fileout provide a human-readable import and export surface for world state.

Filein runs ordinary Mica source:

```mica
make_identity(:sensor)
make_functional_relation(:Label, 2, [0])
assert Label(#sensor, "temperature sensor")

verb inspect(actor, subject)
  let exactly {label} = Label(subject, ?label)
  return label
end
```

Fileout emits readable source that can be reviewed, edited, version controlled, and filed back in.

This is useful for more than object worlds. A fileout can capture the schema, rules, seed facts, and
verb definitions for an agent workspace, including relations such as `Task`, `Artifact`,
`Observation`, `ToolResult`, `AssignedTo`, and `DependsOn`. The result is an auditable bootstrap and
review format for live memory, not a copy of a hidden object heap.

## Loading and Units

A filein can run in memory or attach a store directory:

```sh
filein path/to/example.mica
filein --store world-db --unit equipment path/to/example.mica
```

A _unit_ is a load-time label for the source of one or more files. The unit name comes from
`--unit`; without it, each file's base name without its extension is its own unit. Loading records
the expanded source text as `UnitSource(ordinal, unit, source)` facts, in file order.

Units are labels, not a replacement model. Loading a file into an existing store is a boot, not an
append: the store reconstructs the world from its durable state and the runner's file arguments are
ignored. To change definitions, edit the sources and load a fresh store.

Within one load, later files can extend earlier ones, and loading the same source twice in one
world is not required.

## Fileout

`fileout(:unit)` returns the source text loaded for that unit. When several files share a unit their
sources are joined with a blank line. Because the text is the expanded load input:

- grant blocks are already expanded to their `CanRead`, `CanWrite`, `CanInvoke`, `CanEffect`, and
  `RoleCan*` assertions;
- `include_text("path")` calls are replaced by the included text;
- unit text reflects exactly what the runtime compiled, not the original file.

`fileout_rules([:Relation])` returns the source of active rules, optionally restricted to one head
relation, with rules separated by a blank line. Rule source is each rule's own text, so
`describe_rule(#rule)` and `RuleSource` facts show the same span.

## Includes

Filein can include text files into compiled source with `include_text("path")`. The path is resolved
relative to the filed-in source file. This is intended for large text assets such as CSS and
JavaScript inside verbs:

```mica
verb page_style()
  return include_text("style.css")
end
```

The path uses ordinary Mica string escaping, including `\u{...}` for Unicode characters. The loader
inserts the file's contents as one string value. Quotes, backslashes, newlines, and control
characters in the asset retain their meaning as text; they do not become Mica expressions.

Fileout returns the text with includes already substituted, so a fileout source is self-contained;
the referenced asset files are not needed to file it back in.

## Grant Blocks

Filein also has a grant block surface for durable authorization policy facts. It is source sugar
over the ordinary policy relations, so the stored world still contains `CanRead`, `CanWrite`,
`CanInvoke`, `CanEffect`, and their `RoleCan*` counterparts:

The following complete filein creates its subjects and policy relations before granting authority:

```mica,filein
make_identity(:web)
make_identity(:reviewer)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:CanInvoke, 2)
make_relation(:CanEffect, 1)
make_relation(:RoleCanRead, 2)
make_relation(:RoleCanInvoke, 2)

grant #web
  read:
    :HttpRequest
    :RequestPath
  write:
    :RequestBody
  invoke:
    :http_request
    :http_response
  effect
end

grant role #reviewer
  read:
    :Label
    :ReviewStatus
  invoke:
    :approve
end
```

The first block expands to `Can*` assertions for `#web`; the second expands to `RoleCan*` assertions
for `#reviewer`.

## Store Interaction

When a store is attached, a filein load also persists its durable relations, rules, methods, and
identity names. A clean shutdown writes a checkpoint, and `--checkpoint` forces one explicitly.
Later commands boot from the store and can evaluate expressions without the sources:

```sh
filein --store world-db --eval 'return inspect(#alice, #sensor)'
```

See [Tasks and Transactions](./tasks-and-transactions.md) for durability modes and
[Runtime Overview](./index.md) for the host API.
