package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "base:runtime"
LanguageKind :: enum {
    Plaintext,
    Odin,
    Zig,
    C,
    Cpp,
    Rust,
    Go,
    C3,
    Hare,
    Rela,
    Bash,
    Lua,
    Toml,
    Kdl,
    Makefile,
}

LspServerKind :: enum {
    Odin,
    Zig,
    Clangd,
    Rust,
    Go,
    C3,
}

// LSP defaults to UTF-16 code units; servers that negotiate UTF-8 give byte
// columns directly, which is what the editor already stores.
Lsp_Position_Encoding :: enum {
    UTF16,
    UTF8,
}

language_from_file_path :: proc(path: string) -> LanguageKind {
    if path == "" do return .Plaintext
    base := filepath.base(path)
    if base == "Makefile" || base == "makefile" || base == "GNUmakefile" {
        return .Makefile
    }
    if base == ".bashrc" || base == ".profile" || base == ".bash_profile" || base == "bash.bashrc" || base == ".zshrc" {
        return .Bash
    }
    ext := filepath.ext(path)
    switch ext {
    case ".odin": return .Odin
    case ".zig", ".zon": return .Zig
    case ".c", ".h": return .C
    case ".cpp", ".hpp", ".cc", ".cxx", ".hh", ".hxx": return .Cpp
    case ".rs": return .Rust
    case ".go": return .Go
    case ".c3", ".c3i": return .C3
    case ".ha": return .Hare
    case ".rela": return .Rela
    case ".sh", ".bash", ".zsh": return .Bash
    case ".lua": return .Lua
    case ".toml": return .Toml
    case ".kdl": return .Kdl
    case ".mk": return .Makefile
    }
    return .Plaintext
}

language_to_server_kind :: proc(lang: LanguageKind) -> (LspServerKind, bool) {
    #partial switch lang {
    case .Odin: return .Odin, true
    case .Zig: return .Zig, true
    case .C, .Cpp: return .Clangd, true
    case .Rust: return .Rust, true
    case .Go: return .Go, true
    case .C3: return .C3, true
    }
    return .Odin, false
}

language_id_string :: proc(lang: LanguageKind) -> string {
    #partial switch lang {
    case .Odin: return "odin"
    case .Zig: return "zig"
    case .C: return "c"
    case .Cpp: return "cpp"
    case .Rust: return "rust"
    case .Go: return "go"
    case .C3: return "c3"
    }
    return "plaintext"
}

LspSeverity :: enum {
    Error       = 1,
    Warning     = 2,
    Information = 3,
    Hint        = 4,
}

LspDiagnostic :: struct {
    start_row : int,
    start_col : int,
    end_row   : int,
    end_col   : int,
    severity  : LspSeverity,
    message   : string,
}

LspCompletionItem :: struct {
    label         : string,
    detail        : string,
    documentation : string,
    insert_text   : string,
    kind          : int,
}

LspLocation :: struct {
    file_path : string,
    row       : int,
    col       : int,
}

LspTextEdit :: struct {
    start_row : int,
    start_col : int,
    end_row   : int,
    end_col   : int,
    new_text  : string,
}

LspRequestKind :: enum {
    None,
    Initialize,
    Definition,
    Hover,
    Completion,
    RangeFormatting,
}

PendingRequest :: struct {
    id        : int,
    kind      : LspRequestKind,
    file_path : string,
    start_row : int,
    end_row   : int,
    sent_at   : time.Time,
}

Lsp_Out_Kind :: enum {
    Raw,
    Did_Change,
}

// Owned by the writer queue; strings use runtime.default_allocator().
Lsp_Out_Message :: struct {
    kind      : Lsp_Out_Kind,
    raw       : string, // .Raw payload, already valid JSON
    uri       : string, // .Did_Change target
    file_path : string, // .Did_Change coalescing key
    text      : string, // .Did_Change full document snapshot
    version   : int,
}

LspClient :: struct {
    server_cmd       : string,
    server_kind      : LspServerKind,
    root_dir         : string,
    started_at       : time.Time,
    process          : os.Process,
    stdin_file       : ^os.File,
    stdout_file      : ^os.File,
    reader_thread    : ^thread.Thread,
    writer_thread    : ^thread.Thread,
    writer_mutex     : sync.Mutex,
    writer_cond      : sync.Cond,
    writer_queue     : [dynamic]Lsp_Out_Message,
    writer_running   : bool,
    running          : bool,
    initialized      : bool,
    next_id          : int,
    mutex            : sync.Mutex,
    incoming_queue   : [dynamic]json.Value,
    pending_requests : [dynamic]PendingRequest,
    // Diagnostics map: file_path -> [dynamic]LspDiagnostic
    diagnostics      : map[string][dynamic]LspDiagnostic,
    // Latest completions
    completions      : [dynamic]LspCompletionItem,
    completions_file : string,
    // Pending results to be handled by editor
    last_definition  : Maybe(LspLocation),
    last_hover       : string,
    last_hover_file  : string,
    last_edits       : [dynamic]LspTextEdit,
    last_edits_file  : string,
    last_hover_title : string,
    file_versions    : map[string]int,
    file_texts       : map[string]string,
    position_encoding: Lsp_Position_Encoding,
}

// `running` is touched by the main, reader, and writer threads.
lsp_is_running :: proc(client: ^LspClient) -> bool {
    return sync.atomic_load(&client.running)
}

lsp_set_running :: proc(client: ^LspClient, running: bool) {
    sync.atomic_store(&client.running, running)
}

lsp_uri_encode_path :: proc(path: string, allocator := context.temp_allocator) -> string {
    hex := "0123456789ABCDEF"
    b: strings.Builder
    strings.builder_init(&b, 0, len(path) + 16, allocator)

    for ch in transmute([]u8)path {
        if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
           (ch >= '0' && ch <= '9') || ch == '/' || ch == '-' || ch == '_' ||
           ch == '.' || ch == '~' {
            strings.write_byte(&b, ch)
        } else {
            strings.write_byte(&b, '%')
            strings.write_byte(&b, hex[ch >> 4])
            strings.write_byte(&b, hex[ch & 0x0F])
        }
    }
    return strings.to_string(b)
}

lsp_uri_decode_path :: proc(uri_path: string, allocator := context.temp_allocator) -> string {
    hex_value :: proc(ch: byte) -> int {
        if ch >= '0' && ch <= '9' do return int(ch - '0')
        if ch >= 'a' && ch <= 'f' do return int(ch - 'a') + 10
        if ch >= 'A' && ch <= 'F' do return int(ch - 'A') + 10
        return -1
    }

    b: strings.Builder
    strings.builder_init(&b, 0, len(uri_path), allocator)

    i := 0
    for i < len(uri_path) {
        if uri_path[i] == '%' && i + 2 < len(uri_path) {
            hi := hex_value(uri_path[i + 1])
            lo := hex_value(uri_path[i + 2])
            if hi >= 0 && lo >= 0 {
                strings.write_byte(&b, byte(hi * 16 + lo))
                i += 3
                continue
            }
        }
        strings.write_byte(&b, uri_path[i])
        i += 1
    }
    return strings.to_string(b)
}

lsp_path_to_uri :: proc(path: string, allocator := context.temp_allocator) -> string {
    clean_p := path
    if !filepath.is_abs(path) {
        if abs_path, err := filepath.abs(path, context.temp_allocator); err == nil {
            clean_p = abs_path
        } else if cwd, cwd_err := os.get_working_directory(context.temp_allocator); cwd_err == nil {
            // The file may not exist yet, which makes realpath fail.
            if joined, join_err := filepath.join([]string{cwd, path}, context.temp_allocator); join_err == nil {
                clean_p = joined
            }
        }
    }
    escaped := lsp_uri_encode_path(clean_p, context.temp_allocator)
    return fmt.aprintf("file://%s", escaped, allocator = allocator)
}

lsp_uri_to_path :: proc(uri: string, allocator := context.temp_allocator) -> string {
    if strings.has_prefix(uri, "file://") {
        return lsp_uri_decode_path(uri[7:], allocator)
    }
    return strings.clone(uri, allocator)
}

