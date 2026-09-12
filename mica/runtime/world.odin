// A long-lived world: kernel, compile context, builtins, subscriptions,
// scheduler, and program.
//
// `run_files` builds one, waits for its entry task, and destroys it. Hosts keep
// one alive and submit further tasks through `world_call` or
// `world_submit_call`.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import c "../compiler"
import s "../store"
import k "../kernel"
import vm "../vm"
import v "../var"

World_Config :: struct {
	// Name of the declared identity that submitted tasks run as. Empty keeps
	// every task at root.
	actor:   string,
	// Worker threads. Clamped to at least one.
	workers: int,
	// Filein unit name for `fileout`. Empty derives one unit per file from
	// the file's base name without its extension.
	unit:    string,
	// Durable store directory. When set and non-empty, the world boots from
	// the store; otherwise the given sources load and persist into it.
	store_path: string,
}

// A relation write applied to a task transaction before it starts.
World_Fact :: struct {
	relation: k.Relation_ID,
	tuple:    v.Tuple,
}

// Per-call identity overrides. Empty values keep the world defaults.
World_Call_Options :: struct {
	actor:     v.Value,
	principal: v.Value,
	endpoint:  v.Value,
}

World :: struct {
	kernel:    ^k.Kernel,
	allocator: mem.Allocator,
	ctx:       c.Compile_Context,
	env:       Builtin_Env,
	scheduler: Scheduler,
	program:   ^vm.Program,
	// Final expanded source text. Compile-context keys are views into it.
	sources:   [dynamic]string,
	// Attached durable store. Owned by the world.
	store:     ^s.Store,
	entry:     Task_ID,
	started:   bool,
}

// Loads a world and starts its scheduler. The entry task is submitted but not
// awaited; use `world_wait(world, world.entry)`.
world_start :: proc(
	kernel: ^k.Kernel,
	paths: []string,
	allocator := context.allocator,
	config := World_Config{},
) -> (
	^World,
	Run_Result,
) {
	world := new(World, allocator)
	world.allocator = allocator
	world.kernel = kernel
	world.sources = make([dynamic]string, allocator)

	if config.store_path != "" {
		durable := new(s.Store, allocator)
		if !s.store_open(durable, s.Store_Options {
			mode = .File,
			path = config.store_path,
		}) {
			free(durable, allocator)
			world_destroy(world)
			return nil, Run_Result{ok = false, message = fmt.aprintf(
				"cannot open the store at %s",
				config.store_path,
				allocator = allocator,
			)}
		}
		world.store = durable
		s.store_attach(durable, kernel)
	}

	if world.store != nil &&
	   (s.store_durable_version(world.store) > 0 ||
		   s.store_checkpoint_version(world.store) > 0) {
		result := world_boot(world, world.store, config)
		if !result.ok {
			world_destroy(world)
			return nil, result
		}
		return world, result
	}

	result := world_load(world, paths, config)
	if !result.ok {
		world_destroy(world)
		return nil, result
	}
	return world, result
}

// Stops the scheduler and frees everything the world owns. Safe to call on a
// partially loaded world.
world_destroy :: proc(world: ^World) {
	if world == nil {
		return
	}
	if world.started {
		scheduler_destroy(&world.scheduler)
	}
	if world.store != nil {
		k.kernel_detach_store(world.kernel)
		s.store_destroy(world.store)
		free(world.store, world.allocator)
		world.store = nil
	}
	subscriptions_destroy(&world.env.subscriptions)
	if world.program != nil {
		vm.program_destroy(world.program, world.allocator)
	}
	for source in world.sources {
		delete(source, world.allocator)
	}
	delete(world.sources)
	for _, &source in world.env.unit_sources {
		delete(source, world.allocator)
	}
	delete(world.env.unit_sources)
	for key, info in world.env.fields {
		if info.key_positions != nil {
			delete(info.key_positions, world.allocator)
		}
		delete(key, world.allocator)
	}
	delete(world.env.fields)
	delete(world.ctx.builtins)
	delete(world.ctx.relations)
	delete(world.ctx.identities)
	free(world, world.allocator)
}

// Submits a call to `selector` with `roles`. Returns 0 when no method resolves.
world_submit_call :: proc(
	world: ^World,
	selector: string,
	roles: []k.Role_Pair,
	delay_millis := i64(0),
) -> Task_ID {
	result := scheduler_submit_dispatch(
		&world.scheduler,
		&world.env,
		world.program,
		v.value_symbol(v.symbol_intern(selector)),
		roles,
		delay_millis,
	)
	return result.id
}

