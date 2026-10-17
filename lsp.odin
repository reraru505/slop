package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

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
}

LspClient :: struct {
    server_cmd       : string,
    process          : os.Process,
    stdin_file       : ^os.File,
    stdout_file      : ^os.File,
    reader_thread    : ^thread.Thread,
    running          : bool,
    initialized      : bool,
    next_id          : int,
    mutex            : sync.Mutex,
    incoming_queue   : [dynamic]string,
    pending_requests : [dynamic]PendingRequest,
    // Diagnostics map: file_path -> [dynamic]LspDiagnostic
    diagnostics      : map[string][dynamic]LspDiagnostic,
    // Latest completions
    completions      : [dynamic]LspCompletionItem,
    // Pending results to be handled by editor
    last_definition  : Maybe(LspLocation),
    last_hover       : string,
    last_edits       : [dynamic]LspTextEdit,
    last_hover_title : string,
}

lsp_path_to_uri :: proc(path: string, allocator := context.temp_allocator) -> string {
    abs_path, _ := filepath.abs(path, allocator)
    return fmt.tprintf("file://%s", abs_path)
}

lsp_uri_to_path :: proc(uri: string, allocator := context.temp_allocator) -> string {
    if strings.has_prefix(uri, "file://") {
        return strings.clone(uri[7:], allocator)
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

    for client.running {
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

            // Extract complete JSON payload
            json_bytes := accum[body_start : body_start + content_length]
            json_str := strings.clone(string(json_bytes), context.allocator)

            // Remove processed message from accumulator
            remove_range(&accum, 0, body_start + content_length)

            // Enqueue to incoming queue
            sync.mutex_lock(&client.mutex)
            append(&client.incoming_queue, json_str)
            sync.mutex_unlock(&client.mutex)
        }
    }
}

lsp_start :: proc(client: ^LspClient, server_cmd: string, root_dir: string) -> bool {
    // Ensure OLS finds its builtins folder
    builtin_path := ""
    builtin_candidates := []string{
        "/home/fnln/.local/share/nvim/mason/packages/ols/builtin",
        "/home/fnln/dev/ols/builtin",
        "/usr/lib/odin/base/builtin",
    }
    for cand in builtin_candidates {
        if os.exists(cand) {
            builtin_path = cand
            _ = os.set_env("OLS_BUILTIN_FOLDER", cand)
            break
        }
    }

    client.server_cmd = strings.clone(server_cmd, context.allocator)
    client.running = false
    client.initialized = false
    client.next_id = 1
    client.incoming_queue = make([dynamic]string, 0, 64)
    client.pending_requests = make([dynamic]PendingRequest, 0, 16)
    client.diagnostics = make(map[string][dynamic]LspDiagnostic)
    client.completions = make([dynamic]LspCompletionItem, 0, 32)
    client.last_edits = make([dynamic]LspTextEdit, 0, 8)

    in_r, in_w, err1 := os.pipe()
    if err1 != nil do return false
    out_r, out_w, err2 := os.pipe()
    if err2 != nil {
        os.close(in_r); os.close(in_w)
        return false
    }

    curr_env, _ := os.environ(context.temp_allocator)
    env_slice := make([dynamic]string, 0, len(curr_env) + 2, context.temp_allocator)
    has_builtin_env := false
    for env_entry in curr_env {
        if strings.has_prefix(env_entry, "OLS_BUILTIN_FOLDER=") {
            has_builtin_env = true
            if builtin_path != "" {
                append(&env_slice, fmt.tprintf("OLS_BUILTIN_FOLDER=%s", builtin_path))
            } else {
                append(&env_slice, env_entry)
            }
        } else {
            append(&env_slice, env_entry)
        }
    }
    if !has_builtin_env && builtin_path != "" {
        append(&env_slice, fmt.tprintf("OLS_BUILTIN_FOLDER=%s", builtin_path))
    }

    cmd := []string{server_cmd}
    desc := os.Process_Desc{
        command     = cmd,
        working_dir = root_dir,
        stdin       = in_r,
        stdout      = out_w,
        env         = env_slice[:],
    }

    p, perr := os.process_start(desc)
    if perr != nil {
        os.close(in_r); os.close(in_w)
        os.close(out_r); os.close(out_w)
        return false
    }

    // Close child's ends in parent
    os.close(in_r)
    os.close(out_w)

    client.process = p
    client.stdin_file = in_w
    client.stdout_file = out_r
    client.running = true

    // Start reader thread
    client.reader_thread = thread.create_and_start_with_data(rawptr(client), lsp_reader_thread_proc)

    // Send initialize request
    root_uri := lsp_path_to_uri(root_dir)
    init_json := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{{"processId":null,"rootUri":"%s","capabilities":{{"textDocument":{{"synchronization":{{"didSave":true}},"completion":{{"completionItem":{{"snippetSupport":false,"documentationFormat":["plaintext","markdown"]}}}},"hover":{{"contentFormat":["plaintext","markdown"]}},"definition":{{}},"formatting":{{}},"rangeFormatting":{{}}}}}}}}}}`,
        client.next_id,
        root_uri,
    )
    append(&client.pending_requests, PendingRequest{id = client.next_id, kind = .Initialize})
    client.next_id += 1
    lsp_send_raw(client, init_json)

    return true
}

lsp_stop :: proc(client: ^LspClient) {
    if !client.running do return
    client.running = false

    if client.stdin_file != nil {
        // Send shutdown request
        shutdown_msg := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"shutdown","params":null}}`, client.next_id)
        lsp_send_raw(client, shutdown_msg)
        exit_msg := `{"jsonrpc":"2.0","method":"exit","params":null}`
        lsp_send_raw(client, exit_msg)
        os.close(client.stdin_file)
        client.stdin_file = nil
    }

    if client.stdout_file != nil {
        os.close(client.stdout_file)
        client.stdout_file = nil
    }

    if client.reader_thread != nil {
        thread.join(client.reader_thread)
        thread.destroy(client.reader_thread)
        client.reader_thread = nil
    }

    _ = os.process_kill(client.process)
    _, _ = os.process_wait(client.process)

    // Free structures
    for q in client.incoming_queue do delete(q)
    delete(client.incoming_queue)
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

    for e in client.last_edits do delete(e.new_text)
    delete(client.last_edits)

    if client.last_hover != "" do delete(client.last_hover)
    if client.last_hover_title != "" do delete(client.last_hover_title)
    if client.server_cmd != "" do delete(client.server_cmd)
}