// Background thread reader loop
lsp_reader_thread_proc :: proc(data: rawptr) {
    client := (^LspClient)(data)

    read_buf: [4096]u8
    accum: [dynamic]u8
    accum = make([dynamic]u8, 0, 8192)
    defer delete(accum)

    for lsp_is_running(client) {
        n, err := os.read(client.stdout_file, read_buf[:])
        if err != nil || n <= 0 {
            break
        }

        for i in 0 ..< n {
            append(&accum, read_buf[i])
        }

        // Process all complete messages in accumulator
        for {
            raw_str := string(accum[:])
            header_end := strings.index(raw_str, "\r\n\r\n")
            sep_len := 4
            if header_end < 0 {
                header_end = strings.index(raw_str, "\n\n")
                sep_len = 2
            }
            if header_end < 0 do break // Need more header data

            header_part := raw_str[:header_end]
            content_length := -1

            cl_prefix := "Content-Length:"
            cl_idx := strings.index(header_part, cl_prefix)
            if cl_idx < 0 {
                cl_prefix = "content-length:"
                cl_idx = strings.index(header_part, cl_prefix)
            }
            if cl_idx >= 0 {
                val_part := header_part[cl_idx + len(cl_prefix):]
                end_of_val := strings.index_byte(val_part, '\r')
                if end_of_val < 0 do end_of_val = strings.index_byte(val_part, '\n')
                if end_of_val >= 0 do val_part = val_part[:end_of_val]
                val_part = strings.trim_space(val_part)
                if val, ok := strconv.parse_int(val_part); ok {
                    content_length = val
                }
            }

            if content_length < 0 {
                // Malformed header, skip
                remove_range(&accum, 0, header_end + sep_len)
                continue
            }

            body_start := header_end + sep_len
            if len(accum) < body_start + content_length {
                // Wait for more body bytes
                break
            }

            // Extract complete JSON payload. `string(json_bytes)` aliases the
            // accumulator, so parse BEFORE remove_range shifts the buffer down;
            // otherwise the next buffered message overwrites this payload.
            json_bytes := accum[body_start : body_start + content_length]
            val, err := json.parse_string(string(json_bytes), allocator = runtime.default_allocator())

            // Remove processed message from accumulator
            remove_range(&accum, 0, body_start + content_length)

            if err != nil do continue

            sync.mutex_lock(&client.mutex)
            append(&client.incoming_queue, val)
            sync.mutex_unlock(&client.mutex)
        }
    }

    // The server closed its stdout or the read failed. Mark the client dead so
    // the manager can restart it instead of queueing requests forever.
    lsp_set_running(client, false)
}

// Release the containers allocated by lsp_start when spawning the server
// fails. At that point they are empty; lsp_stop handles the running case.
lsp_release_start_state :: proc(client: ^LspClient) {
    if client.server_cmd != "" do delete(client.server_cmd)
    client.server_cmd = ""
    delete(client.incoming_queue)
    client.incoming_queue = nil
    delete(client.writer_queue)
    client.writer_queue = nil
    delete(client.pending_requests)
    client.pending_requests = nil
    delete(client.diagnostics)
    client.diagnostics = nil
    delete(client.completions)
    client.completions = nil
    delete(client.last_edits)
    client.last_edits = nil
    delete(client.file_versions)
    client.file_versions = nil
}