// Submits a call whose task transaction starts with `facts`. Returns a
// Dispatch_Result so callers can report why a submission failed.
world_submit_call_with_facts :: proc(
	world: ^World,
	selector: string,
	roles: []k.Role_Pair,
	facts: []World_Fact,
	delay_millis := i64(0),
) -> Dispatch_Result {
	return world_submit_call_with_options(world, selector, roles, facts, delay_millis, {})
}

// Submits a call with per-call identity overrides.
world_submit_call_with_options :: proc(
	world: ^World,
	selector: string,
	roles: []k.Role_Pair,
	facts: []World_Fact,
	delay_millis: i64,
	options: World_Call_Options,
) -> Dispatch_Result {
	return scheduler_submit_dispatch(
		&world.scheduler,
		&world.env,
		world.program,
		v.value_symbol(v.symbol_intern(selector)),
		roles,
		delay_millis,
		facts,
		options,
	)
}

// Applies facts from a host thread and dispatches subscriptions. Used for
// session facts that have no owning Mica task.
world_apply_facts :: proc(world: ^World, facts: []World_Fact) -> k.Kernel_Error {
	if len(facts) == 0 {
		return .None
	}
	tx := k.kernel_begin(world.kernel)
	defer k.transaction_destroy(&tx)
	for fact in facts {
		if err := k.transaction_assert(&tx, fact.relation, fact.tuple); err != .None {
			return err
		}
	}
	committed, err := k.transaction_commit(&tx)
	if err != .None {
		return err
	}
	k.snapshot_release(committed)
	subscriptions_dispatch(&world.env)
	return .None
}

// Waits for a submitted task to reach a terminal outcome.
world_wait :: proc(world: ^World, id: Task_ID) -> Task_Outcome {
	return scheduler_wait(&world.scheduler, id)
}

// Resumes a task parked on `read` (or another host request) with `value`.
world_resume :: proc(world: ^World, id: Task_ID, value: v.Value) -> bool {
	return scheduler_resume(&world.scheduler, id, value)
}

// Returns the `read` metadata for a parked task. The boolean reports whether
// the task is currently waiting for host input.
world_task_request :: proc(world: ^World, id: Task_ID) -> (v.Value, bool) {
	return scheduler_task_request(&world.scheduler, id)
}

// Frees a terminal task entry after its outcome is read.
world_release :: proc(world: ^World, id: Task_ID) {
	scheduler_release(&world.scheduler, id)
}

// Writes a chunk-page checkpoint of the current world state. Returns false
// when no store is attached or the checkpoint fails.
world_checkpoint :: proc(world: ^World) -> bool {
	if world.store == nil {
		return false
	}
	return s.store_checkpoint(world.store, world.kernel)
}

// Creates a host-owned mailbox. The returned receiver and sender are
// capability handles; the host drains the receiver and passes the sender to
// `world_subscribe_changes`.
world_mailbox_create :: proc(world: ^World) -> (receiver, sender: v.Value, ok: bool) {
	return scheduler_mailbox_create(&world.scheduler)
}

// Drains queued messages for a host-owned receiver.
world_mailbox_drain :: proc(world: ^World, receiver: v.Value) -> ([dynamic]v.Value, bool) {
	return scheduler_mailbox_drain(&world.scheduler, receiver, world.allocator)
}

// Registers a change subscription on behalf of the host. `sender` is a host
// mailbox sender handle; messages arrive on the paired receiver.
world_subscribe_changes :: proc(
	world: ^World,
	sender: v.Value,
	subject: Subscription_Subject,
	relation: k.Relation_ID,
	bindings: []v.Binding,
	initial_snapshot: bool,
	cursor: u64,
	has_cursor: bool,
	queue_budget: int,
) -> (
	v.Value,
	bool,
) {
	return subscriptions_register(
		&world.env,
		sender,
		subject,
		relation,
		bindings,
		initial_snapshot,
		cursor,
		has_cursor,
		queue_budget,
	)
}

// Cancels a host-registered subscription.
world_cancel_subscription :: proc(world: ^World, capability: v.Value) -> bool {
	return subscriptions_cancel(&world.env, capability)
}

