local skynet = require "skynet"

skynet.start(function()
	skynet.error("[" .. skynet.getenv "name" .. "] starting...")

	local debug_port = tonumber(skynet.getenv "debug_port")
	if debug_port then
		skynet.newservice("debug_console", debug_port)
	end

	skynet.newservice("db.dbproxy")
	skynet.newservice("login.login")

	skynet.error("[" .. skynet.getenv "name" .. "] started on port " .. skynet.getenv "port")
	skynet.exit()
end)
