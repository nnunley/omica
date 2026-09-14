# Mica mode for Lem

A [Lem](https://lem-project.github.io/) major mode for the Mica surface
language: `mica-mode`.

## Features

- **Syntax highlighting** for `//` comments, `"..."` and `b"..."` strings,
  keywords, `true`/`false`, the `make_*` builtins, contextual words
  (`dom`, `exactly`, `grant`), `#identity` values, `:relation`/`:symbol` names,
  `?query` variables, `E_*` error codes, numbers, and operators (including the
  `:-` rule operator).
- **Indentation** for `end`-terminated blocks (`if`, `for`, `while`, `verb`,
  `fn`, `method`, `try`, ...) and for `:-` rule bodies, which run until a blank
  line.
- `//` line comments and a two-space indent.

Files ending in `.mica` open in `mica-mode` automatically.

The token tables mirror `mica/compiler/lexer.odin`; keep them in sync when the
language's keywords or punctuation change.

## Layout

| File | Purpose |
| --- | --- |
| `mica-mode.lisp` | The mode: syntax table, TextMate-style grammar, indentation |
| `lem-mica-mode.asd` | ASDF system definition (`lem-mica-mode`) |

## Installation

### Load the file directly

The mode is self-contained and only depends on Lem's own
`lem`/`lem/language-mode` packages:

```lisp
(load "/path/to/omica/editors/lem/mica-mode.lisp")
```

### As an ASDF system

Put this directory on an ASDF source registry (or symlink it into
`~/.lem/local-extensions/`), `asdf:load-system "lem-mica-mode"`, and the
`define-file-type` form registers `.mica` with `mica-mode`.

## Future

Highlighting here is regex-based. The intended direction is a language server
(`mica-ls`) that supplies semantic tokens, diagnostics, navigation, and
completion; this mode would then mostly provide the major mode, indentation,
and the client connection. See `lsp-design-doc.md` at the repository root.