lsp_start :: proc(client: ^LspClient, server_cmd: string, root_dir: string) -> bool {
    // A dead server makes writes to its stdin raise SIGPIPE. The app's main
    // ignores it, but test runners and other entry points may not.
    posix.sigignore(.SIGPIPE)

    // Ensure OLS finds its builtins folder. The config override wins; the
    // candidate list is only a convenience fallback.
    builtin_path := LSP_OLS_BUILTIN_FOLDER
    if builtin_path == "" && strings.contains(server_cmd, "ols") {
        builtin_candidates := []string{
            "/home/fnln/.local/share/nvim/mason/packages/ols/builtin",
            "/home/fnln/dev/ols/builtin",
            "/usr/lib/odin/base/builtin",
        }
        for cand in builtin_candidates {
            if os.exists(cand) {
                builtin_path = cand
                break
            }
        }
    }

    client.server_cmd = strings.clone(server_cmd, context.allocator)
    lsp_set_running(client, false)
    client.initialized = false
    client.next_id = 1
    client.incoming_queue = make([dynamic]json.Value, 0, 64)
    client.writer_queue = make([dynamic]Lsp_Out_Message, 0, 16)
    client.writer_running = false
    client.pending_requests = make([dynamic]PendingRequest, 0, 16)
    client.diagnostics = make(map[string][dynamic]LspDiagnostic)
    client.completions = make([dynamic]LspCompletionItem, 0, 32)
    client.last_edits = make([dynamic]LspTextEdit, 0, 8)
    client.file_versions = make(map[string]int)
    client.file_texts = make(map[string]string)
    client.position_encoding = .UTF16

    // Serialize pipes and spawning with compilation workers: process_start
    // mutates descriptor inheritance for the whole process.
    sync.mutex_lock(&process_spawn_mutex)
    in_r, in_w, err1 := os.pipe()
    if err1 != nil {
        sync.mutex_unlock(&process_spawn_mutex)
        lsp_release_start_state(client)
        return false
    }
    out_r, out_w, err2 := os.pipe()
    if err2 != nil {
        os.close(in_r); os.close(in_w)
        sync.mutex_unlock(&process_spawn_mutex)
        lsp_release_start_state(client)
        return false
    }

    // Build the child environment explicitly instead of mutating the global
    // environment (which races with compilation's process_exec on another
    // thread and grew PATH on every LSP start).
    extra_paths := LSP_EXTRA_PATHS
    curr_path, has_path := os.lookup_env("PATH", context.temp_allocator)
    has_path = has_path && curr_path != ""

    env_list: [dynamic]string
    defer delete(env_list)
    base_env, _ := os.environ(context.temp_allocator)
    for entry in base_env {
        // Odin's os.environ() currently includes a trailing empty entry
        // (the terminating NULL). Passing "" in envp makes some servers,
        // notably ZLS, abort with a recursive panic.
        if entry == "" do continue
        if has_path && strings.has_prefix(entry, "PATH=") do continue
        if builtin_path != "" && strings.has_prefix(entry, "OLS_BUILTIN_FOLDER=") do continue
        append(&env_list, entry)
    }
    if has_path {
        if extra_paths != "" {
            append(&env_list, fmt.tprintf("PATH=%s:%s", extra_paths, curr_path))
        } else {
            append(&env_list, fmt.tprintf("PATH=%s", curr_path))
        }
    }
    if builtin_path != "" {
        append(&env_list, fmt.tprintf("OLS_BUILTIN_FOLDER=%s", builtin_path))
    }

    cmd := []string{server_cmd}
    desc := os.Process_Desc{
        command     = cmd,
        working_dir = root_dir,
        stdin       = in_r,
        stdout      = out_w,
        stderr      = nil,
        env         = env_list[:],
    }

    p, perr := os.process_start(desc)
    if perr != nil {
        os.close(in_r); os.close(in_w)
        os.close(out_r); os.close(out_w)
        sync.mutex_unlock(&process_spawn_mutex)
        lsp_release_start_state(client)
        return false
    }

    // Close child's ends in parent.
    os.close(in_r)
    os.close(out_w)
    sync.mutex_unlock(&process_spawn_mutex)

    client.process = p
    client.stdin_file = in_w
    client.stdout_file = out_r
    lsp_set_running(client, true)

    // Start reader and writer threads
    client.reader_thread = background_thread(rawptr(client), lsp_reader_thread_proc)
    sync.mutex_lock(&client.writer_mutex)
    client.writer_running = true
    sync.mutex_unlock(&client.writer_mutex)
    client.writer_thread = background_thread(rawptr(client), lsp_writer_thread_proc)

    // Send initialize request
    root_uri := lsp_path_to_uri(root_dir)
    folder_name := filepath.base(root_dir)
    init_json := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{{"processId":null,"rootUri":"%s","workspaceFolders":[{{"uri":"%s","name":"%s"}}],"capabilities":{{"general":{{"positionEncodings":["utf-8","utf-16"]}},"workspace":{{"configuration":true,"workspaceFolders":true}},"textDocument":{{"synchronization":{{"didSave":true}},"publishDiagnostics":{{"relatedInformation":true}},"completion":{{"completionItem":{{"snippetSupport":false,"documentationFormat":["plaintext","markdown"]}}}},"hover":{{"contentFormat":["plaintext","markdown"]}},"definition":{{}},"formatting":{{}},"rangeFormatting":{{}}}}}}}}}}`,
        client.next_id,
        root_uri,
        root_uri,
        folder_name,
    )
    append(&client.pending_requests, PendingRequest{id = client.next_id, kind = .Initialize, sent_at = time.now()})
    client.next_id += 1
    lsp_send_raw(client, init_json)

    return true
}

lsp_wait_thread_done :: proc(t: ^thread.Thread, duration: time.Duration) -> bool {
    if t == nil do return true
    start := time.now()
    for !thread.is_done(t) {
        if time.since(start) >= duration do return false
        time.sleep(1 * time.Millisecond)
    }
    return true
}

lsp_kill_and_wait :: proc(client: ^LspClient) {
    if client.process.pid == 0 do return
    _ = os.process_kill(client.process)
    _, _ = os.process_wait(client.process, 2 * time.Second)
    client.process = {}
}

// Stop a client without ever blocking the UI indefinitely. Returns false when
// a thread could not be joined; the caller must then leak the client rather
// than free memory the live thread still touches.
lsp_stop :: proc(client: ^LspClient) -> bool {
    if client == nil do return true

    // Queue the graceful shutdown before sends are disabled, then let the
    // writer drain everything it has before closing the pipe.
    if client.stdin_file != nil && client.initialized {
        shutdown_msg := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"shutdown","params":null}}`, client.next_id)
        client.next_id += 1
        lsp_send_raw(client, shutdown_msg)
        exit_msg := `{"jsonrpc":"2.0","method":"exit","params":null}`
        lsp_send_raw(client, exit_msg)
    }

    lsp_set_running(client, false)

    sync.mutex_lock(&client.writer_mutex)
    client.writer_running = false
    sync.mutex_unlock(&client.writer_mutex)
    sync.cond_signal(&client.writer_cond)

    writer_ok := true
    if client.writer_thread != nil {
        writer_ok = lsp_wait_thread_done(client.writer_thread, 300 * time.Millisecond)
    }
    if !writer_ok {
        // A wedged write keeps the queue from draining; kill the process to
        // break the pipe, then give the writer a bounded chance to exit.
        lsp_kill_and_wait(client)
        writer_ok = lsp_wait_thread_done(client.writer_thread, 500 * time.Millisecond)
    }
    if client.writer_thread != nil && writer_ok {
        thread.join(client.writer_thread)
        thread.destroy(client.writer_thread)
        client.writer_thread = nil
    }
    if client.stdin_file != nil && writer_ok {
        os.close(client.stdin_file)
        client.stdin_file = nil
    }

    // Make sure the child is gone even when the writer exited cleanly.
    lsp_kill_and_wait(client)

    // The reader is blocked in os.read(); killing the child closes the write
    // end, so give it a bounded chance to observe EOF before we close/free the
    // file object it is using.
    reader_ok := true
    if client.reader_thread != nil {
        reader_ok = lsp_wait_thread_done(client.reader_thread, 1000 * time.Millisecond)
        if reader_ok {
            thread.join(client.reader_thread)
            thread.destroy(client.reader_thread)
            client.reader_thread = nil
        }
    }
    if client.stdout_file != nil && reader_ok {
        os.close(client.stdout_file)
        client.stdout_file = nil
    }

    if !writer_ok || !reader_ok {
        return false
    }

    for &m in client.writer_queue do lsp_destroy_out_message(&m)
    delete(client.writer_queue)
    client.writer_queue = nil

    for q in client.incoming_queue do json.destroy_value(q, runtime.default_allocator())
    delete(client.incoming_queue)
    for req in client.pending_requests {
        if req.file_path != "" do delete(req.file_path)
    }
    delete(client.pending_requests)

    for k, v in client.diagnostics {
        delete(k)
        for d in v do delete(d.message)
        delete(v)
    }
    delete(client.diagnostics)

    for c in client.completions {
        delete(c.label)
        delete(c.detail)
        delete(c.documentation)
        delete(c.insert_text)
    }
    delete(client.completions)
    if client.completions_file != "" do delete(client.completions_file)

    for e in client.last_edits do delete(e.new_text)
    delete(client.last_edits)
    if client.last_edits_file != "" do delete(client.last_edits_file)

    if loc, ok := client.last_definition.?; ok && loc.file_path != "" do delete(loc.file_path)
    if client.last_hover != "" do delete(client.last_hover)
    if client.last_hover_file != "" do delete(client.last_hover_file)
    if client.last_hover_title != "" do delete(client.last_hover_title)
    if client.server_cmd != "" do delete(client.server_cmd)
    if client.root_dir != "" do delete(client.root_dir)
    for k in client.file_versions do delete(k)
    delete(client.file_versions)
    for k, v in client.file_texts {
        delete(k)
        delete(v)
    }
    delete(client.file_texts)
    return true
}

Lsp_Key :: struct {
    kind: LspServerKind,
    root: string,
}

// A document tracked by the manager. `refs` counts editor panes showing it;
// the server receives didOpen once and didClose when the last pane goes away.
Lsp_Doc :: struct {
    refs:   int,
    text:   string,
    client: ^LspClient,
    opened: bool,
}

LspManager :: struct {
    clients      : [dynamic]^LspClient,
    docs         : map[string]^Lsp_Doc,
    project_root : string,
    // Throttle failed spawn attempts (missing servers) per (kind, root).
    attempted    : map[Lsp_Key]time.Time,
    last_message : string,
    spawn_enabled: bool,
}

lsp_manager_init :: proc(mgr: ^LspManager, project_root: string) {
    mgr.clients = make([dynamic]^LspClient, 0, 4)
    mgr.docs = make(map[string]^Lsp_Doc)
    mgr.attempted = make(map[Lsp_Key]time.Time)
    mgr.project_root = lsp_abs_path(project_root, context.allocator) if project_root != "" else ""
    mgr.last_message = ""
    mgr.spawn_enabled = true
}

lsp_manager_set_project_root :: proc(mgr: ^LspManager, root: string) {
    if mgr.project_root != "" do delete(mgr.project_root)
    mgr.project_root = lsp_abs_path(root, context.allocator) if root != "" else ""
    lsp_manager_retarget(mgr)
}

lsp_manager_report :: proc(mgr: ^LspManager, msg: string) {
    if mgr.last_message != "" do delete(mgr.last_message)
    mgr.last_message = strings.clone(msg, context.allocator)
}

lsp_find_project_root :: proc(file_path: string, fallback_dir: string) -> string {
    if file_path == "" do return strings.clone(fallback_dir, context.allocator)
    abs_path, abs_err := filepath.abs(file_path, context.temp_allocator)
    if abs_err != nil {
        abs_path, _ = filepath.clean(file_path, context.temp_allocator)
    }
    dir := filepath.dir(abs_path)

    for dir != "" && dir != "/" && dir != "." {
        markers := []string{
            ".git",
            "ols.json",
            "build.zig",
            "Cargo.toml",
            "go.mod",
            "project.json",
            "compile_commands.json",
            "Makefile",
        }
        for m in markers {
            check, _ := filepath.join([]string{dir, m}, context.temp_allocator)
            if os.exists(check) {
                return strings.clone(dir, context.allocator)
            }
        }
        parent := filepath.dir(dir)
        if parent == dir || parent == "." do break
        dir = parent
    }
    return strings.clone(fallback_dir, context.allocator)
}

lsp_find_server_cmd :: proc(server: LspServerKind) -> (string, bool) {
    cmd := ""
    switch server {
    case .Odin:    cmd = LSP_ODIN_COMMAND
    case .Zig:     cmd = LSP_ZIG_COMMAND
    case .Clangd:  cmd = LSP_CLANGD_COMMAND
    case .Rust:    cmd = LSP_RUST_COMMAND
    case .Go:      cmd = LSP_GO_COMMAND
    case .C3:      cmd = LSP_C3_COMMAND
    }
    if cmd == "" do return "", false
    return cmd, true
}

