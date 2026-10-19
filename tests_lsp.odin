package main

import "core:testing"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"
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
    raw := "hello \"world\"\nnew line\ttab\\backslash\r\x01"
    escaped := lsp_json_escape(raw, context.allocator)
    defer delete(escaped)

    expected := "hello \\\"world\\\"\\nnew line\\ttab\\\\backslash\\r\\u0001"
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

    // Spaces and unicode are percent-encoded and survive a roundtrip
    orig := "/tmp/some dir/файл.odin"
    uri2 := lsp_path_to_uri(orig, context.temp_allocator)
    testing.expect(t, strings.contains(uri2, "%20"), uri2)
    testing.expect(t, strings.contains(uri2, "%D1"), uri2)
    testing.expect(t, !strings.contains(uri2, " "), uri2)
    back := lsp_uri_to_path(uri2, context.temp_allocator)
    testing.expect_value(t, back, orig)

    // Percent escapes from the server are decoded
    decoded := lsp_uri_to_path("file:///tmp/some%20dir/x.odin", context.temp_allocator)
    testing.expect_value(t, decoded, "/tmp/some dir/x.odin")

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
    if client.completions_file != "" do delete(client.completions_file)
    if client.last_hover != "" do delete(client.last_hover)
    if client.last_hover_file != "" do delete(client.last_hover_file)
    for e in client.last_edits do delete(e.new_text)
    delete(client.last_edits)
    if client.last_edits_file != "" do delete(client.last_edits_file)
    if loc, ok := client.last_definition.?; ok && loc.file_path != "" {
        delete(loc.file_path)
    }
    lsp_test_clear_diagnostics(client)
    for k in client.file_versions do delete(k)
    delete(client.file_versions)
    for k, v in client.file_texts {
        delete(k)
        delete(v)
    }
    delete(client.file_texts)
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
    testing.expect_value(t, client.completions_file, "/tmp/odin_lsp_completion.odin")
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
test_lsp_hover_diagnostic_fallback_and_summary :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)

    path := "/tmp/odin_lsp_hover_diag.odin"
    diag_msg := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/odin_lsp_hover_diag.odin","diagnostics":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":9}},"severity":1,"message":"Undeclared name: bogus"},{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":9}},"severity":2,"message":"related warning"}]}}`
    diag_obj, diag_ok := lsp_test_parse_object(diag_msg)
    testing.expect_value(t, diag_ok, true)
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", diag_obj, nil)

    // A null hover result on an error reports the most severe diagnostic.
    append(&client.pending_requests, PendingRequest{
        id        = 20,
        kind      = .Hover,
        file_path = strings.clone(path),
        start_row = 2,
        col       = 4,
    })
    null_hover, null_ok := lsp_test_parse_object(`{"jsonrpc":"2.0","id":20,"result":null}`)
    testing.expect_value(t, null_ok, true)
    lsp_handle_response(&client, 20, null_hover, nil)
    testing.expect_value(t, client.last_hover, "Error: Undeclared name: bogus")

    // Documentation is kept, but the diagnostic comes first.
    append(&client.pending_requests, PendingRequest{
        id        = 21,
        kind      = .Hover,
        file_path = strings.clone(path),
        start_row = 2,
        col       = 4,
    })
    hover_msg := `{"jsonrpc":"2.0","id":21,"result":{"contents":{"kind":"markdown","value":"same :: int"}}}`
    hover_obj, hover_ok := lsp_test_parse_object(hover_msg)
    testing.expect_value(t, hover_ok, true)
    lsp_handle_response(&client, 21, hover_obj, nil)
    testing.expect_value(t, client.last_hover, "Error: Undeclared name: bogus\nsame :: int")
    // The one-line status view starts with the diagnostic.
    testing.expect_value(t, lsp_hover_one_line(client.last_hover), "Error: Undeclared name: bogus")

    // Outside the diagnostic range, only hover content is shown.
    append(&client.pending_requests, PendingRequest{
        id        = 22,
        kind      = .Hover,
        file_path = strings.clone(path),
        start_row = 2,
        col       = 20,
    })
    hover2_obj, hover2_ok := lsp_test_parse_object(hover_msg)
    testing.expect_value(t, hover2_ok, true)
    lsp_handle_response(&client, 22, hover2_obj, nil)
    testing.expect_value(t, client.last_hover, "same :: int")
    testing.expect_value(t, lsp_hover_one_line(client.last_hover), "same :: int")

    // Markdown fences, rules, and blank lines never become the displayed hover.
    testing.expect_value(t, lsp_hover_one_line("```odin\nsame :: int\n```"), "same :: int")
    testing.expect_value(t, lsp_hover_one_line("---\n\nplain docs"), "plain docs")
    testing.expect_value(t, lsp_hover_one_line("~~~\ncode\n~~~"), "code")
    testing.expect_value(t, lsp_hover_one_line("   \n"), "")
    fmt.println("  ✓ [LSP Unit] hover falls back to diagnostics and skips markdown noise")
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
    testing.expect_value(t, client.last_hover_file, "/tmp/x.odin")

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
    testing.expect_value(t, client.last_edits_file, "/tmp/x.odin")
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
    lsp_set_running(&client, true)
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
    lsp_set_running(&client, true)
    client.initialized = true
    client.writer_queue = make([dynamic]Lsp_Out_Message, 0, 4)
    defer {
        for &m in client.writer_queue do lsp_destroy_out_message(&m)
        delete(client.writer_queue)
        for k in client.file_versions do delete(k)
        delete(client.file_versions)
        for k, v in client.file_texts {
            delete(k)
            delete(v)
        }
        delete(client.file_texts)
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

    // A snapshot after a queued request must NOT be coalesced into the one
    // before the request; the request's coordinates refer to the older text.
    lsp_did_change(&client, "/tmp/coalesce.odin", "three")
    testing.expect_value(t, len(client.writer_queue), 4)
    testing.expect_value(t, client.writer_queue[3].kind, Lsp_Out_Kind.Did_Change)
    testing.expect_value(t, client.writer_queue[3].text, "three")
    fmt.println("  ✓ [LSP Unit] unsent didChange snapshots coalesce per file")
}

@(test)
test_lsp_start_failure_cleans_up :: proc(t: ^testing.T) {
    client: LspClient
    ok := lsp_start(&client, "/definitely/not/a/language/server", "/tmp")
    testing.expect_value(t, ok, false)
    testing.expect_value(t, client.server_cmd, "")
    fmt.println("  ✓ [LSP Unit] failed server start releases initialized state")
}

@(test)
test_lsp_reader_handles_batched_messages :: proc(t: ^testing.T) {
    client: LspClient
    client.incoming_queue = make([dynamic]json.Value, 0, 4)
    lsp_set_running(&client, true)

    r, w, pipe_err := os.pipe()
    testing.expect_value(t, pipe_err, nil)
    client.stdout_file = r
    client.reader_thread = thread.create_and_start_with_data(rawptr(&client), lsp_reader_thread_proc)

    defer {
        lsp_set_running(&client, false)
        os.close(w)
        if client.reader_thread != nil {
            thread.join(client.reader_thread)
            thread.destroy(client.reader_thread)
        }
        os.close(r)
        for v in client.incoming_queue do json.destroy_value(v, runtime.default_allocator())
        delete(client.incoming_queue)
    }

    m1 := `{"jsonrpc":"2.0","id":1,"result":null}`
    m2 := `{"jsonrpc":"2.0","id":2,"result":{"items":[1,2,3]}}`
    payload := fmt.tprintf(
        "Content-Length: %d\r\n\r\n%sContent-Length: %d\r\n\r\n%s",
        len(m1), m1, len(m2), m2,
    )
    _, write_err := os.write(w, transmute([]u8)payload)
    testing.expect_value(t, write_err, nil)

    count := 0
    for _ in 0 ..< 2000 {
        sync.mutex_lock(&client.mutex)
        count = len(client.incoming_queue)
        sync.mutex_unlock(&client.mutex)
        if count >= 2 do break
        time.sleep(time.Millisecond)
    }
    testing.expect_value(t, count, 2)
    fmt.println("  ✓ [LSP Unit] reader parses multiple messages batched in one read")
}

@(test)
test_lsp_utf16_position_conversion :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    client.position_encoding = .UTF16
    path := "/tmp/unicode_positions.odin"
    line := "é日😀x" // bytes: 2 + 3 + 4 + 1; UTF-16 units: 1 + 1 + 2 + 1
    client.file_texts[strings.clone(path, context.allocator)] = strings.clone(line, context.allocator)

    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 0), 0)
    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 2), 1)
    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 5), 2)
    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 9), 4)
    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 10), 5)

    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 0), 0)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 1), 2)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 2), 5)
    // Mid-surrogate snaps to the emoji start.
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 3), 5)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 4), 9)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 5), 10)

    client.position_encoding = .UTF8
    testing.expect_value(t, lsp_byte_col_to_character(&client, path, 0, 5), 5)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 0, 5), 5)
    fmt.println("  ✓ [LSP Unit] UTF-8 byte columns and UTF-16 code units convert both ways")
}

