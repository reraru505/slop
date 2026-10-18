package main

import sdl "vendor:sdl3"

// ============================================================================
// Editor configuration
// ============================================================================
//
// Everything here is compile-time: edit a value, rebuild, and the change is
// baked into the binary. This is the only file you need to touch for normal
// configuration.
//
// Keybindings are KEYS ONLY. The Ctrl/Alt/Shift requirements for each action
// are fixed by the dispatch code; changing a KEY_* constant changes which key
// triggers the action, not its modifiers. For example, KEY_SAVE defaults to S
// and is always Ctrl+S; setting it to sdl.K_F5 makes the binding Ctrl+F5.
//
// Intrinsic text-editing keys are intentionally not configurable: Esc, Enter,
// Tab/Shift+Tab, Backspace, Delete, the arrow keys, the mouse wheel, auto-pair
// characters, command-prompt line editing, and the file picker.
//
// If two actions in the same context are mapped to the same key, the first
// matching branch in that handler wins.

// ============================================================================
// Appearance
// ============================================================================

// Editor name used in the window title and the :help heading.
EDITOR_NAME :: "slop"

// The font is embedded into the binary at compile time. To use a different
// font, put its .ttf/.otf file in assets/ and change this path (the path must
// be a string literal, which is an Odin #load requirement).
FONT_FILE :: #load("assets/CaskaydiaCoveNerdFont-Regular.ttf")

// Optional fallback fonts for runes the bundled font does not contain. Paths
// are loaded at runtime; missing files are ignored. Example:
//     FALLBACK_FONT_PATHS :: []string{"/usr/share/fonts/noto/NotoSansMono-Regular.ttf"}
FALLBACK_FONT_PATHS :: []string{}

// Logical pixels at 100% zoom (before display density is applied).
BASE_FONT_SIZE :: 20.0

// One of: .GruberDarker, .Naysayer, .Kanagawa, .Hemisu.
DEFAULT_THEME :: ThemeId.GruberDarker

// Line-height multiplier and initial UI scale. Both can still be changed at
// runtime with :linespace and zoom. Recommended ranges: 1.0..2.0 and 0.5..2.5.
DEFAULT_LINE_SPACING :: 1.0
DEFAULT_UI_SCALE     :: 1.0

WINDOW_TITLE  :: EDITOR_NAME
WINDOW_WIDTH  :: 1024
WINDOW_HEIGHT :: 768

// Project root used by the picker, compilation, relative paths, and LSP.
// Empty means: infer from the file or directory passed on the command line,
// otherwise use the process working directory. Change it at runtime with
// :root <dir> or :root here.
DEFAULT_ROOT_DIRECTORY :: ""

// Maximum files collected by one picker scan. The scan is background work; a
// cap keeps a huge tree from consuming unbounded memory. The UI shows when the
// listing was truncated.
FILE_PICKER_MAX_ITEMS :: 20_000

// ============================================================================
// Language servers
// ============================================================================
//
// Commands may be a bare name resolved through PATH or an absolute path. Set a
// command to "" to disable that server entirely. LSP_EXTRA_PATHS is prepended
// to the inherited PATH for server processes (colon-separated).

LSP_ODIN_COMMAND         :: "ols"
LSP_ZIG_COMMAND          :: "zls"
LSP_CLANGD_COMMAND       :: "clangd"
LSP_RUST_COMMAND         :: "rust-analyzer"
LSP_GO_COMMAND           :: "gopls"
LSP_C3_COMMAND           :: "c3lsp"

LSP_EXTRA_PATHS :: "/home/fnln/opt:/home/fnln/.cargo/bin:/home/fnln/.local/share/nvim/mason/bin:/usr/local/bin:/usr/bin:/bin"

// Override OLS's builtin folder. Empty means auto-detect the usual locations.
LSP_OLS_BUILTIN_FOLDER :: ""

// ============================================================================
// Keybindings
// ============================================================================
//
// Keycodes are SDL3 virtual keycodes: sdl.K_A .. sdl.K_Z, sdl.K_0 .. sdl.K_9,
// sdl.K_ESCAPE, sdl.K_F1, etc. See vendor:sdl3/sdl3_keycode.odin for the list.

// ---- Application / panes ---------------------------------------------------

KEY_CMD_PROMPT       :: sdl.K_COLON      // ':' command prompt
KEY_CMD_PROMPT_ALT   :: sdl.K_SEMICOLON  // Shift+; also opens the prompt

KEY_ZOOM_IN          :: sdl.K_EQUALS     // Ctrl+=
KEY_ZOOM_IN_ALT      :: sdl.K_KP_PLUS    // Ctrl+keypad +
KEY_ZOOM_OUT         :: sdl.K_MINUS      // Ctrl+-
KEY_ZOOM_OUT_ALT     :: sdl.K_KP_MINUS   // Ctrl+keypad -
KEY_ZOOM_RESET       :: sdl.K_0          // Ctrl+0
KEY_ZOOM_RESET_ALT   :: sdl.K_KP_0       // Ctrl+keypad 0

KEY_LEADER           :: sdl.K_SPACE      // leader (Normal/Visual)
KEY_LEADER_FILES     :: sdl.K_F          // leader f: file picker

KEY_WINDOW_PREFIX    :: sdl.K_W          // Ctrl+W prefix (not in Insert)
KEY_WINDOW_LEFT      :: sdl.K_H          // Ctrl+W h
KEY_WINDOW_DOWN      :: sdl.K_J          // Ctrl+W j
KEY_WINDOW_UP        :: sdl.K_K          // Ctrl+W k
KEY_WINDOW_RIGHT     :: sdl.K_L          // Ctrl+W l
KEY_WINDOW_SPLIT_H   :: sdl.K_S          // Ctrl+W s
KEY_WINDOW_SPLIT_V   :: sdl.K_V          // Ctrl+W v
KEY_WINDOW_CYCLE     :: sdl.K_W          // Ctrl+W w
KEY_WINDOW_CLOSE     :: sdl.K_Q          // Ctrl+W q
KEY_WINDOW_CLOSE_ALT :: sdl.K_C          // Ctrl+W c

