local skynet = require "skynet"
require "ylog"

skynet.start(function()
	skynet.error("[" .. skynet.getenv "name" .. "] starting...")

	local debug_port = tonumber(skynet.getenv "debug_port")
	if debug_port then
		skynet.newservice("debug_console", debug_port)
	end

	-- Redis 代理（登录需要令牌/在线/限流）
	skynet.newservice("db.redisproxy")

	-- MySQL 代理（仅玩家操作日志）
	skynet.newservice("db.mysqlproxy")
	skynet.newservice("login.login")

	skynet.error("[" .. skynet.getenv "name" .. "] started on port " .. skynet.getenv "port")
	skynet.exit()
end)
