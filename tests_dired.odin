package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

expect_dired_names :: proc(t: ^testing.T, d: ^Dired, want: []string) {
    testing.expect_value(t, len(d.entries), len(want))
    for name, i in want {
        if i < len(d.entries) {
            testing.expect_value(t, d.entries[i].name, name)
        }
    }
}

@(test)
test_dired_compare_entries :: proc(t: ^testing.T) {
    now := time.now()
    older := time.time_add(now, -2 * time.Hour)
    newer := time.time_add(now, -1 * time.Hour)

    a := DiredEntry{name = "alpha.txt", size = 10, mod_time = older}
    b := DiredEntry{name = "beta.txt", size = 20, mod_time = newer}
    eq_size := DiredEntry{name = "aardvark.txt", size = 20, mod_time = now}

    // Name ordering
    testing.expect_value(t, dired_compare_entries(a, b, .Name, .Asc), true)
    testing.expect_value(t, dired_compare_entries(b, a, .Name, .Asc), false)
    testing.expect_value(t, dired_compare_entries(a, b, .Name, .Desc), false)

    // Size ordering, with name as the tie-breaker
    testing.expect_value(t, dired_compare_entries(a, b, .Size, .Asc), true)
    testing.expect_value(t, dired_compare_entries(b, a, .Size, .Asc), false)
    testing.expect_value(t, dired_compare_entries(b, eq_size, .Size, .Asc), false) // beta > aardvark
    testing.expect_value(t, dired_compare_entries(eq_size, b, .Size, .Asc), true)

    // Time ordering: ascending means oldest first; descending reverses it
    testing.expect_value(t, dired_compare_entries(a, b, .Time, .Asc), true)
    testing.expect_value(t, dired_compare_entries(b, a, .Time, .Asc), false)
    testing.expect_value(t, dired_compare_entries(b, a, .Time, .Desc), true)
    fmt.println("  ✓ [Dired] name/size/time comparisons and tie-breaking verified")
}

@(test)
test_dired_cycle_sort_and_names :: proc(t: ^testing.T) {
    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)

    testing.expect_value(t, d.sort_by, DiredSortBy.Name)
    testing.expect_value(t, d.sort_order, DiredSortOrder.Asc)

    dired_cycle_sort(&d)
    testing.expect_value(t, d.sort_by, DiredSortBy.Size)
    dired_cycle_sort(&d)
    testing.expect_value(t, d.sort_by, DiredSortBy.Time)
    dired_cycle_sort(&d)
    testing.expect_value(t, d.sort_by, DiredSortBy.Name)

    testing.expect_value(t, dired_sort_name(.Name), "Name")
    testing.expect_value(t, dired_sort_name(.Size), "Size")
    testing.expect_value(t, dired_sort_name(.Time), "Time")
    fmt.println("  ✓ [Dired] sort cycle and display names verified")
}

@(test)
test_dired_format_size :: proc(t: ^testing.T) {
    testing.expect_value(t, dired_format_size(0), "   0 B")
    testing.expect_value(t, dired_format_size(1023), "1023 B")
    testing.expect_value(t, dired_format_size(1024), " 1.0 KB")
    testing.expect_value(t, dired_format_size(1536), " 1.5 KB")
    testing.expect_value(t, dired_format_size(1024 * 1024), " 1.0 MB")
    testing.expect_value(t, dired_format_size(5 * 1024 * 1024 + 512 * 1024), " 5.5 MB")
    fmt.println("  ✓ [Dired] human-readable size formatting verified")
}