@(test)
test_lsp_initialize_selects_position_encoding :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    client.position_encoding = .UTF16
    append(&client.pending_requests, PendingRequest{id = 1, kind = .Initialize})

    msg := `{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-8"}}}`
    obj, ok := lsp_test_parse_object(msg)
    testing.expect_value(t, ok, true)
    lsp_handle_response(&client, 1, obj, nil)
    testing.expect_value(t, client.initialized, true)
    testing.expect_value(t, client.position_encoding, Lsp_Position_Encoding.UTF8)

    // Servers that omit the field use the protocol default.
    other: LspClient
    defer lsp_test_cleanup(&other)
    append(&other.pending_requests, PendingRequest{id = 2, kind = .Initialize})
    msg2 := `{"jsonrpc":"2.0","id":2,"result":{"capabilities":{}}}`
    obj2, ok2 := lsp_test_parse_object(msg2)
    testing.expect_value(t, ok2, true)
    lsp_handle_response(&other, 2, obj2, nil)
    testing.expect_value(t, other.position_encoding, Lsp_Position_Encoding.UTF16)
    fmt.println("  ✓ [LSP Unit] initialize honors the server's positionEncoding choice")
}

@(test)
test_lsp_diagnostics_use_utf16_columns :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    client.position_encoding = .UTF16
    path := "/tmp/odin_unicode_diag.odin"
    client.file_texts[strings.clone(path, context.allocator)] = strings.clone("é日😀x", context.allocator)

    msg := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/odin_unicode_diag.odin","diagnostics":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"severity":1,"message":"bad"}]}}`
    obj, ok := lsp_test_parse_object(msg)
    testing.expect_value(t, ok, true)
    lsp_handle_notification(&client, "textDocument/publishDiagnostics", obj, nil)

    diags, has := client.diagnostics[path]
    testing.expect_value(t, has, true)
    if has && len(diags) > 0 {
        testing.expect_value(t, diags[0].start_col, 2)
        testing.expect_value(t, diags[0].end_col, 5)
    }
    fmt.println("  ✓ [LSP Unit] diagnostics UTF-16 columns become byte offsets")
}

