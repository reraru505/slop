.PHONY: all build test test-verbose test-unit test-live clean

all: build

build:
	odin build . -out:text-editor

# Unit tests only (live LSP tests are opt-in below)
test:
	odin test .

test-verbose:
	odin test . -define:ODIN_TEST_LOG_STATE_CHANGES=true -define:ODIN_TEST_THREADS=1

test-unit: test

# Spawns real language servers (ols, zls, clangd) if installed
test-live:
	odin test . -define:ODIN_TEST_LIVE_LSP=true -define:ODIN_TEST_NAMES=main.test_live_lsp_zig,main.test_live_lsp_clangd,main.test_live_lsp_odin

clean:
	rm -f text-editor
