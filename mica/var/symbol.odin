// Interned symbol identifiers.
//
// Symbols are the names used for relations, roles, columns, variables, error
// codes, and error/message kinds. Interning keeps `Value` payloads small and
// makes symbol comparison an integer comparison.
//
// The intern path is hot, so it has two thread-local caches in front of the
// global table: a one-entry most-recently-used slot and a small round-robin
// scan cache. Both hold the interned name, whose storage lives for the process
// lifetime, so a cache hit needs no lock.
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

@(private)
SYMBOL_CACHE_SIZE :: 16

@(private)
Symbol_Cache_Entry :: struct {
	valid:  bool,
	name:   string,
	symbol: Symbol,
}

@(thread_local)
symbol_cache: [SYMBOL_CACHE_SIZE]Symbol_Cache_Entry

@(thread_local)
symbol_cache_next: uint

@(thread_local)
symbol_recent_valid: bool

@(thread_local)
symbol_recent_name: string

@(thread_local)
symbol_recent_symbol: Symbol

// Returns the canonical symbol for `name`, creating one if needed.
//
// The table stores names for the life of the process, so it allocates from the
// runtime default allocator rather than the caller's context allocator.
symbol_intern :: proc(name: string) -> Symbol {
	if symbol_recent_valid && symbol_recent_name == name {
		return symbol_recent_symbol
	}
	for entry in symbol_cache {
		if entry.valid && entry.name == name {
			symbol_recent_valid = true
			symbol_recent_name = entry.name
			symbol_recent_symbol = entry.symbol
			return entry.symbol
		}
	}

	symbol, interned_name := symbol_table_intern(name)
	slot := int(symbol_cache_next % SYMBOL_CACHE_SIZE)
	symbol_cache_next = (symbol_cache_next + 1) % SYMBOL_CACHE_SIZE
	symbol_cache[slot] = Symbol_Cache_Entry {
		valid  = true,
		name   = interned_name,
		symbol = symbol,
	}

	symbol_recent_valid = true
	symbol_recent_name = interned_name
	symbol_recent_symbol = symbol
	return symbol
}

// Returns the name of a symbol, if the id is known.
symbol_name :: proc(s: Symbol) -> (string, bool) {
	if symbol_recent_valid && symbol_recent_symbol == s {
		return symbol_recent_name, true
	}
	for entry in symbol_cache {
		if entry.valid && entry.symbol == s {
			return entry.name, true
		}
	}

	sync.mutex_lock(&symbol_table.mutex)
	defer sync.mutex_unlock(&symbol_table.mutex)

	index := int(u32(s))
	if index < 0 || index >= len(symbol_table.names) {
		return "", false
	}
	return symbol_table.names[index], true
}

@(private)
symbol_table_intern :: proc(name: string) -> (Symbol, string) {
	sync.mutex_lock(&symbol_table.mutex)
	defer sync.mutex_unlock(&symbol_table.mutex)

	if symbol_table.by_name == nil {
		symbol_table.by_name = make(map[string]Symbol, runtime.default_allocator())
	}
	if symbol_table.names == nil {
		symbol_table.names = make([dynamic]string, 0, runtime.default_allocator())
	}
	if existing, ok := symbol_table.by_name[name]; ok {
		return existing, symbol_table.names[u32(existing)]
	}

	id := Symbol(u32(len(symbol_table.names)))
	owned := strings.clone(name, runtime.default_allocator())
	append(&symbol_table.names, owned)
	symbol_table.by_name[owned] = id
	return id, owned
}