@(test)
test_lsp_definition_and_format_use_utf16_columns :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    client.position_encoding = .UTF16
    path := "/tmp/odin_unicode_fmt.odin"
    target := "/tmp/odin_unicode_target.odin"
    defer os.remove(target)
    testing.expect(t, os.write_entire_file_from_string(target, "é日😀x") == nil)
    client.file_texts[strings.clone(path, context.allocator)] = strings.clone("zero\né日😀x", context.allocator)

    // Definition target at UTF-16 character 2 (start of the emoji at byte 5).
    append(&client.pending_requests, PendingRequest{id = 12, kind = .Definition, file_path = strings.clone(path)})
    def_msg := `{"jsonrpc":"2.0","id":12,"result":{"uri":"file:///tmp/odin_unicode_target.odin","range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}}}}`
    def_obj, def_ok := lsp_test_parse_object(def_msg)
    testing.expect_value(t, def_ok, true)
    lsp_handle_response(&client, 12, def_obj, nil)
    loc, has_loc := client.last_definition.?
    testing.expect_value(t, has_loc, true)
    if has_loc {
        testing.expect_value(t, loc.col, 5)
        delete(loc.file_path)
    }
    client.last_definition = nil

    doc_line, line_ok := lsp_document_line(&client, path, 1, context.temp_allocator)
    testing.expect_value(t, line_ok, true)
    testing.expect_value(t, doc_line, "é日😀x")
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 1, 1), 2)
    testing.expect_value(t, lsp_character_to_byte_col(&client, path, 1, 2), 5)

    // Multi-edit formatting on line 1: character 1..2 is bytes 2..5.
    append(&client.pending_requests, PendingRequest{
        id = 13, kind = .RangeFormatting, file_path = strings.clone(path), start_row = 1, end_row = 1,
    })
    fmt_msg := `{"jsonrpc":"2.0","id":13,"result":[{"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":2}},"newText":"X"}]}`
    fmt_obj, fmt_ok := lsp_test_parse_object(fmt_msg)
    testing.expect_value(t, fmt_ok, true)
    lsp_handle_response(&client, 13, fmt_obj, nil)
    testing.expect_value(t, len(client.last_edits), 1)
    if len(client.last_edits) == 1 {
        testing.expect_value(t, client.last_edits[0].start_col, 2)
        testing.expect_value(t, client.last_edits[0].end_col, 5)
    }
    fmt.println("  ✓ [LSP Unit] definition targets and format edits convert UTF-16 columns")
}

