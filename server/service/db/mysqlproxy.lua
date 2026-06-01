-- mysqlproxy: MySQL 代理服务
-- 仅用于玩家操作日志的异步批量写入，不存游戏业务数据
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local mysql = require "skynet.db.mysql"

local mysql_db

local function init_mysql()
	local ok, err = pcall(function()
		local db = mysql.connect({
			host = skynet.getenv("db_host") or "127.0.0.1",
			port = tonumber(skynet.getenv("db_port") or 3306),
			database = skynet.getenv("db_name") or "game",
			user = skynet.getenv("db_user") or "root",
			password = skynet.getenv("db_password") or "",
			charset = "utf8mb4",
			max_packet_size = 1024 * 1024,
		})
		local ping_ok = db:ping()
		if not ping_ok then
			return nil, "mysql ping failed"
		end
		return db
	end)

	if ok and err then
		mysql_db = err
		skynet.error("[mysqlproxy] connected: " .. tostring(mysql_db:server_ver()))
	else
		skynet.error("[mysqlproxy] init failed: " .. tostring(err))
	end
end

local CMD = {}

function CMD.query(sql)
	if not mysql_db then
		return { badresult = true, err = "mysql not connected" }
	end
	local ok, result = pcall(mysql_db.query, mysql_db, sql)
	if not ok then
		skynet.error("[mysqlproxy] query error:", tostring(result))
		init_mysql()
		return { badresult = true, err = tostring(result) }
	end
	if type(result) == "table" and result.badresult then
		skynet.error("[mysqlproxy] badresult:", result.err, "errno:", result.errno)
	end
	return result
end

function CMD.execute(sql)
	return CMD.query(sql)
end

function CMD.ping()
	if not mysql_db then
		return false
	end
	local ok, result = pcall(mysql_db.ping, mysql_db)
	return ok and result or false
end

skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = assert(CMD[cmd], "unknown mysqlproxy cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	init_mysql()

	skynet.register ".mysqlproxy"
	skynet.error("[mysqlproxy] service started")

	-- 30 秒心跳保活
	local function heartbeat()
		if mysql_db then
			pcall(mysql_db.ping, mysql_db)
		end
		skynet.timeout(300, heartbeat)
	end
	skynet.timeout(300, heartbeat)
end)