// ---- Editor, all modes -----------------------------------------------------

KEY_MOVE_LINE_DOWN   :: sdl.K_J          // Alt+J
KEY_MOVE_LINE_UP     :: sdl.K_K          // Alt+K
KEY_YANK_ALT         :: sdl.K_W          // Alt+W in Visual mode
KEY_PASTE_CLIPBOARD  :: sdl.K_Y          // Ctrl+Y
KEY_SAVE             :: sdl.K_S          // Ctrl+S
KEY_UNDO_ALT         :: sdl.K_Z          // Ctrl+Z
KEY_REDO             :: sdl.K_R          // Ctrl+R

// ---- Insert mode -----------------------------------------------------------

KEY_COMPLETION_TRIGGER :: sdl.K_SPACE    // Ctrl+Space

// ---- Normal / Visual mode --------------------------------------------------

KEY_MOVE_LEFT          :: sdl.K_H        // h
KEY_MOVE_DOWN          :: sdl.K_J        // j
KEY_MOVE_UP            :: sdl.K_K        // k
KEY_MOVE_RIGHT         :: sdl.K_L        // l

KEY_LINE_START         :: sdl.K_H        // Shift+H
KEY_LINE_END           :: sdl.K_L        // Shift+L
KEY_LINE_START_ZERO    :: sdl.K_0        // 0
KEY_LINE_END_DOLLAR    :: sdl.K_4        // Shift+4 ($)

KEY_GOTO               :: sdl.K_G        // g (prefix for gg / gd)
KEY_GOTO_DEFINITION    :: sdl.K_D        // gd: go to definition
KEY_FILE_END           :: sdl.K_G        // Shift+G

KEY_WORD_FORWARD       :: sdl.K_L        // Ctrl+L
KEY_WORD_BACKWARD      :: sdl.K_H        // Ctrl+H
KEY_SCOPE_DOWN         :: sdl.K_J        // Ctrl+J
KEY_SCOPE_UP           :: sdl.K_K        // Ctrl+K
KEY_VISUAL_TOGGLE      :: sdl.K_X        // Ctrl+X

KEY_FORMAT_LINE        :: sdl.K_EQUALS   // ==
KEY_FORMAT_SELECTION   :: sdl.K_EQUALS   // = in Visual mode
KEY_HOVER              :: sdl.K_K        // Shift+K
KEY_SELECT_LINE        :: sdl.K_X        // X

KEY_DELETE_CHAR        :: sdl.K_D        // d in Normal mode
KEY_DELETE_SELECTION   :: sdl.K_D        // D in Visual mode
KEY_CHANGE_SELECTION   :: sdl.K_C        // C in Visual mode
KEY_YANK_SELECTION     :: sdl.K_Y        // Y in Visual mode
KEY_PASTE_NORMAL       :: sdl.K_P        // p in Normal/Visual mode

KEY_OPEN_BELOW         :: sdl.K_O        // o
KEY_OPEN_ABOVE         :: sdl.K_O        // Shift+O
KEY_INSERT_BEFORE      :: sdl.K_I        // i
KEY_INSERT_LINE_START  :: sdl.K_I        // Shift+I
KEY_APPEND             :: sdl.K_A        // a
KEY_APPEND_LINE_END    :: sdl.K_A        // Shift+A
KEY_UNDO               :: sdl.K_U        // u

KEY_OPEN_PARENT_DIR    :: sdl.K_MINUS    // - (open parent in Dired)
KEY_DIRED_EDIT_CANCEL  :: sdl.K_Q        // q in Normal while a dired edit is active

// ---- Dired -----------------------------------------------------------------

KEY_DIRED_EDIT          :: sdl.K_I       // i
KEY_DIRED_SORT          :: sdl.K_S       // s
KEY_DIRED_SORT_REVERSE  :: sdl.K_S       // Shift+S
KEY_DIRED_PAGE_DOWN     :: sdl.K_J       // Ctrl+J (five entries)
KEY_DIRED_PAGE_UP       :: sdl.K_K       // Ctrl+K (five entries)
KEY_DIRED_DOWN          :: sdl.K_J       // j
KEY_DIRED_UP            :: sdl.K_K       // k
KEY_DIRED_PARENT        :: sdl.K_H       // h
KEY_DIRED_PARENT_ALT    :: sdl.K_MINUS   // -
KEY_DIRED_OPEN          :: sdl.K_L       // L (lowercase l on the keyboard)
KEY_DIRED_QUIT          :: sdl.K_Q       // q

// ---- Compilation buffer ----------------------------------------------------

KEY_COMPILE_DOWN          :: sdl.K_J     // j
KEY_COMPILE_UP            :: sdl.K_K     // k
KEY_COMPILE_NEXT_ERROR    :: sdl.K_N     // n
KEY_COMPILE_PREV_ERROR    :: sdl.K_P     // p
KEY_COMPILE_JUMP          :: sdl.K_L     // L (lowercase l on the keyboard)
KEY_COMPILE_RECOMPILE     :: sdl.K_R     // r
KEY_COMPILE_RECOMPILE_ALT :: sdl.K_G     // g
KEY_COMPILE_YANK          :: sdl.K_Y     // y: copy current line
KEY_COMPILE_YANK_ALL      :: sdl.K_Y     // Shift+Y: copy whole buffer
KEY_COMPILE_QUIT          :: sdl.K_Q     // q
