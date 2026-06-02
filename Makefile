# 游戏项目 Makefile
SKYNET = 3rd/skynet

# Lua 路径（与 server/config/config.path 保持一致）
LUA_PATH ?= ./server/main/?.lua;./server/module/?.lua;./server/lib/lualib/?.lua;;
LUA_CPATH ?= ./server/lib/luaclib/?.so;;

.PHONY: all proto proto-cs proto-ts proto-check proto-snapshot build compat-check clean run-game run-login

all: build

# ======== 协议预编译 ========
# proto: 将 .sproto 文本编译为各语言协议代码
#   - compile_sproto.lua: .sproto → .spb 二进制
#   - sprotogen.py --all:  .sproto → Lua / C# / TypeScript 代码
#
# 生产部署只需 .spb，可移除 sprotoparser + lpeg 运行时依赖。
# 开发环境（如 Windows）若无法运行此步骤，protoloader 自动回退到运行时解析。
#
# 子目标:
#   proto-cs  仅生成 C# (Unity)
#   proto-ts  仅生成 TypeScript (Cocos Creator)
#   proto-lua 仅生成 Lua (服务端)
proto:
	LUA_PATH="$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" \
		lua tools/compile_sproto.lua
	python tools/sprotogen.py --all

proto-cs:
	python tools/sprotogen.py --lang cs

proto-ts:
	python tools/sprotogen.py --lang ts

proto-lua:
	python tools/sprotogen.py --lang lua

# CI 用：检查 .spb 是否与 .sproto 同步
proto-check:
	LUA_PATH="$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" \
		lua tools/compile_sproto.lua /tmp/proto_check
	@for f in proto/c2s.spb proto/s2c.spb; do \
		if [ -f /tmp/proto_check/$$(basename $$f) ] && [ -f $$f ]; then \
			cmp -s /tmp/proto_check/$$(basename $$f) $$f && \
				echo "  [OK] $$f is up to date" || \
				(echo "  [STALE] $$f - run 'make proto'" && exit 1); \
		fi; \
	done
	@rm -rf /tmp/proto_check

# ======== 协议兼容性检查 ========
# compat-check: 检查 .sproto 更改是否向后兼容
# 使用 proto/.proto_snapshot.json 作为基线
compat-check:
	python tools/compat_check.py

# proto-snapshot: 更新兼容性基线快照
# 在故意破坏兼容性后使用（如删减废弃字段/协议）
proto-snapshot:
	python tools/compat_check.py --update

# proto-snapshot-init: 初始化基线快照（首次使用）
proto-snapshot-init:
	python tools/compat_check.py --init

# ======== 构建 skynet ========
build: proto
	cd $(SKYNET) && $(MAKE) linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC

# ======== 启动 ========
run-game:
	$(SKYNET)/skynet server/config/config.game

run-login:
	$(SKYNET)/skynet server/config/config.login

# ======== 清理 ========
clean:
	cd $(SKYNET) && $(MAKE) clean
	rm -rf log/
	rm -f proto/*.spb
	rm -f client/unity/Assets/Scripts/Proto/Protocol.cs
	rm -f client/cocos/assets/scripts/proto/protocol.ts

# ======== 更新 skynet ========
update:
	git submodule update --init --recursive

# ======== 调试 ========
debug:
	$(SKYNET)/skynet server/config/config.game

# ======== 守护进程 ========
daemon:
	$(SKYNET)/skynet server/config/config.game daemon
