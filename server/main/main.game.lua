local skynet = require "skynet"
require "ylog"

skynet.start(function()
	skynet.error("[" .. skynet.getenv "name" .. "] starting...")

	-- 加载 sproto 协议（全局唯一）
	skynet.uniqueservice("protoloader")

	-- 调试控制台
	local debug_port = tonumber(skynet.getenv "debug_port")
	if debug_port then
		skynet.newservice("debug_console", debug_port)
	end

	-- Redis 代理（令牌/在线/限流/缓存）
	skynet.newservice("db/redisproxy")

	-- MySQL 代理（仅玩家操作日志）
	skynet.newservice("db/mysqlproxy")

	-- MongoDB 代理
	skynet.newservice("db/mongoproxy")

	-- 玩家数据服务
	skynet.uniqueservice("game/player")

	-- 玩家操作日志服务
	skynet.newservice("log/player_log")

	-- 登录服务
	skynet.uniqueservice("login/login")

	-- 通用游戏模块
	skynet.newservice("game/bag")
	skynet.newservice("game/chat")
	skynet.uniqueservice("game/rank")

	-- 网关（连接管理）
	local watchdog = skynet.newservice("common/watchdog")
	skynet.call(watchdog, "lua", "start", {
		port = tonumber(skynet.getenv "port"),
		maxclient = tonumber(skynet.getenv "max_client"),
	})

	skynet.error("[" .. skynet.getenv "name" .. "] started on port " .. skynet.getenv "port")
	skynet.exit()
end)