make_fake_lsp_client :: proc(kind: LspServerKind, root: string) -> ^LspClient {
    c := new(LspClient)
    c.server_kind = kind
    c.root_dir = strings.clone(root, context.allocator)
    c.started_at = time.now()
    c.initialized = true
    c.file_versions = make(map[string]int)
    c.file_texts = make(map[string]string)
    lsp_set_running(c, true)
    return c
}

@(test)
test_lsp_manager_document_lifecycle :: proc(t: ^testing.T) {
    root := "/tmp/odin_editor_tests/lsp_root_one"
    _ = os.remove_all(root)
    testing.expect(t, os.make_directory_all(root) == nil)
    defer os.remove_all(root)

    mgr: LspManager
    lsp_manager_init(&mgr, root)
    mgr.spawn_enabled = false
    defer lsp_manager_stop_all(&mgr)

    fake := make_fake_lsp_client(.Odin, root)
    append(&mgr.clients, fake)

    path := fmt.tprintf("%s/main.odin", root)
    lsp_manager_open_doc(&mgr, path, "package main")
    testing.expect_value(t, len(mgr.docs), 1)
    lsp_manager_poll(&mgr)
    testing.expect_value(t, fake.file_versions[path], 1)
    testing.expect_value(t, len(fake.file_texts), 1)

    // A second pane showing the same file adds a ref, not a didOpen.
    lsp_manager_open_doc(&mgr, path, "package main")
    lsp_manager_poll(&mgr)
    testing.expect_value(t, fake.file_versions[path], 1)

    lsp_manager_change_doc(&mgr, path, "package main\n")
    testing.expect_value(t, fake.file_versions[path], 2)

    lsp_manager_close_doc(&mgr, path)
    testing.expect_value(t, len(mgr.docs), 1) // second ref remains
    lsp_manager_close_doc(&mgr, path)
    testing.expect_value(t, len(mgr.docs), 0)
    testing.expect_value(t, len(fake.file_versions), 0)
    testing.expect_value(t, len(fake.file_texts), 0)

    fmt.println("  ✓ [LSP Unit] manager refcounts didOpen/didChange/didClose")
}

@(test)
test_lsp_manager_retarget_moves_documents :: proc(t: ^testing.T) {
    root1 := "/tmp/odin_editor_tests/lsp_retarget_one"
    root2 := "/tmp/odin_editor_tests/lsp_retarget_two"
    _ = os.remove_all(root1)
    _ = os.remove_all(root2)
    testing.expect(t, os.make_directory_all(root1) == nil)
    testing.expect(t, os.make_directory_all(root2) == nil)
    defer os.remove_all(root1)
    defer os.remove_all(root2)

    mgr: LspManager
    lsp_manager_init(&mgr, root1)
    mgr.spawn_enabled = false
    defer lsp_manager_stop_all(&mgr)

    fake1 := make_fake_lsp_client(.Odin, root1)
    append(&mgr.clients, fake1)
    path := fmt.tprintf("%s/main.odin", root1)
    lsp_manager_open_doc(&mgr, path, "package main")
    lsp_manager_poll(&mgr)
    testing.expect_value(t, fake1.file_versions[path], 1)

    // Re-root: the old client is closed and pruned, the document waits for a
    // client under the new root.
    lsp_manager_set_project_root(&mgr, root2)
    lsp_manager_poll(&mgr)
    testing.expect_value(t, len(fake1.file_versions), 0)
    testing.expect_value(t, len(mgr.clients), 0)
    testing.expect_value(t, len(mgr.docs), 1)

    fake2 := make_fake_lsp_client(.Odin, root2)
    append(&mgr.clients, fake2)
    lsp_manager_poll(&mgr)
    testing.expect_value(t, fake2.file_versions[path], 1)

    fmt.println("  ✓ [LSP Unit] re-root closes old docs and reopens under the new root")
}

