package main

// Name used for the scratch buffer opened by :help.
HELP_FILE_PATH :: "*help*"

// Embedded at compile time, so the binary runs without the assets directory.
// Other static assets (templates, documentation, config snippets) can live in
// assets/ and be included the same way.
HELP_TEXT :: #load("assets/help.txt", string)
