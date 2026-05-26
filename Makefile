# 游戏项目 Makefile
SKYNET = 3rd/skynet

.PHONY: all build clean run-game run-login

all: build

# 构建 skynet
build:
	cd $(SKYNET) && $(MAKE) linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC

# 启动游戏服
run-game:
	$(SKYNET)/skynet server/config/config.game

# 启动登录服
run-login:
	$(SKYNET)/skynet server/config/config.login

# 清理
clean:
	cd $(SKYNET) && $(MAKE) clean
	rm -rf log/

# 更新 skynet
update:
	git submodule update --init --recursive

# 调试模式（带控制台）
debug:
	$(SKYNET)/skynet server/config/config.game

# 守护进程模式
daemon:
	$(SKYNET)/skynet server/config/config.game daemon