@(test)
test_dired_sort_entries :: proc(t: ^testing.T) {
    now := time.now()
    t1 := time.time_add(now, -4 * time.Hour)
    t2 := time.time_add(now, -3 * time.Hour)
    t3 := time.time_add(now, -2 * time.Hour)
    t4 := time.time_add(now, -1 * time.Hour)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)

    append(&d.entries, DiredEntry{name = strings.clone(".."), is_dir = true})
    append(&d.entries, DiredEntry{name = strings.clone("zdir"), is_dir = true, size = 100, mod_time = t2})
    append(&d.entries, DiredEntry{name = strings.clone("adir"), is_dir = true, size = 50, mod_time = t1})
    append(&d.entries, DiredEntry{name = strings.clone("b.txt"), size = 300, mod_time = t4})
    append(&d.entries, DiredEntry{name = strings.clone("a.txt"), size = 100, mod_time = t3})

    // Name ascending: parent, then directories, then files
    d.sort_by = .Name
    d.sort_order = .Asc
    dired_sort_entries(&d)
    expect_dired_names(t, &d, []string{"..", "adir", "zdir", "a.txt", "b.txt"})

    // Size ascending
    d.sort_by = .Size
    d.sort_order = .Asc
    dired_sort_entries(&d)
    expect_dired_names(t, &d, []string{"..", "adir", "zdir", "a.txt", "b.txt"})

    // Size descending
    d.sort_order = .Desc
    dired_sort_entries(&d)
    expect_dired_names(t, &d, []string{"..", "zdir", "adir", "b.txt", "a.txt"})

    // Time ascending (oldest first inside each group)
    d.sort_by = .Time
    d.sort_order = .Asc
    dired_sort_entries(&d)
    expect_dired_names(t, &d, []string{"..", "adir", "zdir", "a.txt", "b.txt"})

    // Time descending (newest first inside each group)
    d.sort_order = .Desc
    dired_sort_entries(&d)
    expect_dired_names(t, &d, []string{"..", "zdir", "adir", "b.txt", "a.txt"})
    fmt.println("  ✓ [Dired] sorting keeps '..' first, dirs before files")
}

@(test)
test_dired_load_path :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dired_load"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/dired_load/alpha.txt", "abc") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/dired_load/zeta.txt", "z") == nil)
    testing.expect(t, os.make_directory("/tmp/odin_editor_tests/dired_load/mid") == nil)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)

    testing.expect_value(t, dired_load_path(&d, dir), true)
    testing.expect_value(t, d.path, dir)
    expect_dired_names(t, &d, []string{"..", "mid", "alpha.txt", "zeta.txt"})
    testing.expect_value(t, d.entries[0].is_dir, true)
    testing.expect_value(t, d.entries[1].is_dir, true)
    testing.expect_value(t, d.entries[2].is_dir, false)
    testing.expect_value(t, d.entries[2].size, 3)

    // Nonexistent directories fail without destroying the current listing
    testing.expect_value(t, dired_load_path(&d, "/tmp/odin_editor_tests/does_not_exist_98765"), false)
    testing.expect_value(t, d.path, dir)
    testing.expect_value(t, len(d.entries), 4)
    fmt.println("  ✓ [Dired] directory load, sort order and error handling verified")
}

@(test)
test_dired_enter_edit_mode_listing :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dired_edit_listing"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/dired_edit_listing/alpha.txt", "a") == nil)
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/dired_edit_listing/zeta.txt", "z") == nil)
    testing.expect(t, os.make_directory("/tmp/odin_editor_tests/dired_edit_listing/mid") == nil)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)
    testing.expect_value(t, dired_load_path(&d, dir), true)

    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)

    dired_enter_edit_mode(&d, &e, nil, nil)
    testing.expect_value(t, d.is_editing, true)
    testing.expect_value(t, e.mode, EditorMode.Insert)

    listing := pt_full_text(&e.table)
    defer delete(listing)
    testing.expect_value(t, listing, "mid/\nalpha.txt\nzeta.txt\n")
    fmt.println("  ✓ [Dired] edit mode renders dirs with '/' and enters Insert")
}

