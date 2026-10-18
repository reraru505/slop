package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

add_picker_item :: proc(fp: ^FilePicker, rel_path: string) {
    append(&fp.items, FilePickerItem{
        rel_path  = strings.clone(rel_path, runtime.default_allocator()),
        full_path = strings.clone(rel_path, runtime.default_allocator()),
    })
}

set_picker_query :: proc(fp: ^FilePicker, query: string) {
    assert(len(query) <= len(fp.query_buffer))
    copy(fp.query_buffer[:], query)
    fp.query_len = len(query)
}

@(test)
test_picker_fuzzy_match :: proc(t: ^testing.T) {
    testing.expect_value(t, fuzzy_match("", "anything"), true)
    testing.expect_value(t, fuzzy_match("abc", "abc"), true)
    testing.expect_value(t, fuzzy_match("ac", "abc"), true)
    testing.expect_value(t, fuzzy_match("abc", "aXbXc"), true)
    testing.expect_value(t, fuzzy_match("ca", "abc"), false)
    testing.expect_value(t, fuzzy_match("abcd", "abc"), false)
    testing.expect_value(t, fuzzy_match("ABC", "abc"), false) // matching is case-sensitive
    fmt.println("  ✓ [Picker] subsequence fuzzy matching verified")
}

@(test)
test_picker_matches_query :: proc(t: ^testing.T) {
    path := "src/main.odin"

    testing.expect_value(t, file_picker_matches("", path), true)
    testing.expect_value(t, file_picker_matches("main", path), true) // substring
    testing.expect_value(t, file_picker_matches("sm", path), true)   // fuzzy
    testing.expect_value(t, file_picker_matches("main odin", path), true) // all tokens
    testing.expect_value(t, file_picker_matches("src zig", path), false)
    testing.expect_value(t, file_picker_matches("xyz", path), false)
    testing.expect_value(t, file_picker_matches("Main", path), false) // caller lowercases
    fmt.println("  ✓ [Picker] substring, fuzzy and multi-token query matching verified")
}

@(test)
test_picker_filter :: proc(t: ^testing.T) {
    fp: FilePicker
    file_picker_init(&fp)
    defer file_picker_destroy(&fp)

    add_picker_item(&fp, "src/main.odin")
    add_picker_item(&fp, "src/lsp.odin")
    add_picker_item(&fp, "README.md")
    add_picker_item(&fp, "tests/test_main.odin")

    // Empty query shows everything
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 4)

    set_picker_query(&fp, "main")
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 2)
    testing.expect_value(t, fp.items[fp.filtered_indices[0]].rel_path, "src/main.odin")
    testing.expect_value(t, fp.items[fp.filtered_indices[1]].rel_path, "tests/test_main.odin")

    set_picker_query(&fp, "odin")
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 3)

    // Query is lowercased before matching
    set_picker_query(&fp, "SRC")
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 2)

    // Fuzzy match across a path
    set_picker_query(&fp, "sm")
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 2)

    // Selection is clamped into the filtered range
    fp.selected_index = 99
    file_picker_filter(&fp)
    testing.expect_value(t, fp.selected_index, len(fp.filtered_indices) - 1)

    // No results resets selection and scroll
    set_picker_query(&fp, "zzz")
    fp.selected_index = 3
    fp.scroll_offset = 7
    file_picker_filter(&fp)
    testing.expect_value(t, len(fp.filtered_indices), 0)
    testing.expect_value(t, fp.selected_index, 0)
    testing.expect_value(t, fp.scroll_offset, 0)
    fmt.println("  ✓ [Picker] filtering, case folding, clamping and empty results")
}

@(test)
test_picker_open_walks_tree :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/picker_open"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    testing.expect(t, os.make_directory_all("/tmp/odin_editor_tests/picker_open/sub") == nil)
    testing.expect(t, os.make_directory_all("/tmp/odin_editor_tests/picker_open/.git") == nil)
    testing.expect(t, os.make_directory_all("/tmp/odin_editor_tests/picker_open/node_modules") == nil)
    testing.expect(t, os.make_directory_all("/tmp/odin_editor_tests/picker_open/bin") == nil)

    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/keep.txt", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/sub/nested.txt", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/backup~", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/swap.swp", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/.git/secret.txt", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/node_modules/x.js", "x") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/picker_open/bin/tool", "x") == nil)

    fp: FilePicker
    file_picker_init(&fp)
    defer file_picker_destroy(&fp)

    file_picker_open(&fp, dir, nil)
    file_picker_wait(&fp)
    testing.expect_value(t, fp.active, true)
    testing.expect_value(t, fp.root_dir, dir)
    testing.expect_value(t, fp.query_len, 0)
    testing.expect_value(t, len(fp.items), 2)
    testing.expect_value(t, len(fp.filtered_indices), 2)
    testing.expect_value(t, fp.items[0].rel_path, "keep.txt")
    testing.expect_value(t, fp.items[1].rel_path, "sub/nested.txt")

    file_picker_close(&fp, nil)
    testing.expect_value(t, fp.active, false)
    fmt.println("  ✓ [Picker] open skips VCS/build dirs and editor backups")
}

@(test)
test_picker_scan_defers_results :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/picker_async"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/one.txt", dir), "1") == nil)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/two.txt", dir), "2") == nil)

    fp: FilePicker
    file_picker_init(&fp)
    defer file_picker_destroy(&fp)

    file_picker_open(&fp, dir, nil)
    // The walk is owned by a background thread; nothing is published until
    // the main thread polls for completion.
    testing.expect(t, fp.scan_thread != nil)
    testing.expect_value(t, len(fp.items), 0)

    file_picker_wait(&fp)
    testing.expect(t, fp.scan_thread == nil)
    testing.expect_value(t, len(fp.items), 2)

    file_picker_close(&fp, nil)
    testing.expect_value(t, fp.active, false)
    fmt.println("  ✓ [Picker] tree walk runs off-thread and publishes on poll")
}

@(test)
test_picker_query_utf8_truncation :: proc(t: ^testing.T) {
    fp: FilePicker
    file_picker_init(&fp)
    defer file_picker_destroy(&fp)

    // Leave exactly one byte of room; a two-byte rune must not be split.
    for fp.query_len < len(fp.query_buffer) - 1 {
        fp.query_buffer[fp.query_len] = 'a'
        fp.query_len += 1
    }
    before := fp.query_len
    picker_append_query(&fp, "é")
    testing.expect_value(t, fp.query_len, before)

    // With room, multi-byte text is copied intact.
    fp.query_len = 0
    picker_append_query(&fp, "éx")
    testing.expect_value(t, fp.query_len, 3)
    testing.expect_value(t, string(fp.query_buffer[:fp.query_len]), "éx")
    fmt.println("  ✓ [Picker] query buffer never splits UTF-8 sequences")
}