// The world's default endpoint identity.
world_endpoint :: proc(world: ^World) -> v.Value {
	return world.env.endpoint
}

// The world's default principal and actor identities.
world_principal :: proc(world: ^World) -> v.Value {
	return world.env.principal
}

world_actor :: proc(world: ^World) -> v.Value {
	return world.env.actor
}

// Submits a call, waits for it, and frees the task entry.
world_call :: proc(world: ^World, selector: string, roles: []k.Role_Pair) -> Task_Outcome {
	id := world_submit_call(world, selector, roles)
	if id == 0 {
		return Task_Outcome{kind = .Aborted, message = "no applicable method"}
	}
	outcome := scheduler_wait(&world.scheduler, id)
	scheduler_release(&world.scheduler, id)
	return outcome
}

// --- Loading ---------------------------------------------------------------

// Derives a filein unit name from a path: the base name without its extension.
@(private)
source_unit_name :: proc(path: string) -> string {
	base := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		base = path[slash + 1:]
	}
	if dot := strings.last_index_byte(base, '.'); dot > 0 {
		base = base[:dot]
	}
	return base
}

@(private)
world_load :: proc(world: ^World, paths: []string, config: World_Config) -> Run_Result {
	allocator := world.allocator
	asts := make([dynamic]^c.Program_AST, allocator)
	defer delete(asts)

	Unit_Entry :: struct {
		name:    string,
		source:  string,
		ordinal: i64,
	}
	unit_entries: [dynamic]Unit_Entry
	unit_entries = make([dynamic]Unit_Entry, allocator)
	defer delete(unit_entries)

	for path in paths {
		data, read_err := os.read_entire_file(path, allocator)
		if read_err != nil {
			return Run_Result{ok = false, message = fmt.aprintf(
				"cannot read %s",
				path,
				allocator = allocator,
			)}
		}
		text := string(data)
		expanded, expand_result := substitute_include_text(
			text,
			filepath.dir(path),
			allocator,
		)
		if !expand_result.ok {
			return expand_result
		}
		if raw_data(expanded) != raw_data(text) {
			delete(data, allocator)
		}
		granted, grant_result := expand_grant_blocks(expanded, allocator)
		if !grant_result.ok {
			return grant_result
		}
		if raw_data(granted) != raw_data(expanded) {
			delete(expanded, allocator)
		}
		ast, parse_errors := c.parse_program(granted, allocator)
		if len(parse_errors) > 0 {
			first := parse_errors[0]
			return Run_Result{ok = false, message = fmt.aprintf(
				"%s:%d:%d: %s",
				path,
				first.line,
				first.column,
				first.message,
				allocator = allocator,
			)}
		}
		append(&asts, ast)
		append(&world.sources, granted)
		unit_name := config.unit
		if unit_name == "" {
			unit_name = source_unit_name(path)
		}
		if unit_name != "" {
			append(&unit_entries, Unit_Entry {
				name    = unit_name,
				source  = granted,
				ordinal = i64(len(unit_entries)),
			})
		}
	}

	world.ctx = c.Compile_Context {
		builtins   = make(map[string]bool, allocator),
		relations  = make(map[string]u32, allocator),
		identities = make(map[string]v.Value, allocator),
	}
	install_builtin_names(&world.ctx)
	install_primitive_identities(&world.ctx)

	world.env = Builtin_Env {
		kernel       = world.kernel,
		ctx          = &world.ctx,
		fields       = make(map[string]Field_Info, allocator),
		unit_sources = make(map[string]string, allocator),
		allocator    = allocator,
	}
	unit_facts: [dynamic]Unit_Source_Fact
	defer delete(unit_facts)
	for entry in unit_entries {
		if existing, found := world.env.unit_sources[entry.name]; found {
			combined := strings.concatenate(
				[]string{existing, "\n\n", entry.source},
				allocator,
			)
			delete(existing, allocator)
			world.env.unit_sources[entry.name] = combined
		} else {
			world.env.unit_sources[entry.name] = strings.clone(entry.source, allocator)
		}
		append(&unit_facts, Unit_Source_Fact {
			ordinal = entry.ordinal,
			unit    = v.symbol_intern(entry.name),
			source  = entry.source,
		})
	}
	subscriptions_init(&world.env.subscriptions, allocator)

	declarations := Declarations {
		next_relation = 1,
		next_identity = 0x1000,
		next_rule     = 1,
	}
	endpoint_identity, endpoint_ok := v.value_identity_raw(declarations.next_identity)
	declarations.next_identity += 1
	actor_identity, actor_ok := v.value_identity_raw(declarations.next_identity)
	declarations.next_identity += 1
	if endpoint_ok && actor_ok {
		world.env.endpoint = endpoint_identity
		world.env.actor = actor_identity
		world.env.principal = actor_identity
	}

	dispatch_result := install_dispatch_relations(&world.env)
	if !dispatch_result.ok {
		return dispatch_result
	}

	for ast in asts {
		result := prescan_file(&world.env, ast, &declarations)
		if !result.ok {
			return result
		}
	}
	identity_result := assert_named_identities(&world.env, declarations.named_identities[:])
	if !identity_result.ok {
		return identity_result
	}
	delete(declarations.named_identities)
	unit_result := assert_unit_sources(&world.env, unit_facts[:])
	if !unit_result.ok {
		return unit_result
	}
	if config.actor != "" {
		actor_value, actor_found := world.ctx.identities[config.actor]
		if !actor_found {
			return Run_Result{ok = false, message = fmt.aprintf(
				"unknown authority actor: %s",
				config.actor,
				allocator = allocator,
			)}
		}
		world.env.actor = actor_value
		world.env.principal = actor_value
	}

	for path, index in paths {
		source := ""
		if index < len(world.sources) {
			source = world.sources[index]
		}
		result := install_rules(
			&world.env,
			world.kernel,
			asts[index],
			&declarations,
			path,
			source,
		)
		if !result.ok {
			return result
		}
	}

	method_result := install_methods(
		&world.env,
		asts[:],
		world.sources[:],
		&declarations,
	)
	if !method_result.ok {
		return method_result
	}

	items := make([dynamic]c.Item, allocator)
	defer delete(items)
	for ast in asts {
		for item in ast.items {
			append(&items, item)
		}
	}
	program_ast := c.Program_AST {
		items = items[:],
	}

	compiled := c.compile_program(&program_ast, &world.ctx, allocator)
	if len(compiled.errors) > 0 {
		if _, show_all := os.lookup_env("MICA_ALL_ERRORS", context.allocator); show_all {
			for compile_error in compiled.errors {
				fmt.eprintln(compile_error.message)
			}
		}
		return Run_Result{ok = false, message = compiled.errors[0].message}
	}
	world.program = compiled.program

	// The entry task runs root so declarations and grant facts can load.
	workers := config.workers
	if workers < 1 {
		workers = 1
	}
	scheduler_init(
		&world.scheduler,
		world.kernel,
		Scheduler_Config{workers = workers},
		allocator,
	)
	world.started = true
	world.env.scheduler = &world.scheduler

	entry := new(Task, allocator)
	task_init(entry, 0, world.kernel, world.program, &world.env, allocator)
	if config.actor != "" {
		world.env.enforce_authority = true
	}
	world.entry = scheduler_submit(&world.scheduler, entry)
	return Run_Result{ok = true, message = "loaded"}
}

