LUA ?= lua5.4
LUAJIT ?= luajit
LUA51 ?= lua5.1

.PHONY: all test test-lua test-jit test-lua51 lint check

all: check

test: test-lua test-jit test-lua51

test-lua:
	TZ=UTC $(LUA) spec/run.lua
	TZ=Europe/Vienna $(LUA) spec/run.lua

test-jit:
	@if command -v $(LUAJIT) >/dev/null 2>&1; then \
		TZ=UTC $(LUAJIT) spec/run.lua && TZ=Europe/Vienna $(LUAJIT) spec/run.lua; \
	else echo "skip: $(LUAJIT) not installed"; fi

test-lua51:
	@if command -v $(LUA51) >/dev/null 2>&1; then \
		TZ=UTC $(LUA51) spec/run.lua && TZ=Europe/Vienna $(LUA51) spec/run.lua; \
	else echo "skip: $(LUA51) not installed"; fi

lint:
	luacheck .

check: lint test