lsp_abs_path :: proc(path: string, allocator: runtime.Allocator) -> string {
    abs, err := filepath.abs(path, allocator)
    if err != nil {
        cleaned, _ := filepath.clean(path, allocator)
        return cleaned
    }
    return abs
}

lsp_path_is_under :: proc(path, root: string) -> bool {
    if path == "" || root == "" do return false
    if path == root do return true
    if strings.has_suffix(root, "/") do return strings.has_prefix(path, root)
    return strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/'
}

// Project root used for a file: the configured project root when the file is
// inside it, otherwise the nearest marker-based project (multi-root support).
lsp_root_for_file :: proc(mgr: ^LspManager, file_path: string) -> string {
    abs := lsp_abs_path(file_path, context.temp_allocator)
    if mgr.project_root != "" && lsp_path_is_under(abs, mgr.project_root) {
        return strings.clone(mgr.project_root, context.allocator)
    }
    return lsp_find_project_root(abs, mgr.project_root)
}

lsp_manager_find_client :: proc(mgr: ^LspManager, kind: LspServerKind, root: string) -> ^LspClient {
    for c in mgr.clients {
        if c.server_kind == kind && c.root_dir == root do return c
    }
    return nil
}

// Lookup only; never spawns. Rendering uses this so draw cannot fork.
lsp_manager_peek :: proc(mgr: ^LspManager, lang: LanguageKind, file_path: string) -> ^LspClient {
    kind, has_server := language_to_server_kind(lang)
    if !has_server do return nil
    root := lsp_root_for_file(mgr, file_path)
    defer delete(root)
    client := lsp_manager_find_client(mgr, kind, root)
    if client != nil && lsp_is_running(client) do return client
    return nil
}

lsp_manager_spawn_client :: proc(mgr: ^LspManager, kind: LspServerKind, root: string) -> ^LspClient {
    if existing := lsp_manager_find_client(mgr, kind, root); existing != nil {
        return existing
    }

    server_cmd, found := lsp_find_server_cmd(kind)
    if !found do return nil

    key := Lsp_Key{kind = kind, root = root}
    now := time.now()
    if last, tried := mgr.attempted[key]; tried && time.since(last) < time.Second {
        return nil
    }
    if _, tried := mgr.attempted[key]; !tried {
        mgr.attempted[Lsp_Key{kind = kind, root = strings.clone(root, context.allocator)}] = now
    } else {
        mgr.attempted[key] = now
    }

    client := new(LspClient)
    client.server_kind = kind
    client.root_dir = strings.clone(root, context.allocator)
    client.started_at = now
    if !lsp_start(client, server_cmd, root) {
        lsp_release_start_state(client)
        if client.root_dir != "" do delete(client.root_dir)
        free(client)
        return nil
    }
    append(&mgr.clients, client)
    return client
}

lsp_manager_client_for_file :: proc(mgr: ^LspManager, file_path: string, spawn: bool) -> ^LspClient {
    lang := language_from_file_path(file_path)
    kind, has_server := language_to_server_kind(lang)
    if !has_server do return nil
    root := lsp_root_for_file(mgr, file_path)
    defer delete(root)
    client := lsp_manager_find_client(mgr, kind, root)
    if client != nil {
        if lsp_is_running(client) do return client
        // Dead; detached by poll and retried there.
        return nil
    }
    if spawn do return lsp_manager_spawn_client(mgr, kind, root)
    return nil
}

lsp_manager_attach_doc :: proc(mgr: ^LspManager, path: string, doc: ^Lsp_Doc) {
    client := lsp_manager_client_for_file(mgr, path, spawn = false)
    if doc.client != nil && doc.client != client && doc.opened {
        lsp_did_close(doc.client, path)
    }
    if doc.client != client {
        doc.client = client
        doc.opened = false
    }
}

lsp_manager_open_doc :: proc(mgr: ^LspManager, file_path: string, text: string) {
    if file_path == "" || strings.has_prefix(file_path, "*") do return
    path := lsp_abs_path(file_path, context.temp_allocator)
    if doc, exists := mgr.docs[path]; exists {
        doc.refs += 1
        if doc.text != "" do delete(doc.text)
        doc.text = strings.clone(text, context.allocator)
        lsp_manager_attach_doc(mgr, path, doc)
        return
    }

    doc := new(Lsp_Doc)
    doc.refs = 1
    doc.text = strings.clone(text, context.allocator)
    doc.client = nil
    doc.opened = false
    key := strings.clone(path, context.allocator)
    mgr.docs[key] = doc
    lsp_manager_attach_doc(mgr, path, doc)
}

lsp_manager_change_doc :: proc(mgr: ^LspManager, file_path: string, text: string) {
    if file_path == "" do return
    path := lsp_abs_path(file_path, context.temp_allocator)
    doc, exists := mgr.docs[path]
    if !exists do return
    if doc.text != "" do delete(doc.text)
    doc.text = strings.clone(text, context.allocator)
    if doc.client != nil && lsp_is_running(doc.client) && doc.client.initialized {
        if !doc.opened {
            lsp_did_open(doc.client, path, text)
            doc.opened = true
        } else {
            lsp_did_change(doc.client, path, text)
        }
    }
}

lsp_manager_close_doc :: proc(mgr: ^LspManager, file_path: string) {
    if file_path == "" do return
    path := lsp_abs_path(file_path, context.temp_allocator)
    doc, exists := mgr.docs[path]
    if !exists do return
    doc.refs -= 1
    if doc.refs > 0 do return

    if doc.client != nil && doc.opened do lsp_did_close(doc.client, path)
    if doc.text != "" do delete(doc.text)
    free(doc)
    for key in mgr.docs {
        if key == path {
            delete_key(&mgr.docs, key)
            delete(key, context.allocator)
            break
        }
    }
}

lsp_manager_retarget :: proc(mgr: ^LspManager) {
    for path, doc in mgr.docs {
        lsp_manager_attach_doc(mgr, path, doc)
    }
}

lsp_manager_retire_client :: proc(mgr: ^LspManager, client: ^LspClient) {
    for _, doc in mgr.docs {
        if doc.client == client {
            doc.client = nil
            doc.opened = false
        }
    }
    for i := 0; i < len(mgr.clients); i += 1 {
        if mgr.clients[i] == client {
            ordered_remove(&mgr.clients, i)
            break
        }
    }
    fully_stopped := lsp_stop(client)
    if fully_stopped {
        free(client)
    }
    // If a thread is wedged we deliberately leak the client rather than free
    // memory a live thread still dereferences.
}

lsp_manager_poll :: proc(mgr: ^LspManager) {
    // Dead or timed-out clients.
    for i := len(mgr.clients) - 1; i >= 0; i -= 1 {
        client := mgr.clients[i]
        timed_out := false
        if lsp_is_running(client) && !client.initialized && time.since(client.started_at) > 10 * time.Second {
            timed_out = true
            lsp_manager_report(mgr, "LSP: server initialization timed out")
        }
        if lsp_is_running(client) && client.initialized {
            for req in client.pending_requests {
                if time.since(req.sent_at) > 30 * time.Second {
                    timed_out = true
                    lsp_manager_report(mgr, "LSP: request timed out")
                    break
                }
            }
        }
        if !lsp_is_running(client) || timed_out {
            lsp_manager_retire_client(mgr, client)
        }
    }

    // Attach unassigned docs to (possibly newly spawned) clients.
    for path, doc in mgr.docs {
        if doc.client == nil {
            client := lsp_manager_client_for_file(mgr, path, spawn = mgr.spawn_enabled)
            if client != nil {
                doc.client = client
                doc.opened = false
            }
        }
    }

    // Open every attached document exactly once after initialize.
    for path, doc in mgr.docs {
        if doc.client != nil && lsp_is_running(doc.client) && doc.client.initialized && !doc.opened {
            lsp_did_open(doc.client, path, doc.text)
            doc.opened = true
        }
    }

    // Drop clients that no longer own any document (e.g. after :root).
    for i := len(mgr.clients) - 1; i >= 0; i -= 1 {
        client := mgr.clients[i]
        used := false
        for _, doc in mgr.docs {
            if doc.client == client {
                used = true
                break
            }
        }
        if !used {
            lsp_manager_retire_client(mgr, client)
        }
    }
}