lsp_send_raw :: proc(client: ^LspClient, json_str: string) {
    if client.stdin_file == nil do return
    header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(json_str))
    _, _ = os.write(client.stdin_file, transmute([]u8)header)
    _, _ = os.write(client.stdin_file, transmute([]u8)json_str)
}

lsp_append_json_escaped :: proc(b: ^strings.Builder, s: string) {
    for ch in s {
        switch ch {
        case '\\': strings.write_string(b, "\\\\")
        case '"':  strings.write_string(b, "\\\"")
        case '\n': strings.write_string(b, "\\n")
        case '\r': strings.write_string(b, "\\r")
        case '\t': strings.write_string(b, "\\t")
        case:      strings.write_rune(b, ch)
        }
    }
}

lsp_did_open :: proc(client: ^LspClient, file_path: string, text: string) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)

    lang_id := "odin"
    ext := filepath.ext(file_path)
    if ext == ".c" || ext == ".h" do lang_id = "c"
    else if ext == ".cpp" || ext == ".hpp" do lang_id = "cpp"
    else if ext == ".rs" do lang_id = "rust"
    else if ext == ".go" do lang_id = "go"

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
    if !client.running do return
    uri := lsp_path_to_uri(file_path)

    b: strings.Builder
    strings.builder_init(&b, 0, len(text) * 2 + 256, context.temp_allocator)
    strings.write_string(&b, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"`)
    strings.write_string(&b, uri)
    strings.write_string(&b, `","version":2},"contentChanges":[{"text":"`)
    lsp_append_json_escaped(&b, text)
    strings.write_string(&b, `"}]}}`)
    lsp_send_raw(client, strings.to_string(b))
}

lsp_did_save :: proc(client: ^LspClient, file_path: string) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)
    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":"%s"}}}}}}`,
        uri,
    )
    lsp_send_raw(client, msg)
}

lsp_request_definition :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Definition, file_path = strings.clone(file_path, context.allocator)})

    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/definition","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, col,
    )
    lsp_send_raw(client, msg)
}

lsp_request_hover :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Hover, file_path = strings.clone(file_path, context.allocator)})

    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, col,
    )
    lsp_send_raw(client, msg)
}

lsp_request_completion :: proc(client: ^LspClient, file_path: string, row, col: int) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{id = id, kind = .Completion, file_path = strings.clone(file_path, context.allocator)})

    msg := fmt.tprintf(
        `{{"jsonrpc":"2.0","id":%d,"method":"textDocument/completion","params":{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}}}`,
        id, uri, row, col,
    )
    lsp_send_raw(client, msg)
}