// Boots a world from an attached store: replay the kernel, rebuild the compile
// context from durable reflection facts, recompile the persisted unit sources,
// restore rules, and start the scheduler. The entry task is not submitted
// because every top-level expression already ran in the original world.
@(private)
world_boot :: proc(world: ^World, store: ^s.Store, config: World_Config) -> Run_Result {
	allocator := world.allocator
	// Replay without persistence hooks so restored commits do not append to
	// the log they were read from.
	k.kernel_detach_store(world.kernel)
	if !s.store_restore(store, world.kernel) {
		s.store_attach(store, world.kernel)
		return Run_Result{ok = false, message = "cannot restore the stored world"}
	}
	s.store_attach(store, world.kernel)

	world.ctx = c.Compile_Context {
		builtins                            = make(map[string]bool, allocator),
		relations                           = make(map[string]u32, allocator),
		identities                          = make(map[string]v.Value, allocator),
		dispatch_method_selector_relation   = u32(k.DISPATCH_METHOD_SELECTOR_ID),
		dispatch_param_relation             = u32(k.DISPATCH_PARAM_ID),
		dispatch_delegates_relation         = u32(k.DISPATCH_DELEGATES_ID),
		dispatch_method_program_relation    = u32(k.DISPATCH_METHOD_PROGRAM_ID),
	}
	install_builtin_names(&world.ctx)
	install_primitive_identities(&world.ctx)
	world.env = Builtin_Env {
		kernel       = world.kernel,
		ctx          = &world.ctx,
		fields       = make(map[string]Field_Info, allocator),
		unit_sources = make(map[string]string, allocator),
		allocator    = allocator,
	}
	subscriptions_init(&world.env.subscriptions, allocator)

	// The catalogue supplies the relation name -> id map plus the functional
	// field metadata used by `record.field` access.
	catalog := k.kernel_snapshot(world.kernel)
	for metadata in catalog.catalog {
		name, has_name := v.symbol_name(metadata.name)
		if !has_name {
			continue
		}
		world.ctx.relations[name] = u32(metadata.id)
		if metadata.conflict.kind != .Functional {
			continue
		}
		key_positions := make([]u16, len(metadata.conflict.key_positions), allocator)
		copy(key_positions, metadata.conflict.key_positions)
		world.env.fields[lower_first(name, allocator)] = Field_Info {
			relation      = metadata.id,
			key_positions = key_positions,
		}
	}
	k.snapshot_release(catalog)

	// NamedIdentity facts supply `#name` resolution.
	name_rows: [dynamic]v.Tuple
	defer delete(name_rows)
	k.kernel_scan_into(world.kernel, k.SYSTEM_NAMED_IDENTITY_ID, []v.Binding{{}, {}}, &name_rows)
	for row in name_rows {
		values := v.tuple_values(row)
		name, has_name := v.value_as_symbol(values[1])
		if !has_name {
			continue
		}
		name_text, has_text := v.symbol_name(name)
		if has_text {
			world.ctx.identities[name_text] = values[0]
		}
	}

	// UnitSource facts supply fileout text and the recompilation order.
	unit_rows: [dynamic]v.Tuple
	defer delete(unit_rows)
	k.kernel_scan_into(world.kernel, k.SYSTEM_UNIT_SOURCE_ID, []v.Binding{{}, {}, {}}, &unit_rows)
	ordered_sources: [dynamic]string
	defer delete(ordered_sources)
	for row in unit_rows {
		values := v.tuple_values(row)
		unit, has_unit := v.value_as_symbol(values[1])
		source, has_source := v.value_as_string(values[2])
		has_name := false
		name := ""
		if has_unit {
			name, has_name = v.symbol_name(unit)
		}
		if !has_source || !has_name {
			continue
		}
		if existing, found := world.env.unit_sources[name]; found {
			world.env.unit_sources[name] = strings.concatenate(
				[]string{existing, "\n\n", source},
				allocator,
			)
		} else {
			world.env.unit_sources[name] = strings.clone(source, allocator)
		}
		append(&ordered_sources, world.env.unit_sources[name])
	}

	// Runtime context identities: allocate above every stored identity.
	next_identity := max_stored_identity(world.kernel) + 1
	endpoint_identity, endpoint_ok := v.value_identity_raw(next_identity)
	next_identity += 1
	actor_identity, actor_ok := v.value_identity_raw(next_identity)
	if endpoint_ok && actor_ok {
		world.env.endpoint = endpoint_identity
		world.env.actor = actor_identity
		world.env.principal = actor_identity
	}
	if config.actor != "" {
		actor_value, actor_found := world.ctx.identities[config.actor]
		if !actor_found {
			return Run_Result{ok = false, message = fmt.aprintf(
				"unknown authority actor: %s",
				config.actor,
				allocator = allocator,
			)}
		}
		world.env.actor = actor_value
		world.env.principal = actor_value
	}

	// Recompile the same concatenated sources; function indices must match the
	// persisted MethodProgram facts.
	items: [dynamic]c.Item
	defer delete(items)
	for source in ordered_sources {
		ast, parse_errors := c.parse_program(source, allocator)
		if len(parse_errors) > 0 {
			return Run_Result{ok = false, message = fmt.aprintf(
				"cannot reparse stored source: %s",
				parse_errors[0].message,
				allocator = allocator,
			)}
		}
		for item in ast.items {
			append(&items, item)
		}
	}
	program_ast := c.Program_AST {
		items = items[:],
	}
	compiled := c.compile_program(&program_ast, &world.ctx, allocator)
	if len(compiled.errors) > 0 {
		return Run_Result{ok = false, message = compiled.errors[0].message}
	}
	world.program = compiled.program

	rule_result := restore_rules(world)
	if !rule_result.ok {
		return rule_result
	}

	workers := config.workers
	if workers < 1 {
		workers = 1
	}
	scheduler_init(
		&world.scheduler,
		world.kernel,
		Scheduler_Config{workers = workers},
		allocator,
	)
	world.started = true
	world.env.scheduler = &world.scheduler
	if config.actor != "" {
		world.env.enforce_authority = true
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Reinstalls rule definitions from the durable Rule/RuleSource/ActiveRule
// reflection facts. The lowered bodies are not persisted, so they are parsed
// and converted again here.
@(private)
restore_rules :: proc(world: ^World) -> Run_Result {
	rule_rows: [dynamic]v.Tuple
	defer delete(rule_rows)
	k.kernel_scan_into(world.kernel, k.SYSTEM_RULE_ID, []v.Binding{{}}, &rule_rows)

	inactive: [dynamic]v.Value
	defer delete(inactive)
	for row in rule_rows {
		rule_id := v.tuple_values(row)[0]
		source_rows: [dynamic]v.Tuple
		k.kernel_scan_into(
			world.kernel,
			k.SYSTEM_RULE_SOURCE_ID,
			[]v.Binding{v.binding_of(rule_id), {}},
			&source_rows,
		)
		if len(source_rows) == 0 {
			delete(source_rows)
			continue
		}
		source_values := v.tuple_values(source_rows[0])
		source, has_source := v.value_as_string(source_values[1])
		delete(source_rows)
		if !has_source {
			continue
		}
		ast, parse_errors := c.parse_program(source, world.allocator)
		if len(parse_errors) > 0 {
			return Run_Result{ok = false, message = fmt.aprintf(
				"cannot reparse stored rule: %s",
				parse_errors[0].message,
				allocator = world.allocator,
			)}
		}
		rule_item: c.Rule_Item
		found_rule := false
		for item in ast.items {
			if candidate, is_rule := item.(c.Rule_Item); is_rule {
				rule_item = candidate
				found_rule = true
				break
			}
		}
		if !found_rule {
			continue
		}
		rule, rule_ok := convert_rule(rule_item, &world.ctx)
		if !rule_ok {
			return Run_Result{ok = false, message = "cannot lower stored rule"}
		}
		identity, identity_ok := v.value_as_identity(rule_id)
		if !identity_ok {
			continue
		}
		installed, install_error := k.kernel_install_rule(
			world.kernel,
			identity,
			rule,
			source,
		)
		if install_error != k.Kernel_Error.None {
			return Run_Result{ok = false, message = fmt.aprintf(
				"cannot restore rule: %v",
				install_error,
				allocator = world.allocator,
			)}
		}
		k.snapshot_release(installed)

		active_rows: [dynamic]v.Tuple
		k.kernel_scan_into(
			world.kernel,
			k.SYSTEM_ACTIVE_RULE_ID,
			[]v.Binding{v.binding_of(rule_id), v.binding_of(v.value_bool(false))},
			&active_rows,
		)
		if len(active_rows) > 0 {
			append(&inactive, rule_id)
		}
		delete(active_rows)
	}
	for rule_id in inactive {
		identity, identity_ok := v.value_as_identity(rule_id)
		if !identity_ok {
			continue
		}
		disabled, disable_error := k.kernel_set_rule_active(world.kernel, identity, false)
		if disable_error == k.Kernel_Error.None {
			k.snapshot_release(disabled)
		}
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Highest raw identity stored in NamedIdentity or MethodSelector facts.
@(private)
max_stored_identity :: proc(kernel: ^k.Kernel) -> u64 {
	maximum := u64(0)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, k.SYSTEM_NAMED_IDENTITY_ID, []v.Binding{{}, {}}, &rows)
	for row in rows {
		if identity, is_identity := v.value_as_identity(v.tuple_values(row)[0]); is_identity {
			maximum = max(maximum, v.identity_raw(identity))
		}
	}
	delete(rows)
	rows = make([dynamic]v.Tuple, context.temp_allocator)
	k.kernel_scan_into(kernel, k.DISPATCH_METHOD_SELECTOR_ID, []v.Binding{{}, {}}, &rows)
	for row in rows {
		if identity, is_identity := v.value_as_identity(v.tuple_values(row)[0]); is_identity {
			maximum = max(maximum, v.identity_raw(identity))
		}
	}
	return maximum
}