lsp_manager_stop_all :: proc(mgr: ^LspManager) {
    for i := len(mgr.clients) - 1; i >= 0; i -= 1 {
        client := mgr.clients[i]
        ordered_remove(&mgr.clients, i)
        if lsp_stop(client) do free(client)
    }
    for path, doc in mgr.docs {
        _ = path
        if doc.text != "" do delete(doc.text)
        free(doc)
    }
    for key in mgr.docs do delete(key, context.allocator)
    delete(mgr.docs)
    mgr.docs = nil
    for key in mgr.attempted do delete(key.root, context.allocator)
    delete(mgr.attempted)
    mgr.attempted = nil
    delete(mgr.clients)
    mgr.clients = nil
    if mgr.project_root != "" do delete(mgr.project_root)
    if mgr.last_message != "" do delete(mgr.last_message)
    mgr.project_root = ""
    mgr.last_message = ""
}

lsp_destroy_out_message :: proc(m: ^Lsp_Out_Message) {
    if m.raw != "" do delete(m.raw, runtime.default_allocator())
    if m.uri != "" do delete(m.uri, runtime.default_allocator())
    if m.file_path != "" do delete(m.file_path, runtime.default_allocator())
    if m.text != "" do delete(m.text, runtime.default_allocator())
    m^ = {}
}

// Called on the main thread; the writer thread owns the actual pipe writes.
lsp_send_raw :: proc(client: ^LspClient, json_str: string) {
    if client.stdin_file == nil || !lsp_is_running(client) do return
    sync.mutex_lock(&client.writer_mutex)
    append(&client.writer_queue, Lsp_Out_Message{
        kind = .Raw,
        raw = strings.clone(json_str, runtime.default_allocator()),
    })
    sync.mutex_unlock(&client.writer_mutex)
    sync.cond_signal(&client.writer_cond)
}

lsp_write_framed :: proc(client: ^LspClient, json_str: string) {
    if client.stdin_file == nil do return
    header_buf: [64]u8
    header := fmt.bprintf(header_buf[:], "Content-Length: %d\r\n\r\n", len(json_str))

    if _, err := os.write(client.stdin_file, transmute([]u8)header); err != nil {
        lsp_set_running(client, false)
        return
    }
    if _, err := os.write(client.stdin_file, transmute([]u8)json_str); err != nil {
        lsp_set_running(client, false)
    }
}

lsp_writer_thread_proc :: proc(data: rawptr) {
    client := (^LspClient)(data)

    for {
        msg: Lsp_Out_Message

        sync.mutex_lock(&client.writer_mutex)
        for len(client.writer_queue) == 0 {
            if !client.writer_running {
                sync.mutex_unlock(&client.writer_mutex)
                return
            }
            sync.cond_wait(&client.writer_cond, &client.writer_mutex)
        }
        msg = client.writer_queue[0]
        ordered_remove(&client.writer_queue, 0)
        sync.mutex_unlock(&client.writer_mutex)

        switch msg.kind {
        case .Raw:
            lsp_write_framed(client, msg.raw)

        case .Did_Change:
            b: strings.Builder
            strings.builder_init(&b, 0, len(msg.text) * 2 + 256, runtime.default_allocator())
            strings.write_string(&b, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"`)
            strings.write_string(&b, msg.uri)
            strings.write_string(&b, `","version":`)
            strings.write_int(&b, msg.version)
            strings.write_string(&b, `},"contentChanges":[{"text":"`)
            lsp_append_json_escaped(&b, msg.text)
            strings.write_string(&b, `"}]}}`)
            lsp_write_framed(client, strings.to_string(b))
            strings.builder_destroy(&b)
        }

        lsp_destroy_out_message(&msg)
    }
}

lsp_append_json_escaped :: proc(b: ^strings.Builder, s: string) {
    for ch in s {
        switch ch {
        case '\\': strings.write_string(b, "\\\\")
        case '"':  strings.write_string(b, "\\\"")
        case '\n': strings.write_string(b, "\\n")
        case '\r': strings.write_string(b, "\\r")
        case '\t': strings.write_string(b, "\\t")
        case:
            if ch < 0x20 {
                esc_buf: [8]u8
                strings.write_string(b, fmt.bprintf(esc_buf[:], "\\u%04x", u32(ch)))
            } else {
                strings.write_rune(b, ch)
            }
        }
    }
}

lsp_did_open :: proc(client: ^LspClient, file_path: string, text: string) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)

    // Map keys are borrowed, not copied; clone because callers such as the
    // picker pass strings from a per-frame temp allocator.
    if _, exists := client.file_versions[file_path]; !exists {
        client.file_versions[strings.clone(file_path, context.allocator)] = 1
    } else {
        client.file_versions[file_path] = 1
    }
    if old, exists := client.file_texts[file_path]; exists {
        delete(old)
        client.file_texts[file_path] = strings.clone(text, context.allocator)
    } else {
        client.file_texts[strings.clone(file_path, context.allocator)] = strings.clone(text, context.allocator)
    }

    lang := language_from_file_path(file_path)
    lang_id := language_id_string(lang)

    b: strings.Builder
    strings.builder_init(&b, 0, len(text) * 2 + 256, context.temp_allocator)
    strings.write_string(&b, `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"`)
    strings.write_string(&b, uri)
    strings.write_string(&b, `","languageId":"`)
    strings.write_string(&b, lang_id)
    strings.write_string(&b, `","version":1,"text":"`)
    lsp_append_json_escaped(&b, text)
    strings.write_string(&b, `"}}}`)
    lsp_send_raw(client, strings.to_string(b))
}

lsp_did_change :: proc(client: ^LspClient, file_path: string, text: string) {
    if !lsp_is_running(client) || !client.initialized do return

    ver := 2
    if v, ok := &client.file_versions[file_path]; ok {
        v^ += 1
        ver = v^
    } else {
        client.file_versions[strings.clone(file_path, context.allocator)] = 2
    }
    if old, exists := client.file_texts[file_path]; exists {
        delete(old)
        client.file_texts[file_path] = strings.clone(text, context.allocator)
    } else {
        client.file_texts[strings.clone(file_path, context.allocator)] = strings.clone(text, context.allocator)
    }

    // Unit tests exercise version bookkeeping without a live pipe.
    if client.stdin_file == nil do return

    // Coalesce only with a trailing snapshot for the same file. If a request
    // was queued after that snapshot, appending (not mutating) preserves the
    // text the request's positions were computed against.
    sync.mutex_lock(&client.writer_mutex)
    if len(client.writer_queue) > 0 {
        last := &client.writer_queue[len(client.writer_queue) - 1]
        if last.kind == .Did_Change && last.file_path == file_path {
            if last.text != "" do delete(last.text, runtime.default_allocator())
            last.text = strings.clone(text, runtime.default_allocator())
            last.version = ver
            sync.mutex_unlock(&client.writer_mutex)
            sync.cond_signal(&client.writer_cond)
            return
        }
    }

    uri := lsp_path_to_uri(file_path, runtime.default_allocator())
    append(&client.writer_queue, Lsp_Out_Message{
        kind      = .Did_Change,
        uri       = uri,
        file_path = strings.clone(file_path, runtime.default_allocator()),
        text      = strings.clone(text, runtime.default_allocator()),
        version   = ver,
    })
    sync.mutex_unlock(&client.writer_mutex)
    sync.cond_signal(&client.writer_cond)
}

lsp_did_save :: proc(client: ^LspClient, file_path: string) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":"%s"}}}}}}`,
        uri,
    )
    lsp_send_raw(client, msg)
}

