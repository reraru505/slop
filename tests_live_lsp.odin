package main

import "core:testing"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"
import "core:strings"

// Live tests spawn real language servers. They are opt-in so the default
// `odin test .` / `make test` run is hermetic and fast:
//     odin test . -define:ODIN_TEST_LIVE_LSP=true
LIVE_LSP_TESTS :: #config(ODIN_TEST_LIVE_LSP, false)

when LIVE_LSP_TESTS {

@(test)
test_live_lsp_zig :: proc(t: ^testing.T) {
    cmd, found := lsp_find_server_cmd(.Zig)
    if !found {
        fmt.println("ZLS not installed, skipping live test")
        return
    }

    client: LspClient
    tmp_dir := "/home/fnln/.cache/test_live_zig_ws"
    _ = os.make_directory_all(tmp_dir)
    defer os.remove_all(tmp_dir)

    test_file, _ := filepath.join([]string{tmp_dir, "main.zig"}, context.temp_allocator)
    test_src := "const std = @import(\"std\");\npub fn main() void {\n    const a = 123;\n    const b = a;\n    const bad: u32 = \"type error\";\n}\n"
    _ = os.write_entire_file(test_file, transmute([]u8)test_src)

    ok := lsp_start(&client, cmd, tmp_dir)
    testing.expect_value(t, ok, true)
    if !ok do return
    defer lsp_stop(&client)

    // Wait up to 5 seconds for initialization
    init_start := time.now()
    for time.since(init_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if client.initialized do break
        time.sleep(20 * time.Millisecond)
    }
    testing.expect_value(t, client.initialized, true)
    if !client.initialized do return

    // Open file
    lsp_did_open(&client, test_file, test_src)

    // Wait a brief moment for document index
    preamble_start := time.now()
    for time.since(preamble_start) < 400 * time.Millisecond {
        lsp_update(&client, nil)
        time.sleep(30 * time.Millisecond)
    }

    // Request completions at row 3, col 15 (after const b = a)
    lsp_request_completion(&client, test_file, 3, 15)

    comp_start := time.now()
    got_completions := false
    for time.since(comp_start) < 6 * time.Second {
        lsp_update(&client, nil)
        if len(client.completions) > 0 {
            got_completions = true
            break
        }
        time.sleep(30 * time.Millisecond)
    }

    testing.expect_value(t, got_completions, true)
    if got_completions {
        testing.expect_value(t, len(client.completions) > 5, true)
    }

    // Wait for diagnostics published
    diag_start := time.now()
    got_diagnostics := false
    norm_path, _ := filepath.abs(test_file, context.temp_allocator)
    for time.since(diag_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if diags, has := client.diagnostics[norm_path]; has && len(diags) > 0 {
            got_diagnostics = true
            break
        }
        time.sleep(30 * time.Millisecond)
    }
    testing.expect_value(t, got_diagnostics, true)
    fmt.printf("  ✓ [Live LSP] Zig (ZLS): Handshake, %d completions, diagnostics verified\n", len(client.completions))
}

@(test)
test_live_lsp_clangd :: proc(t: ^testing.T) {
    cmd, found := lsp_find_server_cmd(.Clangd)
    if !found {
        fmt.println("clangd not installed, skipping live test")
        return
    }

    client: LspClient
    tmp_dir := "/home/fnln/.cache/test_live_clangd_ws"
    _ = os.make_directory_all(tmp_dir)
    defer os.remove_all(tmp_dir)

    test_file, _ := filepath.join([]string{tmp_dir, "main.c"}, context.temp_allocator)
    test_src := "#include <stdio.h>\nint main() {\n    prin\n    const int err = \"type error\";\n    return 0;\n}\n"
    _ = os.write_entire_file(test_file, transmute([]u8)test_src)

    ok := lsp_start(&client, cmd, tmp_dir)
    testing.expect_value(t, ok, true)
    if !ok do return
    defer lsp_stop(&client)

    // Wait up to 5 seconds for initialization
    init_start := time.now()
    for time.since(init_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if client.initialized do break
        time.sleep(20 * time.Millisecond)
    }
    testing.expect_value(t, client.initialized, true)
    if !client.initialized do return

    // Open file
    lsp_did_open(&client, test_file, test_src)

    // Clangd builds preamble/AST asynchronously; give it up to 1s
    preamble_start := time.now()
    for time.since(preamble_start) < 1000 * time.Millisecond {
        lsp_update(&client, nil)
        time.sleep(30 * time.Millisecond)
    }

    // Request completions at row 2, col 8 (after prin)
    lsp_request_completion(&client, test_file, 2, 8)

    comp_start := time.now()
    got_completions := false
    for time.since(comp_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if len(client.completions) > 0 {
            got_completions = true
            break
        }
        time.sleep(30 * time.Millisecond)
    }
    testing.expect_value(t, got_completions, true)
    if got_completions {
        has_printf := false
        for c in client.completions {
            if strings.contains(c.label, "printf") {
                has_printf = true
                break
            }
        }
        testing.expect_value(t, has_printf, true)
    }

    // Wait for diagnostics published
    diag_start := time.now()
    got_diagnostics := false
    norm_path, _ := filepath.abs(test_file, context.temp_allocator)
    for time.since(diag_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if diags, has := client.diagnostics[norm_path]; has && len(diags) > 0 {
            got_diagnostics = true
            break
        }
        time.sleep(30 * time.Millisecond)
    }
    testing.expect_value(t, got_diagnostics, true)
    fmt.printf("  ✓ [Live LSP] C (Clangd): Handshake, printf completion (%d items), diagnostics verified\n", len(client.completions))
}

@(test)
test_live_lsp_odin :: proc(t: ^testing.T) {
    cmd, found := lsp_find_server_cmd(.Odin)
    if !found {
        fmt.println("ols not installed, skipping live test")
        return
    }

    client: LspClient
    tmp_dir := "/home/fnln/Intrusive/text-editor"

    ok := lsp_start(&client, cmd, tmp_dir)
    testing.expect_value(t, ok, true)
    if !ok do return
    defer lsp_stop(&client)

    init_start := time.now()
    for time.since(init_start) < 5 * time.Second {
        lsp_update(&client, nil)
        if client.initialized do break
        time.sleep(20 * time.Millisecond)
    }
    testing.expect_value(t, client.initialized, true)
    fmt.println("  ✓ [Live LSP] Odin (OLS): Handshake and initialization verified")
}

@(test)
test_live_lsp_manager_root_lifecycle :: proc(t: ^testing.T) {
    root := "/home/fnln/.cache/test_live_manager_ws"
    _ = os.remove_all(root)
    _ = os.make_directory_all(root)
    defer os.remove_all(root)

    path, _ := filepath.join([]string{root, "main.odin"}, context.temp_allocator)
    _ = os.write_entire_file_from_string(path, "package main\n\nmain :: proc() {}\n")

    mgr: LspManager
    lsp_manager_init(&mgr, root)
    defer lsp_manager_stop_all(&mgr)

    lsp_manager_open_doc(&mgr, path, "package main\n\nmain :: proc() {}\n")
    start := time.now()
    initialized := false
    for time.since(start) < 8 * time.Second {
        lsp_manager_poll(&mgr)
        for client in mgr.clients {
            lsp_update(client, nil)
            if client.initialized do initialized = true
        }
        if initialized do break
        time.sleep(20 * time.Millisecond)
    }
    testing.expect_value(t, initialized, true)
    if !initialized do return

    lsp_manager_poll(&mgr)
    lsp_manager_change_doc(&mgr, path, "package main\n\nmain :: proc() { println(\"hi\") }\n")
    lsp_manager_close_doc(&mgr, path)
    testing.expect_value(t, len(mgr.docs), 0)

    stop_start := time.now()
    lsp_manager_stop_all(&mgr)
    elapsed := time.since(stop_start)
    testing.expect(t, elapsed < 3 * time.Second, "manager shutdown stalled")
    fmt.println("  ✓ [Live LSP] manager spawns, opens, re-roots, and shuts down")
}

} // when LIVE_LSP_TESTS
