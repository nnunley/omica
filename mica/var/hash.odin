// Value and tuple hashing.
//
// `value_hash` is consistent with canonical equality: when `value_eq(a, b)`
// holds, `value_hash(a) == value_hash(b)`. The hash is used for fast
// membership checks in rule evaluation and other dedup paths. It is not a
// persisted identifier.
package var

@(private)
HASH_SEED :: u64(0xcbf2_9ce4_8422_2325)

@(private)
HASH_PRIME :: u64(0x0000_0100_0000_01b3)

@(private)
hash_mix :: proc(hash: u64, value: u64) -> u64 {
	return (hash ~ value) * HASH_PRIME
}

@(private)
hash_bytes :: proc(hash: u64, data: []u8) -> u64 {
	result := hash
	for byte in data {
		result = (result ~ u64(byte)) * HASH_PRIME
	}
	return result
}

// Returns a hash consistent with `value_eq`.
value_hash :: proc(v: Value) -> u64 {
	hash := hash_mix(HASH_SEED, u64(value_kind(v)))
	switch value_kind(v) {
	case .Bool, .Int, .Float, .Identity, .Symbol, .Error_Code, .Capability, .Function:
		return hash_mix(hash, value_payload(v))
	case .String:
		text, _ := value_as_string(v)
		return hash_bytes(hash, transmute([]u8)text)
	case .Bytes:
		data, _ := value_as_bytes(v)
		return hash_bytes(hash, data)
	case .List:
		values, _ := value_as_list(v)
		hash = hash_mix(hash, u64(len(values)))
		for item in values {
			hash = hash_mix(hash, value_hash(item))
		}
		return hash
	case .Map:
		entries, _ := value_as_map(v)
		hash = hash_mix(hash, u64(len(entries)))
		for entry in entries {
			hash = hash_mix(hash, value_hash(entry.key))
			hash = hash_mix(hash, value_hash(entry.value))
		}
		return hash
	case .Range:
		start, end, has_end, _ := value_as_range(v)
		hash = hash_mix(hash, value_hash(start))
		hash = hash_mix(hash, has_end ? 1 : 0)
		if has_end {
			hash = hash_mix(hash, value_hash(end))
		}
		return hash
	case .Error:
		error, _ := value_as_error(v)
		hash = hash_mix(hash, u64(symbol_id(error.code)))
		hash = hash_mix(hash, error.has_message ? 1 : 0)
		if error.has_message {
			hash = hash_bytes(hash, transmute([]u8)error.message)
		}
		hash = hash_mix(hash, error.has_value ? 1 : 0)
		if error.has_value {
			hash = hash_mix(hash, value_hash(error.value))
		}
		return hash
	case .Frob:
		frob, _ := value_as_frob(v)
		hash = hash_mix(hash, identity_raw(frob.delegate))
		return hash_mix(hash, value_hash(frob.value))
	case .Relation:
		relation, _ := value_as_relation(v)
		hash = hash_mix(hash, u64(len(relation.heading)))
		for column in relation.heading {
			hash = hash_mix(hash, u64(symbol_id(column)))
		}
		hash = hash_mix(hash, u64(len(relation.rows)))
		for row in relation.rows {
			hash = hash_mix(hash, tuple_hash(row))
		}
		return hash
	}
	return hash
}

// Returns a hash consistent with `tuple_eq`.
tuple_hash :: proc(t: Tuple) -> u64 {
	hash := hash_mix(HASH_SEED, u64(tuple_arity(t)))
	for value in tuple_values(t) {
		hash = hash_mix(hash, value_hash(value))
	}
	return hash
}