@(test)
test_dired_apply_edits_create_rename_delete :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dired_apply"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)

    // Stage 1: create a file and a directory from an empty listing
    testing.expect_value(t, dired_load_path(&d, dir), true)
    dired_enter_edit_mode(&d, &e, nil, nil)
    set_editor_text(&e, "new_file.txt\nnew_dir/\n")
    msg := dired_apply_edits(&d, &e)
    testing.expect_value(t, msg, "Dired: applied changes (2 created, 0 renamed, 0 deleted)")
    testing.expect_value(t, d.is_editing, false)
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/new_file.txt"), true)
    testing.expect_value(t, os.is_dir("/tmp/odin_editor_tests/dired_apply/new_dir"), true)

    // Stage 2: remove everything by emptying the listing
    testing.expect_value(t, dired_load_path(&d, dir), true)
    dired_enter_edit_mode(&d, &e, nil, nil)
    set_editor_text(&e, "")
    msg2 := dired_apply_edits(&d, &e)
    testing.expect_value(t, msg2, "Dired: applied changes (0 created, 0 renamed, 2 deleted)")
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/new_file.txt"), false)
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/new_dir"), false)

    // Stage 3: rename preserves file contents
    testing.expect(t, os.write_entire_file_from_string("/tmp/odin_editor_tests/dired_apply/old.txt", "payload") == nil)
    testing.expect_value(t, dired_load_path(&d, dir), true)
    dired_enter_edit_mode(&d, &e, nil, nil)
    set_editor_text(&e, "renamed.txt\n")
    msg3 := dired_apply_edits(&d, &e)
    testing.expect_value(t, msg3, "Dired: applied changes (0 created, 1 renamed, 0 deleted)")
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/old.txt"), false)
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/renamed.txt"), true)

    renamed, read_err := os.read_entire_file(
        "/tmp/odin_editor_tests/dired_apply/renamed.txt",
        context.temp_allocator,
    )
    testing.expect(t, read_err == nil)
    testing.expect_value(t, string(renamed), "payload")

    // Stage 4: renaming a directory
    testing.expect(t, os.make_directory("/tmp/odin_editor_tests/dired_apply/old_dir") == nil)
    testing.expect_value(t, dired_load_path(&d, dir), true)
    dired_enter_edit_mode(&d, &e, nil, nil)
    set_editor_text(&e, "renamed_dir/\n")
    msg4 := dired_apply_edits(&d, &e)
    // renamed.txt is not present in the new listing, so it is removed as well
    testing.expect_value(t, msg4, "Dired: applied changes (0 created, 1 renamed, 1 deleted)")
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/dired_apply/old_dir"), false)
    testing.expect_value(t, os.is_dir("/tmp/odin_editor_tests/dired_apply/renamed_dir"), true)
    fmt.println("  ✓ [Dired] wdired create/delete/rename applied on disk")
}

@(test)
test_dired_dispatch_uses_config_keys :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dired_dispatch"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    names := []string{"a", "b", "c", "d", "e", "f"}
    for name in names {
        path := fmt.tprintf("%s/%s.txt", dir, name)
        testing.expect(t, os.write_entire_file_from_string(path, "") == nil)
    }

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)
    testing.expect(t, dired_load_path(&d, dir))
    testing.expect_value(t, len(d.entries), 7) // ".." + six files

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane

    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.key = KEY_DIRED_DOWN
    ev.key.mod = {}
    testing.expect_value(t, dired_handle_event(&d, &ev, &app, pane), true)
    testing.expect_value(t, d.cursor, 1)

    ev.key.key = KEY_DIRED_PAGE_DOWN
    ev.key.mod = sdl.KMOD_CTRL
    testing.expect_value(t, dired_handle_event(&d, &ev, &app, pane), true)
    testing.expect_value(t, d.cursor, 6)

    ev.key.key = KEY_DIRED_UP
    ev.key.mod = {}
    testing.expect_value(t, dired_handle_event(&d, &ev, &app, pane), true)
    testing.expect_value(t, d.cursor, 5)

    before := d.sort_by
    ev.key.key = KEY_DIRED_SORT
    testing.expect_value(t, dired_handle_event(&d, &ev, &app, pane), true)
    testing.expect(t, d.sort_by != before)
    fmt.println("  ✓ [Dired] dispatch follows configured key constants")
}