@(test)
test_lsp_stop_is_bounded :: proc(t: ^testing.T) {
    client: LspClient
    ok := lsp_start(&client, "cat", "/tmp")
    testing.expect_value(t, ok, true)
    if !ok do return

    start := time.now()
    stopped := lsp_stop(&client)
    elapsed := time.since(start)
    testing.expect_value(t, stopped, true)
    testing.expect(t, elapsed < 3 * time.Second, "lsp_stop took too long")
    testing.expect_value(t, client.writer_thread == nil, true)
    testing.expect_value(t, client.reader_thread == nil, true)
    fmt.println("  ✓ [LSP Unit] shutdown joins writer/reader with bounded waits")
}

@(test)
test_lsp_manager_multi_root_clients :: proc(t: ^testing.T) {
    root1 := "/tmp/odin_editor_tests/lsp_multi_one"
    root2 := "/tmp/odin_editor_tests/lsp_multi_two"
    _ = os.remove_all(root1)
    _ = os.remove_all(root2)
    testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.git", root2)) == nil)
    defer os.remove_all(root1)
    defer os.remove_all(root2)
    testing.expect(t, os.make_directory_all(root1) == nil)

    mgr: LspManager
    lsp_manager_init(&mgr, root1)
    mgr.spawn_enabled = false
    defer lsp_manager_stop_all(&mgr)

    fake1 := make_fake_lsp_client(.Odin, root1)
    fake2 := make_fake_lsp_client(.Odin, root2)
    append(&mgr.clients, fake1)
    append(&mgr.clients, fake2)

    inside := fmt.tprintf("%s/a.odin", root1)
    outside := fmt.tprintf("%s/b.odin", root2)
    lsp_manager_open_doc(&mgr, inside, "package a")
    lsp_manager_open_doc(&mgr, outside, "package b")
    lsp_manager_poll(&mgr)

    testing.expect_value(t, fake1.file_versions[inside], 1)
    testing.expect_value(t, fake2.file_versions[outside], 1)
    testing.expect_value(t, fake1.file_versions[outside], 0)
    testing.expect_value(t, fake2.file_versions[inside], 0)
    fmt.println("  ✓ [LSP Unit] files outside the project root use their own client")
}

@(test)
test_lsp_request_encodes_utf16_character :: proc(t: ^testing.T) {
    client: LspClient
    defer lsp_test_cleanup(&client)
    lsp_set_running(&client, true)
    client.initialized = true
    client.position_encoding = .UTF16
    client.writer_queue = make([dynamic]Lsp_Out_Message, 0, 4)
    defer {
        for &m in client.writer_queue do lsp_destroy_out_message(&m)
        delete(client.writer_queue)
    }
    r, w, pipe_err := os.pipe()
    testing.expect_value(t, pipe_err, nil)
    defer os.close(r)
    defer os.close(w)
    client.stdin_file = w

    path := "/tmp/odin_utf16_request.odin"
    client.file_texts[strings.clone(path, context.allocator)] = strings.clone("é日😀x", context.allocator)

    // Byte column 5 is the start of the emoji, UTF-16 character 2.
    lsp_request_completion(&client, path, 0, 5)
    testing.expect_value(t, len(client.writer_queue), 1)
    if len(client.writer_queue) == 1 {
        testing.expect(t, strings.contains(client.writer_queue[0].raw, `"character":2`))
    }
    fmt.println("  ✓ [LSP Unit] outgoing requests encode UTF-16 character offsets")
}
