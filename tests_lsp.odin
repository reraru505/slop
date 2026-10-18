package main

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:encoding/json"

@(test)
test_lsp_server_discovery :: proc(t: ^testing.T) {
    ols_cmd, ols_found := lsp_find_server_cmd(.Odin)
    testing.expect_value(t, ols_found, true)
    testing.expect_value(t, len(ols_cmd) > 0, true)

    zls_cmd, zls_found := lsp_find_server_cmd(.Zig)
    testing.expect_value(t, zls_found, true)
    testing.expect_value(t, len(zls_cmd) > 0, true)

    clangd_cmd, clangd_found := lsp_find_server_cmd(.Clangd)
    testing.expect_value(t, clangd_found, true)
    testing.expect_value(t, len(clangd_cmd) > 0, true)

    rust_cmd, rust_found := lsp_find_server_cmd(.Rust)
    testing.expect_value(t, rust_found, true)
    testing.expect_value(t, len(rust_cmd) > 0, true)

    gopls_cmd, gopls_found := lsp_find_server_cmd(.Go)
    testing.expect_value(t, gopls_found, true)
    testing.expect_value(t, len(gopls_cmd) > 0, true)

    c3_cmd, c3_found := lsp_find_server_cmd(.C3)
    testing.expect_value(t, c3_found, true)
    testing.expect_value(t, len(c3_cmd) > 0, true)
    fmt.println("  ✓ [LSP Unit] Server discovery verified (ols, zls, clangd, rust-analyzer, gopls, c3lsp)")
}

@(test)
test_lsp_language_mapping :: proc(t: ^testing.T) {
    srv, has := language_to_server_kind(.Odin)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Odin)

    srv, has = language_to_server_kind(.Zig)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Zig)

    srv, has = language_to_server_kind(.C)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Clangd)

    srv, has = language_to_server_kind(.Cpp)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Clangd)

    srv, has = language_to_server_kind(.Rust)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Rust)

    srv, has = language_to_server_kind(.Go)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.Go)

    srv, has = language_to_server_kind(.C3)
    testing.expect_value(t, has, true)
    testing.expect_value(t, srv, LspServerKind.C3)

    // Languages without language server
    _, has = language_to_server_kind(.Hare)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Rela)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Bash)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Lua)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Toml)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Kdl)
    testing.expect_value(t, has, false)

    _, has = language_to_server_kind(.Makefile)
    testing.expect_value(t, has, false)
    fmt.println("  ✓ [LSP Unit] Language-to-server routing mapping verified")
}

@(test)
test_lsp_project_root_detection :: proc(t: ^testing.T) {
    // Current editor repo has a .git directory
    editor_file := "/home/fnln/Intrusive/text-editor/main.odin"
    root := lsp_find_project_root(editor_file, "/tmp")
    defer delete(root)

    abs_expected, _ := filepath.abs("/home/fnln/Intrusive/text-editor", context.temp_allocator)
    testing.expect_value(t, root, abs_expected)

    // Fallback directory when no markers exist
    fb_root := lsp_find_project_root("/tmp/non_existent_dir_1234/test.odin", "/var/tmp")
    defer delete(fb_root)
    testing.expect_value(t, fb_root, "/var/tmp")
    fmt.println("  ✓ [LSP Unit] Project root detection & fallback verified")
}

@(test)
test_lsp_json_escaping :: proc(t: ^testing.T) {
    raw := "hello \"world\"\nnew line\ttab\\backslash\r"
    escaped := lsp_json_escape(raw, context.allocator)
    defer delete(escaped)

    expected := "hello \\\"world\\\"\\nnew line\\ttab\\\\backslash\\r"
    testing.expect_value(t, escaped, expected)
    fmt.println("  ✓ [LSP Unit] JSON escape sequences (quotes, newlines, tabs) verified")
}