lsp_did_close :: proc(client: ^LspClient, file_path: string) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path, context.temp_allocator)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":"%s"}}}}}}`,
        uri,
    )
    lsp_send_raw(client, msg)

    for k in client.file_versions {
        if k == file_path {
            delete_key(&client.file_versions, k)
            delete(k, context.allocator)
            break
        }
    }
    for k in client.file_texts {
        if k == file_path {
            text := client.file_texts[k]
            delete_key(&client.file_texts, k)
            delete(text, context.allocator)
            delete(k, context.allocator)
            break
        }
    }
    diag_key := ""
    diag_value: [dynamic]LspDiagnostic
    for k, v in client.diagnostics {
        if k == file_path {
            diag_key = k
            diag_value = v
            break
        }
    }
    if diag_key != "" {
        delete_key(&client.diagnostics, diag_key)
        for d in diag_value do delete(d.message)
        delete(diag_value)
        delete(diag_key, context.allocator)
    }
}

// Return one line (without CR) from a document snapshot. The returned string
// is cloned with `allocator`; callers using a temp allocator may ignore it.
lsp_line_from_text :: proc(text: string, row: int, allocator: runtime.Allocator) -> (string, bool) {
    if row < 0 do return "", false
    start := 0
    current := 0
    for i in 0 ..< len(text) {
        if text[i] == '\n' {
            if current == row {
                end := i
                if end > start && text[end - 1] == '\r' do end -= 1
                return strings.clone(text[start:end], allocator), true
            }
            current += 1
            start = i + 1
        }
    }
    if current == row {
        end := len(text)
        if end > start && text[end - 1] == '\r' do end -= 1
        return strings.clone(text[start:end], allocator), true
    }
    return "", false
}

lsp_read_line_from_disk :: proc(path: string, row: int, allocator: runtime.Allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil || data == nil do return "", false
    return lsp_line_from_text(string(data), row, allocator)
}

lsp_document_line :: proc(client: ^LspClient, path: string, row: int, allocator: runtime.Allocator) -> (string, bool) {
    if client != nil {
        if text, ok := client.file_texts[path]; ok {
            return lsp_line_from_text(text, row, allocator)
        }
    }
    return lsp_read_line_from_disk(path, row, allocator)
}

lsp_byte_col_to_character :: proc(client: ^LspClient, path: string, row, byte_col: int) -> int {
    if client == nil || client.position_encoding == .UTF8 do return byte_col
    line, ok := lsp_document_line(client, path, row, context.temp_allocator)
    if !ok do return byte_col
    col := clamp(byte_col, 0, len(line))
    units := 0
    i := 0
    for i < col {
        r, size := utf8.decode_rune_in_string(line[i:])
        if size <= 0 {
            size = 1
            r = utf8.RUNE_ERROR
        }
        units += 2 if r > 0xFFFF else 1
        i += size
    }
    return units
}

lsp_character_to_byte_col :: proc(client: ^LspClient, path: string, row, character: int) -> int {
    if client == nil || client.position_encoding == .UTF8 {
        return max(0, character)
    }
    line, ok := lsp_document_line(client, path, row, context.temp_allocator)
    if !ok do return max(0, character)
    remaining := max(0, character)
    i := 0
    for i < len(line) {
        r, size := utf8.decode_rune_in_string(line[i:])
        if size <= 0 {
            size = 1
            r = utf8.RUNE_ERROR
        }
        units := 2 if r > 0xFFFF else 1
        // A position inside a surrogate pair snaps to the rune start.
        if remaining < units do return i
        remaining -= units
        i += size
    }
    return len(line)
}

lsp_request_definition :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Definition, file_path = strings.clone(file_path, context.allocator), sent_at = time.now()})

    character := lsp_byte_col_to_character(client, file_path, row, col)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/definition","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, character,
    )
    lsp_send_raw(client, msg)
}

lsp_request_hover :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Hover, file_path = strings.clone(file_path, context.allocator), sent_at = time.now()})

    character := lsp_byte_col_to_character(client, file_path, row, col)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, character,
    )
    lsp_send_raw(client, msg)
}

lsp_request_completion :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Completion, file_path = strings.clone(file_path, context.allocator), sent_at = time.now()})

    character := lsp_byte_col_to_character(client, file_path, row, col)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/completion","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, character,
    )
    lsp_send_raw(client, msg)
}

lsp_request_range_formatting :: proc(client: ^LspClient, file_path: string, start_row, end_row: int) {
    if !lsp_is_running(client) || !client.initialized do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{
        id        = id,
        kind      = .RangeFormatting,
        file_path = strings.clone(file_path, context.allocator),
        start_row = start_row,
        end_row   = end_row,
        sent_at   = time.now(),
    })

    // OLS implements textDocument/formatting; our handler extracts the start_row..end_row range
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/formatting","params":{{"textDocument":{{"uri":"%s"}},"options":{{"tabSize":4,"insertSpaces":true}}}}}}`,
        id, uri,
    )
    lsp_send_raw(client, msg)
}

lsp_json_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, 0, len(s) + 64, allocator)
    lsp_append_json_escaped(&b, s)
    return strings.to_string(b)
}

// Poll and dispatch all completed LSP messages in main thread
lsp_update :: proc(client: ^LspClient, app: ^App) {
    if !lsp_is_running(client) do return

    messages_to_process: [dynamic]json.Value
    sync.mutex_lock(&client.mutex)
    if len(client.incoming_queue) > 0 {
        messages_to_process = make([dynamic]json.Value, len(client.incoming_queue), context.temp_allocator)
        for m, i in client.incoming_queue {
            messages_to_process[i] = m
        }
        clear(&client.incoming_queue)
    }
    sync.mutex_unlock(&client.mutex)

    if len(messages_to_process) == 0 do return

    for val in messages_to_process {
        defer json.destroy_value(val, runtime.default_allocator())

        obj, is_obj := val.(json.Object)
        if !is_obj do continue

        // Check if message is a request or notification with "method"
        if method_val, has_method := obj["method"]; has_method {
            if method_str, ok := method_val.(json.String); ok {
                if id_val, has_id := obj["id"]; has_id {
                    // Server-to-client request (needs a response)
                    lsp_handle_server_request(client, id_val, method_str, obj, app)
                    continue
                }
                // Server notification
                lsp_handle_notification(client, method_str, obj, app)
                continue
            }
        }

        // Response from server to our client request
        if id_val, has_id := obj["id"]; has_id {
            req_id := -1
            #partial switch v in id_val {
            case json.Integer: req_id = int(v)
            case json.Float:   req_id = int(v)
            }

            if req_id > 0 {
                lsp_handle_response(client, req_id, obj, app)
                continue
            }
        }
    }
}

lsp_id_to_string :: proc(id_val: json.Value, allocator := context.temp_allocator) -> string {
    #partial switch v in id_val {
    case json.String:
        escaped := lsp_json_escape(v, context.temp_allocator)
        return fmt.aprintf(`"%s"`, escaped, allocator = allocator)
    case json.Integer: return fmt.aprintf(`%d`, v, allocator = allocator)
    case json.Float:   return fmt.aprintf(`%d`, int(v), allocator = allocator)
    case:              return "null"
    }
}

