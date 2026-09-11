package web

import "core:fmt"
import "core:os"
import "core:testing"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(private)
write_document_source :: proc(t: ^testing.T, name, source: string) -> (string, bool) {
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return "", false
	}
	path := fmt.aprintf("%s/%s", directory, name, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, transmute([]byte)source); write_err != nil {
		testing.expect(t, false, "cannot write the document source")
		return "", false
	}
	return path, true
}

@(private)
expect_rows :: proc(t: ^testing.T, kernel: ^k.Kernel, name: string, expected: int) {
	snapshot := k.kernel_snapshot(kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	k.snapshot_release(snapshot)
	testing.expect(t, found)
	if !found {
		return
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	k.kernel_scan_into(kernel, metadata.id, bindings, &rows)
	defer delete(rows)
	testing.expectf(t, len(rows) == expected, "%s has %d rows, expected %d", name, len(rows), expected)
}

@(test)
test_documents_dispatch_fixture :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:HttpRequest, 1, :volatile)
make_relation(:RequestMethod, 2, :volatile)
make_relation(:RequestPath, 2, :volatile)
make_relation(:Out, 1)

verb http_request(request)
  let exactly {:m -> m} = RequestMethod(request, ?m)
  let exactly {:p -> p} = RequestPath(request, ?p)
  if m == "GET" && p == "/hello"
    assert Out(1)
    return {:status -> 200, :headers -> [["content-type", "text/plain"]], :body -> "hello"}
  end
  return {:status -> 404, :body -> "missing"}
end
`
	path, path_ok := write_document_source(t, "mica_documents_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)

	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	documents: Documents
	documents_init(&documents, world)

	request := Http_Request {
		method  = "GET",
		target  = "/hello",
		version = "HTTP/1.1",
		close   = true,
	}
	response: Http_Response
	documents_handle(&documents, &request, &response)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "hello")
	testing.expect_value(t, len(response.headers), 1)
	testing.expect_value(t, response.headers[0].name, "content-type")
	testing.expect_value(t, response.headers[0].value, "text/plain")

	missing := Http_Request {
		method  = "GET",
		target  = "/nope",
		version = "HTTP/1.1",
		close   = true,
	}
	missing_response: Http_Response
	documents_handle(&documents, &missing, &missing_response)
	testing.expect_value(t, missing_response.status, 404)
	testing.expect_value(t, string(missing_response.body), "missing")

	expect_rows(t, &kernel, "Out", 1)
}
