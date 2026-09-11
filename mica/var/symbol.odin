// Interned symbol identifiers.
//
// Symbols are the names used for relations, roles, columns, variables, error
// codes, and error/message kinds. Interning keeps `Value` payloads small and
// makes symbol comparison an integer comparison.
package var

import "base:runtime"
import "core:strings"
import "core:sync"

// An interned symbol id.
Symbol :: distinct u32

// Returns the id of a symbol.
symbol_id :: proc(s: Symbol) -> u32 {
	return u32(s)
}

// Returns a symbol for a known id. The id must have been produced by
// `symbol_intern`; ids are stable for the lifetime of the process.
symbol_from_id :: proc(id: u32) -> Symbol {
	return Symbol(id)
}

@(private)
Symbol_Table :: struct {
	mutex:   sync.Mutex,
	by_name: map[string]Symbol,
	names:   [dynamic]string,
}

@(private)
symbol_table: Symbol_Table

// Returns the canonical symbol for `name`, creating one if needed.
//
// The table stores names for the life of the process, so it allocates from the
// runtime default allocator rather than the caller's context allocator.
symbol_intern :: proc(name: string) -> Symbol {
	sync.mutex_lock(&symbol_table.mutex)
	defer sync.mutex_unlock(&symbol_table.mutex)

	if symbol_table.by_name == nil {
		symbol_table.by_name = make(map[string]Symbol, runtime.default_allocator())
	}
	if symbol_table.names == nil {
		symbol_table.names = make([dynamic]string, 0, runtime.default_allocator())
	}
	if existing, ok := symbol_table.by_name[name]; ok {
		return existing
	}

	id := Symbol(u32(len(symbol_table.names)))
	owned := strings.clone(name, runtime.default_allocator())
	append(&symbol_table.names, owned)
	symbol_table.by_name[owned] = id
	return id
}

// Returns the name of a symbol, if the id is known.
symbol_name :: proc(s: Symbol) -> (string, bool) {
	sync.mutex_lock(&symbol_table.mutex)
	defer sync.mutex_unlock(&symbol_table.mutex)

	index := int(u32(s))
	if index < 0 || index >= len(symbol_table.names) {
		return "", false
	}
	return symbol_table.names[index], true
}
