# Editor support

Editor integrations for Mica live here, one directory per editor. They are
maintained in-tree so the language, its grammar, and its tooling can move
together.

| Editor | Directory | Status |
| --- | --- | --- |
| Lem | [`lem/`](./lem/) | `mica-mode`: highlighting + indentation |
| shared TextMate grammar | `textmate/` | planned; reused by editors without LSP |
| VS Code, Neovim, Helix, Kate, ... | | planned, expected to lean on the language server |

## Direction: a language server

Highlighting today is regex-based and duplicated per editor. The intended
direction is a single language server (`mica-ls`) that serves semantic tokens,
diagnostics, navigation, and completion to every editor at once, leaving the
TextMate grammars as fallbacks. See [`lsp-design-doc.md`](../lsp-design-doc.md).

## Conventions

- One directory per editor, named after the editor (`lem`, `vscode`, ...).
- Keep editor-neutral assets (for example a shared `*.tmLanguage.json`) in
  `textmate/`, and let each editor's glue load them, rather than re-encoding
  the grammar per editor.
- Every editor directory has a `README.md` with install and usage notes.
- These directories are not part of the Odin build; `scripts/test.sh` builds an
  explicit tool list and ignores `editors/`.
