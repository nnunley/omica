// Kernel error codes.
package kernel

// Errors produced by kernel operations.
Kernel_Error :: enum {
	None,
	Unknown_Relation,
	Arity_Mismatch,
	Non_Persistent_Value,
	Functional_Key_Violation,
	Conflict,
	Duplicate_Relation_Name,
	Invalid_Metadata,
	No_Such_Rule,
	Unstratified_Negation,
	Unsafe_Negation,
	Unsafe_Guard,
	Unbound_Head_Variable,
	Read_Only,
	// A revision-checked buffer apply already happened for this buffer in this
	// transaction, so later mutations would address offsets it invalidated.
	Already_Applied,
	// The entry was killed. Its id and name are never reused, so a stale
	// reference fails here rather than aliasing a new object.
	Killed,
	// The durable store refused admission; the transaction did not publish.
	Overloaded,
}
