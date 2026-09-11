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
}