@(test)
test_lsp_language_ids :: proc(t: ^testing.T) {
    testing.expect_value(t, language_id_string(.Odin), "odin")
    testing.expect_value(t, language_id_string(.Zig), "zig")
    testing.expect_value(t, language_id_string(.C), "c")
    testing.expect_value(t, language_id_string(.Cpp), "cpp")
    testing.expect_value(t, language_id_string(.Rust), "rust")
    testing.expect_value(t, language_id_string(.Go), "go")
    testing.expect_value(t, language_id_string(.C3), "c3")

    // Languages without a server use the generic plaintext id
    testing.expect_value(t, language_id_string(.Hare), "plaintext")
    testing.expect_value(t, language_id_string(.Rela), "plaintext")
    testing.expect_value(t, language_id_string(.Bash), "plaintext")
    testing.expect_value(t, language_id_string(.Lua), "plaintext")
    testing.expect_value(t, language_id_string(.Toml), "plaintext")
    testing.expect_value(t, language_id_string(.Kdl), "plaintext")
    testing.expect_value(t, language_id_string(.Makefile), "plaintext")
    testing.expect_value(t, language_id_string(.Plaintext), "plaintext")
    fmt.println("  ✓ [LSP Unit] languageId strings for every language verified")
}

@(test)
test_lsp_language_detection_extended :: proc(t: ^testing.T) {
    testing.expect_value(t, language_from_file_path("build.zon"), LanguageKind.Zig)
    testing.expect_value(t, language_from_file_path("app.hpp"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("app.cxx"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("app.hh"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("app.hxx"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("script.zsh"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path("rules.mk"), LanguageKind.Makefile)
    testing.expect_value(t, language_from_file_path(".bashrc"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path(".profile"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path(".zshrc"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path("src/nested/main.go"), LanguageKind.Go)
    testing.expect_value(t, language_from_file_path("no_extension"), LanguageKind.Plaintext)
    testing.expect_value(t, language_from_file_path(""), LanguageKind.Plaintext)
    fmt.println("  ✓ [LSP Unit] extended extension and dotfile detection verified")
}

@(test)
test_lsp_uri_edge_cases :: proc(t: ^testing.T) {
    // Relative paths are converted to absolute URIs
    uri := lsp_path_to_uri("main.odin", context.temp_allocator)
    testing.expect_value(t, strings.has_prefix(uri, "file:///"), true)
    testing.expect_value(t, strings.has_suffix(uri, "/main.odin"), true)

    // A relative path for a not-yet-created file still resolves against the cwd
    missing_uri := lsp_path_to_uri("zzz_nonexistent_file_98765.odin", context.temp_allocator)
    testing.expect_value(t, strings.has_prefix(missing_uri, "file:///"), true)
    testing.expect_value(t, strings.has_suffix(missing_uri, "/zzz_nonexistent_file_98765.odin"), true)

    // Spaces and unicode survive a roundtrip (the client does not percent-encode)
    orig := "/tmp/some dir/файл.odin"
    uri2 := lsp_path_to_uri(orig, context.temp_allocator)
    back := lsp_uri_to_path(uri2, context.temp_allocator)
    testing.expect_value(t, back, orig)

    // Non-file URIs are passed through unchanged
    passthrough := lsp_uri_to_path("https://example.com/x", context.temp_allocator)
    testing.expect_value(t, passthrough, "https://example.com/x")
    fmt.println("  ✓ [LSP Unit] relative/space/unicode URI handling verified")
}

@(test)
test_lsp_json_escape_control_chars :: proc(t: ^testing.T) {
    escaped := lsp_json_escape("a\tb\r\nc\\d\"e", context.temp_allocator)
    testing.expect_value(t, escaped, "a\\tb\\r\\nc\\\\d\\\"e")

    plain := lsp_json_escape("symbol_123", context.temp_allocator)
    testing.expect_value(t, plain, "symbol_123")
    fmt.println("  ✓ [LSP Unit] JSON escaping of tab/CR/LF/backslash/quote verified")
}

// --- Response/notification parsing (no server process needed) --------------

lsp_test_parse_object :: proc(text: string) -> (json.Object, bool) {
    val, err := json.parse_string(text, allocator = context.temp_allocator)
    if err != nil do return nil, false
    obj, ok := val.(json.Object)
    return obj, ok
}

lsp_test_clear_completions :: proc(client: ^LspClient) {
    for c in client.completions {
        delete(c.label)
        delete(c.detail)
        delete(c.documentation)
        delete(c.insert_text)
    }
    clear(&client.completions)
}

lsp_test_clear_diagnostics :: proc(client: ^LspClient) {
    keys := make([dynamic]string, 0, len(client.diagnostics), context.temp_allocator)
    for key, _ in client.diagnostics do append(&keys, key)
    for key in keys {
        diags := client.diagnostics[key]
        for d in diags do delete(d.message)
        delete(diags)
        delete_key(&client.diagnostics, key)
        delete(key)
    }
    delete(client.diagnostics)
    client.diagnostics = nil
}

lsp_test_cleanup :: proc(client: ^LspClient) {
    for req in client.pending_requests {
        if req.file_path != "" do delete(req.file_path)
    }
    delete(client.pending_requests)
    lsp_test_clear_completions(client)
    delete(client.completions)
    if client.last_hover != "" do delete(client.last_hover)
    for e in client.last_edits do delete(e.new_text)
    delete(client.last_edits)
    if loc, ok := client.last_definition.?; ok && loc.file_path != "" {
        delete(loc.file_path)
    }
    lsp_test_clear_diagnostics(client)
    delete(client.file_versions)
}

@(test)
test_lsp_publish_diagnostics_parsing :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)

    path := "/tmp/odin_lsp_diag_test.odin"
    msg := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/odin_lsp_diag_test.odin","diagnostics":[{"range":{"start":{"line":2,"character":3},"end":{"line":2,"character":7}},"severity":1,"message":"bad thing"}]}}`
    obj, ok := lsp_test_parse_object(msg)
    testing.expect_value(t, ok, true)
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", obj, nil)

    // This file intentionally does not exist, exercising the lexical fallback
    // for realpath failures (unsaved buffers).
    norm, abs_err := filepath.abs(path, context.temp_allocator)
    if abs_err != nil {
        norm, _ = filepath.clean(path, context.temp_allocator)
    }
    diags, has := client.diagnostics[norm]
    testing.expect_value(t, has, true)
    testing.expect_value(t, len(diags), 1)
    testing.expect_value(t, diags[0].start_row, 2)
    testing.expect_value(t, diags[0].start_col, 3)
    testing.expect_value(t, diags[0].end_row, 2)
    testing.expect_value(t, diags[0].end_col, 7)
    testing.expect_value(t, diags[0].severity, LspSeverity.Error)
    testing.expect_value(t, diags[0].message, "bad thing")

    // An empty diagnostics array clears the file's diagnostics
    clear_msg := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/odin_lsp_diag_test.odin","diagnostics":[]}}`
    clear_obj, clear_ok := lsp_test_parse_object(clear_msg)
    testing.expect_value(t, clear_ok, true)
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", clear_obj, nil)
    _, still_there := client.diagnostics[norm]
    testing.expect_value(t, still_there, false)

    // Missing severity defaults to Error; severity is honored when present
    two_msg := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/odin_lsp_diag_test.odin","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"first"},{"range":{"start":{"line":5,"character":2},"end":{"line":5,"character":4}},"severity":2,"message":"second"}]}}`
    two_obj, two_ok := lsp_test_parse_object(two_msg)
    testing.expect_value(t, two_ok, true)
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", two_obj, nil)
    diags2 := client.diagnostics[norm]
    testing.expect_value(t, len(diags2), 2)
    testing.expect_value(t, diags2[0].severity, LspSeverity.Error)
    testing.expect_value(t, diags2[0].message, "first")
    testing.expect_value(t, diags2[1].severity, LspSeverity.Warning)
    testing.expect_value(t, diags2[1].start_row, 5)
    testing.expect_value(t, diags2[1].start_col, 2)

    // Malformed notifications are ignored
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", json.Object{}, nil)
    fmt.println("  ✓ [LSP Unit] publishDiagnostics parse/replace/clear verified")
}

@(test)
test_lsp_completion_response_parsing :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)

    append(&client.pending_requests, PendingRequest{
        id        = 7,
        kind      = .Completion,
        file_path = strings.clone("/tmp/odin_lsp_completion.odin"),
    })
    msg := `{"jsonrpc":"2.0","id":7,"result":{"isIncomplete":false,"items":[{"label":"printf","detail":"int printf(...)","documentation":{"kind":"markdown","value":"formats output"},"insertText":"printf"},{"label":"puts"}]}}`
    obj, ok := lsp_test_parse_object(msg)
    testing.expect_value(t, ok, true)
    lsp_handle_response(&client, 7, obj, nil)

    testing.expect_value(t, len(client.pending_requests), 0)
    testing.expect_value(t, len(client.completions), 2)
    testing.expect_value(t, client.completions[0].label, "printf")
    testing.expect_value(t, client.completions[0].detail, "int printf(...)")
    testing.expect_value(t, client.completions[0].documentation, "formats output")
    testing.expect_value(t, client.completions[0].insert_text, "printf")
    // insertText defaults to label; missing strings become empty
    testing.expect_value(t, client.completions[1].label, "puts")
    testing.expect_value(t, client.completions[1].insert_text, "puts")
    testing.expect_value(t, client.completions[1].detail, "")

    // Result may also be a bare array; previous completions are replaced
    lsp_test_clear_completions(&client)
    append(&client.pending_requests, PendingRequest{
        id        = 8,
        kind      = .Completion,
        file_path = strings.clone("/tmp/odin_lsp_completion.odin"),
    })
    arr_msg := `{"jsonrpc":"2.0","id":8,"result":[{"label":"alpha"}]}`
    arr_obj, arr_ok := lsp_test_parse_object(arr_msg)
    testing.expect_value(t, arr_ok, true)
    lsp_handle_response(&client, 8, arr_obj, nil)
    testing.expect_value(t, len(client.completions), 1)
    testing.expect_value(t, client.completions[0].label, "alpha")

    // Error responses remove the pending request without touching completions
    append(&client.pending_requests, PendingRequest{
        id        = 9,
        kind      = .Completion,
        file_path = strings.clone("/tmp/odin_lsp_completion.odin"),
    })
    err_msg := `{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"nope"}}`
    err_obj, err_ok := lsp_test_parse_object(err_msg)
    testing.expect_value(t, err_ok, true)
    lsp_handle_response(&client, 9, err_obj, nil)
    testing.expect_value(t, len(client.pending_requests), 0)
    testing.expect_value(t, len(client.completions), 1)
    fmt.println("  ✓ [LSP Unit] completion responses (object/array/error) parsed")
}

@(test)
test_lsp_hover_and_definition_parsing :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)

    // Null hover result
    append(&client.pending_requests, PendingRequest{id = 10, kind = .Hover})
    null_hover, ok := lsp_test_parse_object(`{"jsonrpc":"2.0","id":10,"result":null}`)
    testing.expect_value(t, ok, true)
    lsp_handle_response(&client, 10, null_hover, nil)
    testing.expect_value(t, client.last_hover, "(No hover documentation)")

    // Markup hover contents use the "value" field
    append(&client.pending_requests, PendingRequest{
        id        = 11,
        kind      = .Hover,
        file_path = strings.clone("/tmp/x.odin"),
    })
    hover_msg := `{"jsonrpc":"2.0","id":11,"result":{"contents":{"kind":"markdown","value":"details here"}}}`
    hover_obj, hover_ok := lsp_test_parse_object(hover_msg)
    testing.expect_value(t, hover_ok, true)
    lsp_handle_response(&client, 11, hover_obj, nil)
    testing.expect_value(t, client.last_hover, "details here")

    // Definition result with uri + range start
    append(&client.pending_requests, PendingRequest{
        id        = 12,
        kind      = .Definition,
        file_path = strings.clone("/tmp/x.odin"),
    })
    def_msg := `{"jsonrpc":"2.0","id":12,"result":{"uri":"file:///tmp/odin_lsp_def.odin","range":{"start":{"line":9,"character":4},"end":{"line":9,"character":8}}}}`
    def_obj, def_ok := lsp_test_parse_object(def_msg)
    testing.expect_value(t, def_ok, true)
    lsp_handle_response(&client, 12, def_obj, nil)

    loc, has_loc := client.last_definition.?
    testing.expect_value(t, has_loc, true)
    if has_loc {
        testing.expect_value(t, loc.file_path, "/tmp/odin_lsp_def.odin")
        testing.expect_value(t, loc.row, 9)
        testing.expect_value(t, loc.col, 4)
        delete(loc.file_path)
    }
    client.last_definition = nil
    fmt.println("  ✓ [LSP Unit] hover (null/markup) and definition parsing verified")
}

@(test)
test_lsp_range_formatting_parsing :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)

    // Single whole-file edit: only the requested line range is extracted
    append(&client.pending_requests, PendingRequest{
        id        = 13,
        kind      = .RangeFormatting,
        file_path = strings.clone("/tmp/x.odin"),
        start_row = 1,
        end_row   = 2,
    })
    fmt_msg := `{"jsonrpc":"2.0","id":13,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":3,"character":0}},"newText":"L0\nL1\nL2\nL3\n"}]}`
    fmt_obj, fmt_ok := lsp_test_parse_object(fmt_msg)
    testing.expect_value(t, fmt_ok, true)
    lsp_handle_response(&client, 13, fmt_obj, nil)

    testing.expect_value(t, len(client.last_edits), 1)
    if len(client.last_edits) == 1 {
        edit := client.last_edits[0]
        testing.expect_value(t, edit.start_row, 1)
        testing.expect_value(t, edit.start_col, 0)
        testing.expect_value(t, edit.end_row, 3)
        testing.expect_value(t, edit.end_col, 0)
        testing.expect_value(t, edit.new_text, "L1\nL2\n")
    }
    for e in client.last_edits do delete(e.new_text)
    clear(&client.last_edits)

    // Multiple edits: only those fully inside the requested range survive
    append(&client.pending_requests, PendingRequest{
        id        = 14,
        kind      = .RangeFormatting,
        file_path = strings.clone("/tmp/x.odin"),
        start_row = 1,
        end_row   = 2,
    })
    multi_msg := `{"jsonrpc":"2.0","id":14,"result":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"newText":"A"},{"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":0}},"newText":"B"}]}`
    multi_obj, multi_ok := lsp_test_parse_object(multi_msg)
    testing.expect_value(t, multi_ok, true)
    lsp_handle_response(&client, 14, multi_obj, nil)

    testing.expect_value(t, len(client.last_edits), 1)
    if len(client.last_edits) == 1 {
        edit := client.last_edits[0]
        testing.expect_value(t, edit.new_text, "A")
        testing.expect_value(t, edit.start_row, 1)
        testing.expect_value(t, edit.start_col, 0)
        testing.expect_value(t, edit.end_row, 1)
        testing.expect_value(t, edit.end_col, 5)
    }

    // A null result yields no edits
    append(&client.pending_requests, PendingRequest{
        id        = 15,
        kind      = .RangeFormatting,
        file_path = strings.clone("/tmp/x.odin"),
        start_row = 0,
        end_row   = 0,
    })
    null_obj, null_ok := lsp_test_parse_object(`{"jsonrpc":"2.0","id":15,"result":null}`)
    testing.expect_value(t, null_ok, true)
    lsp_handle_response(&client, 15, null_obj, nil)
    testing.expect_value(t, len(client.last_edits), 0)
    fmt.println("  ✓ [LSP Unit] range-formatting edit extraction/filtering verified")
}

@(test)
test_lsp_request_bookkeeping :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    client.running = true
    client.initialized = true

    lsp_did_open(&client, "test.odin", "package main")
    testing.expect_value(t, client.file_versions["test.odin"], 1)
    lsp_did_change(&client, "test.odin", "package main\n")
    testing.expect_value(t, client.file_versions["test.odin"], 2)
    lsp_did_change(&client, "test.odin", "package main\n\n")
    testing.expect_value(t, client.file_versions["test.odin"], 3)

    lsp_request_completion(&client, "test.odin", 1, 2)
    lsp_request_hover(&client, "test.odin", 3, 4)
    lsp_request_definition(&client, "test.odin", 5, 6)
    lsp_request_range_formatting(&client, "test.odin", 7, 8)

    testing.expect_value(t, len(client.pending_requests), 4)
    testing.expect_value(t, client.pending_requests[0].kind, LspRequestKind.Completion)
    testing.expect_value(t, client.pending_requests[1].kind, LspRequestKind.Hover)
    testing.expect_value(t, client.pending_requests[2].kind, LspRequestKind.Definition)
    testing.expect_value(t, client.pending_requests[3].kind, LspRequestKind.RangeFormatting)
    testing.expect_value(t, client.pending_requests[3].start_row, 7)
    testing.expect_value(t, client.pending_requests[3].end_row, 8)
    testing.expect_value(t, client.next_id, 4)
    fmt.println("  ✓ [LSP Unit] didOpen/didChange versions and request bookkeeping verified")
}

@(test)
test_lsp_uri_roundtrip :: proc(t: ^testing.T) {
    orig_path := "/home/fnln/Projects/my_project/src/main.zig"
    uri := lsp_path_to_uri(orig_path, context.allocator)
    defer delete(uri)

    testing.expect_value(t, strings.has_prefix(uri, "file:///"), true)

    back_path := lsp_uri_to_path(uri, context.allocator)
    defer delete(back_path)

    testing.expect_value(t, back_path, orig_path)
    fmt.println("  ✓ [LSP Unit] file:// URI encoding/decoding roundtrip verified")
}

@(test)
test_lsp_did_change_queue_coalescing :: proc(t: ^testing.T) {
    client: LspClient
    client.running = true
    client.initialized = true
    client.writer_queue = make([dynamic]Lsp_Out_Message, 0, 4)
    defer {
        for &m in client.writer_queue do lsp_destroy_out_message(&m)
        delete(client.writer_queue)
        delete(client.file_versions)
    }

    // A pipe stands in for the server's stdin; nothing reads it because the
    // writer thread is not started in this unit test.
    r, w, pipe_err := os.pipe()
    testing.expect_value(t, pipe_err, nil)
    client.stdin_file = w
    defer os.close(r)
    defer os.close(w)

    lsp_did_change(&client, "/tmp/coalesce.odin", "one")
    testing.expect_value(t, len(client.writer_queue), 1)

    // A newer snapshot for the same file replaces the unsent one.
    lsp_did_change(&client, "/tmp/coalesce.odin", "two")
    testing.expect_value(t, len(client.writer_queue), 1)
    msg := client.writer_queue[0]
    testing.expect_value(t, msg.kind, Lsp_Out_Kind.Did_Change)
    testing.expect_value(t, msg.text, "two")
    testing.expect_value(t, msg.version, 3)
    testing.expect_value(t, msg.uri, "file:///tmp/coalesce.odin")

    // A different file gets its own entry.
    lsp_did_change(&client, "/tmp/other.odin", "other")
    testing.expect_value(t, len(client.writer_queue), 2)

    // Raw messages stay separate and ordered after pending changes.
    lsp_send_raw(&client, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
    testing.expect_value(t, len(client.writer_queue), 3)
    testing.expect_value(t, client.writer_queue[2].kind, Lsp_Out_Kind.Raw)
    fmt.println("  ✓ [LSP Unit] unsent didChange snapshots coalesce per file")
}