lsp_request_range_formatting :: proc(client: ^LspClient, file_path: string, start_row, end_row: int) {
    if !client.running do return
    uri := lsp_path_to_uri(file_path)
    id := client.next_id
    client.next_id += 1

    append(&client.pending_requests, PendingRequest{
        id        = id,
        kind      = .RangeFormatting,
        file_path = strings.clone(file_path, context.allocator),
        start_row = start_row,
        end_row   = end_row,
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
    if !client.running do return

    messages_to_process: [dynamic]string
    sync.mutex_lock(&client.mutex)
    if len(client.incoming_queue) > 0 {
        messages_to_process = make([dynamic]string, len(client.incoming_queue), context.temp_allocator)
        for m, i in client.incoming_queue {
            messages_to_process[i] = m
        }
        clear(&client.incoming_queue)
    }
    sync.mutex_unlock(&client.mutex)

    if len(messages_to_process) == 0 do return

    for raw_json in messages_to_process {
        defer delete(raw_json)

        val, err := json.parse_string(raw_json, allocator = context.temp_allocator)
        if err != nil do continue

        obj, is_obj := val.(json.Object)
        if !is_obj do continue

        // Check if message is a response with "id"
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

        // Check if message is a notification with "method"
        if method_val, has_method := obj["method"]; has_method {
            if method_str, ok := method_val.(json.String); ok {
                lsp_handle_notification(client, method_str, obj, app)
            }
        }
    }
}

lsp_handle_notification :: proc(client: ^LspClient, method: string, obj: json.Object, app: ^App) {
    if method == "textDocument/publishDiagnostics" {
        params_obj, has_params := obj["params"].(json.Object)
        if !has_params do return

        uri_str, has_uri := params_obj["uri"].(json.String)
        if !has_uri do return

        file_path := lsp_uri_to_path(uri_str, context.temp_allocator)
        norm_path, _ := filepath.abs(file_path, context.allocator)

        // Clear existing diagnostics for this path
        if existing, exists := client.diagnostics[norm_path]; exists {
            for d in existing do delete(d.message)
            delete(existing)
        }

        diags_arr, has_diags := params_obj["diagnostics"].(json.Array)
        if !has_diags {
            delete_key(&client.diagnostics, norm_path)
            delete(norm_path)
            return
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
                start_col = s_col,
                end_row   = e_row,
                end_col   = e_col,
                severity  = sev,
                message   = msg_str,
            })
        }

        client.diagnostics[norm_path] = new_diags
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
        case .Completion, .Initialize, .None:
        }
        return
    }

    switch req.kind {
    case .Initialize:
        client.initialized = true
        // Send initialized notification
        init_notif := `{"jsonrpc":"2.0","method":"initialized","params":{}}`
        lsp_send_raw(client, init_notif)

    case .Definition:
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
                abs_target, _ := filepath.abs(target_path, context.allocator)
                client.last_definition = LspLocation{
                    file_path = abs_target,
                    row       = target_row,
                    col       = target_col,
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
                        }
                    }
                    content_str = strings.to_string(b)
                }
            }
        }

        if client.last_hover != "" do delete(client.last_hover)
        if content_str != "" {
            client.last_hover = strings.clone(content_str, context.allocator)
        } else {
            client.last_hover = strings.clone("(No hover documentation)", context.allocator)
        }

    case .Completion:
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
        for e in client.last_edits do delete(e.new_text)
        clear(&client.last_edits)

        if edits_arr, ok := res_val.(json.Array); ok && len(edits_arr) > 0 {
            first_ed, is_obj := edits_arr[0].(json.Object)
            if is_obj && len(edits_arr) == 1 {
                new_t := ""
                if nt, ok3 := first_ed["newText"].(json.String); ok3 do new_t = nt

                s_row, e_row := 0, 0
                if r_obj, ok3 := first_ed["range"].(json.Object); ok3 {
                    if st, ok4 := r_obj["start"].(json.Object); ok4 {
                        if l, ok5 := st["line"].(json.Integer); ok5 do s_row = int(l)
                        else if l, ok5 := st["line"].(json.Float); ok5 do s_row = int(l)
                    }
                    if en, ok4 := r_obj["end"].(json.Object); ok4 {
                        if l, ok5 := en["line"].(json.Integer); ok5 do e_row = int(l)
                        else if l, ok5 := en["line"].(json.Float); ok5 do e_row = int(l)
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
                        start_col = 0,
                        end_row   = e_row,
                        end_col   = 0,
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
                            start_col = s_col,
                            end_row   = e_row,
                            end_col   = e_col,
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
