package main

import "base:runtime"
import "core:sync"
import "core:thread"

// Odin's os.process_start is documented as not thread-safe because it changes
// descriptor inheritance globally. Compilation workers and LSP startup can run
// at the same time, so every pipe/spawn/close sequence goes through this lock.
process_spawn_mutex: sync.Mutex

// Background workers may outlive the allocator context that created them (for
// example a canceled Dired scan reaped by a later test). Give the thread struct
// and its runtime context the process-wide default allocator so joining and
// destroying it later is always safe.
background_thread :: proc(data: rawptr, fn: proc(data: rawptr)) -> ^thread.Thread {
    saved := context
    context.allocator = runtime.default_allocator()
    t := thread.create_and_start_with_data(data, fn)
    context = saved
    return t
}