@(test)
test_dired_symlink_directory :: proc(t: ^testing.T) {
    root := "/tmp/odin_editor_tests/dired_symlink"
    _ = os.remove_all(root)
    testing.expect(t, os.make_directory_all(root) == nil)
    defer os.remove_all(root)

    target := fmt.tprintf("%s/real_dir", root)
    link := fmt.tprintf("%s/link_dir", root)
    testing.expect(t, os.make_directory(target) == nil)
    testing.expect(t, os.symlink(target, link) == nil)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)
    testing.expect(t, dired_load_path(&d, root))

    found := false
    for e in d.entries {
        if e.name == "link_dir" {
            found = true
            testing.expect_value(t, e.is_dir, true)
        }
    }
    testing.expect_value(t, found, true)
    fmt.println("  ✓ [Dired] symlinked directories are treated as directories")
}

@(test)
test_dired_wdired_rejects_unsafe_edits :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dired_wdired_validate"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    file := fmt.tprintf("%s/a.txt", dir)
    testing.expect(t, os.write_entire_file_from_string(file, "original") == nil)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)
    testing.expect(t, dired_load_path(&d, dir))

    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)
    dired_enter_edit_mode(&d, &e, nil, nil)

    // Duplicate entries must not truncate the existing file.
    set_editor_text(&e, "a.txt\na.txt\n")
    msg := dired_apply_edits(&d, &e)
    testing.expect(t, strings.contains(msg, "duplicate"), msg)

    // Path separators must not escape the listed directory.
    set_editor_text(&e, "a.txt\n../escape.txt\n")
    msg = dired_apply_edits(&d, &e)
    testing.expect(t, strings.contains(msg, "invalid name"), msg)
    testing.expect_value(t, os.exists("/tmp/odin_editor_tests/escape.txt"), false)

    // Changing a file into a directory (or vice versa) is refused.
    set_editor_text(&e, "a.txt/\n")
    msg = dired_apply_edits(&d, &e)
    testing.expect(t, strings.contains(msg, "cannot change"), msg)

    content, read_err := os.read_entire_file(file, context.temp_allocator)
    testing.expect_value(t, read_err, nil)
    testing.expect_value(t, string(content), "original")
    fmt.println("  ✓ [Dired] wdired rejects duplicates, path escapes and type changes")
}

@(test)
test_dired_async_load_and_stale_results :: proc(t: ^testing.T) {
    dir1 := "/tmp/odin_editor_tests/dired_async_one"
    dir2 := "/tmp/odin_editor_tests/dired_async_two"
    _ = os.remove_all(dir1)
    _ = os.remove_all(dir2)
    testing.expect(t, os.make_directory_all(dir1) == nil)
    testing.expect(t, os.make_directory_all(dir2) == nil)
    defer os.remove_all(dir1)
    defer os.remove_all(dir2)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/one.txt", dir1), "") == nil)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/two.txt", dir2), "") == nil)

    d: Dired
    dired_init(&d)
    defer dired_destroy(&d)

    dired_request_load(&d, dir1, .Name, .Asc)
    testing.expect_value(t, d.loading, true)
    dired_wait_load(&d)
    testing.expect_value(t, d.loading, false)
    testing.expect_value(t, d.path, dir1)
    testing.expect_value(t, len(d.entries), 2)

    // A second request supersedes the first; only the newest listing lands.
    dired_request_load(&d, dir1, .Name, .Asc)
    dired_request_load(&d, dir2, .Name, .Asc)
    dired_wait_load(&d)
    testing.expect_value(t, d.path, dir2)
    found_two := false
    for e in d.entries {
        if e.name == "two.txt" do found_two = true
        testing.expect(t, e.name != "one.txt")
    }
    testing.expect_value(t, found_two, true)
    fmt.println("  ✓ [Dired] async loads apply the latest generation only")
}
