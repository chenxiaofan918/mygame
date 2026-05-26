local skynet = require "skynet"

skynet.start(function()
	skynet.error("[" .. skynet.getenv "name" .. "] starting...")

	-- 加载 sproto 协议（全局唯一）
	skynet.uniqueservice("protoloader")

	-- 调试控制台
	local debug_port = tonumber(skynet.getenv "debug_port")
	if debug_port then
		skynet.newservice("debug_console", debug_port)
	end

	-- 数据库代理
	skynet.newservice("db/dbproxy")

	-- 登录服务
	skynet.uniqueservice("login/login")

	-- 网关（连接管理）
	local watchdog = skynet.newservice("common/watchdog")
	skynet.call(watchdog, "lua", "start", {
		port = tonumber(skynet.getenv "port"),
		maxclient = tonumber(skynet.getenv "max_client"),
	})

	skynet.error("[" .. skynet.getenv "name" .. "] started on port " .. skynet.getenv "port")
	skynet.exit()
end)