lsp_handle_server_request :: proc(client: ^LspClient, id_val: json.Value, method: string, obj: json.Object, app: ^App) {
    id_str := lsp_id_to_string(id_val)
    if method == "workspace/configuration" {
        item_count := 1
        if params_obj, ok := obj["params"].(json.Object); ok {
            if items_arr, ok2 := params_obj["items"].(json.Array); ok2 && len(items_arr) > 0 {
                item_count = len(items_arr)
            }
        }
        b: strings.Builder
        strings.builder_init(&b, 0, 64, context.temp_allocator)
        strings.write_string(&b, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":[`, id_str))
        for i in 0 ..< item_count {
            if i > 0 do strings.write_string(&b, ",")
            strings.write_string(&b, "null")
        }
        strings.write_string(&b, "]}")
        lsp_send_raw(client, strings.to_string(b))
        return
    }

    res_msg := fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":null}}`, id_str)
    lsp_send_raw(client, res_msg)
}

lsp_handle_notification :: proc(client: ^LspClient, method: string, obj: json.Object, app: ^App) {
    if method == "textDocument/publishDiagnostics" {
        params_obj, has_params := obj["params"].(json.Object)
        if !has_params do return

        uri_str, has_uri := params_obj["uri"].(json.String)
        if !has_uri do return

        file_path := lsp_uri_to_path(uri_str, context.temp_allocator)
        // realpath fails for files that do not exist yet (e.g. unsaved buffers);
        // fall back to lexical normalization so diagnostics still key consistently.
        norm_temp, abs_err := filepath.abs(file_path, context.temp_allocator)
        if abs_err != nil {
            norm_temp, _ = filepath.clean(file_path, context.temp_allocator)
        }

        // Validate the payload before touching existing diagnostics. A
        // malformed notification must not wipe them.
        diags_value, has_diags := params_obj["diagnostics"]
        if !has_diags do return
        diags_arr, is_array := diags_value.(json.Array)
        if !is_array do return

        // Clear existing diagnostics for this path
        existing_key := ""
        for k, v in client.diagnostics {
            if k == norm_temp {
                existing_key = k
                for d in v do delete(d.message)
                delete(v)
                break
            }
        }

        if len(diags_arr) == 0 {
            if existing_key != "" {
                delete_key(&client.diagnostics, existing_key)
                delete(existing_key)
            }
            return
        }

        norm_key := existing_key
        if norm_key == "" {
            norm_key = strings.clone(norm_temp, context.allocator)
        }

        new_diags := make([dynamic]LspDiagnostic, 0, len(diags_arr))
        for d_elem in diags_arr {
            d_obj, ok := d_elem.(json.Object)
            if !ok do continue

            msg_str := ""
            if m, has_m := d_obj["message"].(json.String); has_m {
                msg_str = strings.clone(m, context.allocator)
            }

            sev := LspSeverity.Error
            if s, has_s := d_obj["severity"].(json.Integer); has_s {
                sev = LspSeverity(int(s))
            } else if s, has_s := d_obj["severity"].(json.Float); has_s {
                sev = LspSeverity(int(s))
            }

            s_row, s_col, e_row, e_col := 0, 0, 0, 0
            if r_obj, has_r := d_obj["range"].(json.Object); has_r {
                if start_obj, has_st := r_obj["start"].(json.Object); has_st {
                    if l, ok := start_obj["line"].(json.Integer); ok do s_row = int(l)
                    else if l, ok := start_obj["line"].(json.Float); ok do s_row = int(l)

                    if c, ok := start_obj["character"].(json.Integer); ok do s_col = int(c)
                    else if c, ok := start_obj["character"].(json.Float); ok do s_col = int(c)
                }
                if end_obj, has_en := r_obj["end"].(json.Object); has_en {
                    if l, ok := end_obj["line"].(json.Integer); ok do e_row = int(l)
                    else if l, ok := end_obj["line"].(json.Float); ok do e_row = int(l)

                    if c, ok := end_obj["character"].(json.Integer); ok do e_col = int(c)
                    else if c, ok := end_obj["character"].(json.Float); ok do e_col = int(c)
                }
            }

            append(&new_diags, LspDiagnostic{
                start_row = s_row,
                start_col = lsp_character_to_byte_col(client, norm_temp, s_row, s_col),
                end_row   = e_row,
                end_col   = lsp_character_to_byte_col(client, norm_temp, e_row, e_col),
                severity  = sev,
                message   = msg_str,
            })
        }

        client.diagnostics[norm_key] = new_diags
    }
}

lsp_handle_response :: proc(client: ^LspClient, req_id: int, obj: json.Object, app: ^App) {
    // Find matching pending request
    req_idx := -1
    for req, i in client.pending_requests {
        if req.id == req_id {
            req_idx = i
            break
        }
    }
    if req_idx < 0 do return

    req := client.pending_requests[req_idx]
    ordered_remove(&client.pending_requests, req_idx)
    defer if req.file_path != "" do delete(req.file_path)

    err_val, has_err := obj["error"]
    if has_err && err_val != nil {
        if app != nil {
            err_msg := "LSP error"
            if err_obj, ok := err_val.(json.Object); ok {
                if m, ok2 := err_obj["message"].(json.String); ok2 do err_msg = m
            }
            app_set_message(app, fmt.tprintf("LSP Error: %s", err_msg))
        }
        // A failed initialize must not leave a client that looks alive but
        // never becomes initialized.
        if req.kind == .Initialize do lsp_set_running(client, false)
        return
    }

    res_val, has_res := obj["result"]
    if !has_res || res_val == nil {
        switch req.kind {
        case .Hover:
            if client.last_hover != "" do delete(client.last_hover)
            client.last_hover = strings.clone("(No hover documentation)", context.allocator)
        case .Definition:
            if app != nil do app_set_message(app, "LSP: No definition found")
        case .RangeFormatting:
            if app != nil do app_set_message(app, "LSP: Formatting returned no changes")
        case .Initialize:
            lsp_set_running(client, false)
        case .Completion, .None:
        }
        return
    }

    switch req.kind {
    case .Initialize:
        // The server chooses one of the advertised encodings; UTF-16 is the
        // protocol default when it does not answer.
        if result_obj, ok := res_val.(json.Object); ok {
            encoding := ""
            if caps, caps_ok := result_obj["capabilities"].(json.Object); caps_ok {
                if enc, enc_ok := caps["positionEncoding"].(json.String); enc_ok do encoding = enc
            }
            if encoding == "" {
                if enc, enc_ok := result_obj["positionEncoding"].(json.String); enc_ok do encoding = enc
            }
            client.position_encoding = .UTF8 if encoding == "utf-8" else .UTF16
        }
        client.initialized = true
        // Send initialized notification. The manager's poll opens documents
        // once per client so didOpen cannot be duplicated.
        init_notif := `{"jsonrpc":"2.0","method":"initialized","params":{}}`
        lsp_send_raw(client, init_notif)

    case .Definition:
        if prev, has_prev := client.last_definition.?; has_prev && prev.file_path != "" {
            delete(prev.file_path)
        }
        client.last_definition = nil

        // Can be a Location object or an array of Locations
        loc_obj: json.Object
        found := false

        if single_loc, ok := res_val.(json.Object); ok {
            loc_obj = single_loc
            found = true
        } else if arr_loc, ok := res_val.(json.Array); ok && len(arr_loc) > 0 {
            if first_loc, ok2 := arr_loc[0].(json.Object); ok2 {
                loc_obj = first_loc
                found = true
            }
        }

        if found {
            target_uri := ""
            if u, ok := loc_obj["uri"].(json.String); ok do target_uri = u
            else if u, ok := loc_obj["targetUri"].(json.String); ok do target_uri = u

            target_row, target_col := 0, 0
            range_obj: json.Object
            has_range := false

            if r, ok := loc_obj["range"].(json.Object); ok {
                range_obj = r
                has_range = true
            } else if r, ok := loc_obj["targetSelectionRange"].(json.Object); ok {
                range_obj = r
                has_range = true
            }

            if has_range {
                if start_obj, ok := range_obj["start"].(json.Object); ok {
                    if l, ok2 := start_obj["line"].(json.Integer); ok2 do target_row = int(l)
                    else if l, ok2 := start_obj["line"].(json.Float); ok2 do target_row = int(l)

                    if c, ok2 := start_obj["character"].(json.Integer); ok2 do target_col = int(c)
                    else if c, ok2 := start_obj["character"].(json.Float); ok2 do target_col = int(c)
                }
            }

            if target_uri != "" {
                target_path := lsp_uri_to_path(target_uri, context.temp_allocator)
                abs_target, abs_err := filepath.abs(target_path, context.allocator)
                if abs_err != nil {
                    abs_target, _ = filepath.clean(target_path, context.allocator)
                }
                client.last_definition = LspLocation{
                    file_path = abs_target,
                    row       = target_row,
                    col       = lsp_character_to_byte_col(client, abs_target, target_row, target_col),
                }
            } else {
                if app != nil do app_set_message(app, "LSP: No definition found")
            }
        } else {
            if app != nil do app_set_message(app, "LSP: No definition found")
        }

    case .Hover:
        content_str := ""
        if hover_obj, ok := res_val.(json.Object); ok {
            contents_val, has_contents := hover_obj["contents"]
            if has_contents {
                if str, ok := contents_val.(json.String); ok {
                    content_str = str
                } else if markup, ok := contents_val.(json.Object); ok {
                    if val, ok2 := markup["value"].(json.String); ok2 {
                        content_str = val
                    }
                } else if arr, ok := contents_val.(json.Array); ok {
                    b: strings.Builder
                    strings.builder_init(&b, context.temp_allocator)
                    for item in arr {
                        if s, ok2 := item.(json.String); ok2 {
                            strings.write_string(&b, s)
                            strings.write_byte(&b, '\n')
                        } else if marked, ok2 := item.(json.Object); ok2 {
                            if v, ok3 := marked["value"].(json.String); ok3 {
                                strings.write_string(&b, v)
                                strings.write_byte(&b, '\n')
                            }
                        }
                    }
                    content_str = strings.to_string(b)
                }
            }
        }

        if client.last_hover != "" do delete(client.last_hover)
        if client.last_hover_file != "" do delete(client.last_hover_file)
        client.last_hover_file = ""
        if req.file_path != "" {
            client.last_hover_file = strings.clone(req.file_path, context.allocator)
        }
        if content_str != "" {
            client.last_hover = strings.clone(content_str, context.allocator)
        } else {
            client.last_hover = strings.clone("(No hover documentation)", context.allocator)
        }

    case .Completion:
        if client.completions_file != "" do delete(client.completions_file)
        client.completions_file = ""
        if req.file_path != "" {
            client.completions_file = strings.clone(req.file_path, context.allocator)
        }

        for c in client.completions {
            delete(c.label)
            delete(c.detail)
            delete(c.documentation)
            delete(c.insert_text)
        }
        clear(&client.completions)

        items_arr: json.Array
        has_items := false

        if arr, ok := res_val.(json.Array); ok {
            items_arr = arr
            has_items = true
        } else if comp_list, ok := res_val.(json.Object); ok {
            if arr2, ok2 := comp_list["items"].(json.Array); ok2 {
                items_arr = arr2
                has_items = true
            }
        }

        if has_items {
            for item_val in items_arr {
                it_obj, ok := item_val.(json.Object)
                if !ok do continue

                lbl := ""
                if l, ok2 := it_obj["label"].(json.String); ok2 do lbl = l

                det := ""
                if d, ok2 := it_obj["detail"].(json.String); ok2 do det = d

                doc := ""
                if doc_val, ok2 := it_obj["documentation"]; ok2 {
                    if d_str, ok3 := doc_val.(json.String); ok3 {
                        doc = d_str
                    } else if d_obj, ok3 := doc_val.(json.Object); ok3 {
                        if v, ok4 := d_obj["value"].(json.String); ok4 do doc = v
                    }
                }

                ins := lbl
                if it, ok2 := it_obj["insertText"].(json.String); ok2 do ins = it

                append(&client.completions, LspCompletionItem{
                    label         = strings.clone(lbl, context.allocator),
                    detail        = strings.clone(det, context.allocator),
                    documentation = strings.clone(doc, context.allocator),
                    insert_text   = strings.clone(ins, context.allocator),
                })
            }
        }

    case .RangeFormatting:
        if client.last_edits_file != "" do delete(client.last_edits_file)
        client.last_edits_file = ""
        if req.file_path != "" {
            client.last_edits_file = strings.clone(req.file_path, context.allocator)
        }

        for e in client.last_edits do delete(e.new_text)
        clear(&client.last_edits)

        if edits_arr, ok := res_val.(json.Array); ok && len(edits_arr) > 0 {
            first_ed, is_obj := edits_arr[0].(json.Object)
            if is_obj && len(edits_arr) == 1 {
                new_t := ""
                if nt, ok3 := first_ed["newText"].(json.String); ok3 do new_t = nt

                s_row, s_col, e_row, e_col := 0, 0, 0, 0
                if r_obj, ok3 := first_ed["range"].(json.Object); ok3 {
                    if st, ok4 := r_obj["start"].(json.Object); ok4 {
                        if l, ok5 := st["line"].(json.Integer); ok5 do s_row = int(l)
                        else if l, ok5 := st["line"].(json.Float); ok5 do s_row = int(l)
                        if c, ok5 := st["character"].(json.Integer); ok5 do s_col = int(c)
                        else if c, ok5 := st["character"].(json.Float); ok5 do s_col = int(c)
                    }
                    if en, ok4 := r_obj["end"].(json.Object); ok4 {
                        if l, ok5 := en["line"].(json.Integer); ok5 do e_row = int(l)
                        else if l, ok5 := en["line"].(json.Float); ok5 do e_row = int(l)
                        if c, ok5 := en["character"].(json.Integer); ok5 do e_col = int(c)
                        else if c, ok5 := en["character"].(json.Float); ok5 do e_col = int(c)
                    }
                }

                if s_row == 0 && e_row >= req.end_row {
                    // Extract only req.start_row ..= req.end_row
                    lines := strings.split(new_t, "\n", context.temp_allocator)
                    valid_count := len(lines)
                    if valid_count > 0 && lines[valid_count - 1] == "" {
                        valid_count -= 1
                    }

                    if valid_count > 0 && req.start_row < valid_count {
                        sel_start := clamp(req.start_row, 0, valid_count - 1)
                        sel_end := clamp(req.end_row, sel_start, valid_count - 1)

                        b: strings.Builder
                        strings.builder_init(&b, context.allocator)
                        for i in sel_start ..= sel_end {
                            strings.write_string(&b, lines[i])
                            strings.write_byte(&b, '\n')
                        }

                        append(&client.last_edits, LspTextEdit{
                            start_row = sel_start,
                            start_col = 0,
                            end_row   = sel_end + 1,
                            end_col   = 0,
                            new_text  = strings.to_string(b),
                        })
                    }
                } else {
                    append(&client.last_edits, LspTextEdit{
                        start_row = s_row,
                        start_col = lsp_character_to_byte_col(client, req.file_path, s_row, s_col),
                        end_row   = e_row,
                        end_col   = lsp_character_to_byte_col(client, req.file_path, e_row, e_col),
                        new_text  = strings.clone(new_t, context.allocator),
                    })
                }
            } else {
                for edit_val in edits_arr {
                    ed_obj, ok2 := edit_val.(json.Object)
                    if !ok2 do continue

                    new_t := ""
                    if nt, ok3 := ed_obj["newText"].(json.String); ok3 do new_t = nt

                    s_row, s_col, e_row, e_col := 0, 0, 0, 0
                    if r_obj, ok3 := ed_obj["range"].(json.Object); ok3 {
                        if st, ok4 := r_obj["start"].(json.Object); ok4 {
                            if l, ok5 := st["line"].(json.Integer); ok5 do s_row = int(l)
                            else if l, ok5 := st["line"].(json.Float); ok5 do s_row = int(l)

                            if c, ok5 := st["character"].(json.Integer); ok5 do s_col = int(c)
                            else if c, ok5 := st["character"].(json.Float); ok5 do s_col = int(c)
                        }
                        if en, ok4 := r_obj["end"].(json.Object); ok4 {
                            if l, ok5 := en["line"].(json.Integer); ok5 do e_row = int(l)
                            else if l, ok5 := en["line"].(json.Float); ok5 do e_row = int(l)

                            if c, ok5 := en["character"].(json.Integer); ok5 do e_col = int(c)
                            else if c, ok5 := en["character"].(json.Float); ok5 do e_col = int(c)
                        }
                    }

                    if s_row >= req.start_row && e_row <= req.end_row {
                        append(&client.last_edits, LspTextEdit{
                            start_row = s_row,
                            start_col = lsp_character_to_byte_col(client, req.file_path, s_row, s_col),
                            end_row   = e_row,
                            end_col   = lsp_character_to_byte_col(client, req.file_path, e_row, e_col),
                            new_text  = strings.clone(new_t, context.allocator),
                        })
                    }
                }
            }
        }

        if len(client.last_edits) == 0 && app != nil {
            app_set_message(app, "LSP: Range is already formatted")
        }

    case .None:
    }
}
