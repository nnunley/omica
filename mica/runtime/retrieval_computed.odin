// Exact nearest-neighbour computed relation for the shared retrieval schema.
package mica_runtime

import "core:math"
import "core:slice"

import k "../kernel"
import v "../var"

@(private)
Nearest_Candidate :: struct {
	subject: v.Value,
	score:   f64,
}

@(private)
numeric_value :: proc(value: v.Value) -> (f64, bool) {
	if integer, ok := v.value_as_int(value); ok {
		return f64(integer), true
	}
	if number, ok := v.value_as_float(value); ok {
		return f64(number), true
	}
	return 0, false
}

@(private)
cosine_similarity :: proc(query, candidate: []v.Value) -> (f64, bool) {
	if len(query) == 0 || len(query) != len(candidate) {
		return 0, false
	}
	dot := f64(0)
	query_norm := f64(0)
	candidate_norm := f64(0)
	for value, index in query {
		left, left_ok := numeric_value(value)
		right, right_ok := numeric_value(candidate[index])
		if !left_ok || !right_ok {
			return 0, false
		}
		dot += left * right
		query_norm += left * left
		candidate_norm += right * right
	}
	if query_norm == 0 || candidate_norm == 0 {
		return 0, false
	}
	return dot / (math.sqrt(query_norm) * math.sqrt(candidate_norm)), true
}

@(private)
nearest_embedding_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	if len(bindings) < 3 || !bindings[0].bound || !bindings[1].bound || !bindings[2].bound {
		return .Computed_Binding_Required
	}
	query, query_ok := v.value_as_list(bindings[1].value)
	limit, limit_ok := v.value_as_int(bindings[2].value)
	if !query_ok || !limit_ok || limit < 0 {
		return .Arity_Mismatch
	}
	if limit == 0 {
		return .None
	}
	contains_id, has_contains := computed_relation_id(source, "VectorIndexContains")
	embedding_of_id, has_embedding_of := computed_relation_id(source, "EmbeddingOf")
	vector_id, has_vector := computed_relation_id(source, "EmbeddingVector")
	if !has_contains || !has_embedding_of || !has_vector {
		return .None
	}

	members: [dynamic]v.Tuple
	k.relation_source_scan_into(source, contains_id, []v.Binding{bindings[0], {}}, &members)
	defer delete(members)
	candidates: [dynamic]Nearest_Candidate
	by_subject := make(map[v.Value]int, context.temp_allocator)
	defer delete(by_subject)
	for member in members {
		embedding := v.tuple_values(member)[1]
		subject_rows: [dynamic]v.Tuple
		vector_rows: [dynamic]v.Tuple
		k.relation_source_scan_into(
			source,
			embedding_of_id,
			[]v.Binding{v.binding_of(embedding), {}},
			&subject_rows,
		)
		k.relation_source_scan_into(
			source,
			vector_id,
			[]v.Binding{v.binding_of(embedding), {}},
			&vector_rows,
		)
		if len(subject_rows) == 1 && len(vector_rows) == 1 {
			subject := v.tuple_values(subject_rows[0])[1]
			vector, vector_ok := v.value_as_list(v.tuple_values(vector_rows[0])[1])
			if vector_ok {
				if score, score_ok := cosine_similarity(query, vector); score_ok {
					if existing, found := by_subject[subject]; found {
						if score > candidates[existing].score {
							candidates[existing].score = score
						}
					} else {
						by_subject[subject] = len(candidates)
						append(&candidates, Nearest_Candidate{subject = subject, score = score})
					}
				}
			}
		}
		delete(subject_rows)
		delete(vector_rows)
	}
	slice.sort_by(candidates[:], proc(a, b: Nearest_Candidate) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return v.value_cmp(a.subject, b.subject) == .Less
	})

	version := source.snapshot != nil ? source.snapshot.version : source.transaction.base.version
	selected := min(len(candidates), int(limit))
	for candidate in candidates[:selected] {
		score, score_ok := v.value_float(f32(candidate.score))
		if !score_ok {
			continue
		}
		row := v.tuple_new(
			context.temp_allocator,
			[]v.Value {
				bindings[0].value,
				bindings[1].value,
				bindings[2].value,
				candidate.subject,
				score,
				computed_int(version),
			},
		)
		if !visit(visit_user, row) {
			break
		}
	}
	return .None
}

install_retrieval_computed_relation :: proc(env: ^Builtin_Env) -> Run_Result {
	relation, found := env.ctx.relations["NearestEmbedding"]
	if !found {
		return Run_Result{ok = true}
	}
	if err := k.kernel_register_computed_relation(
		env.kernel,
		k.Relation_ID(relation),
		[]u16{0, 1, 2},
		nearest_embedding_scan,
		rawptr(env),
	); err != .None {
		return Run_Result{ok = false, message = "cannot register NearestEmbedding"}
	}
	return Run_Result{ok = true}
}
