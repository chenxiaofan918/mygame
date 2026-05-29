-- dbproxy: 数据库代理服务
-- 屏蔽底层 MySQL/Redis 连接细节，提供简洁的异步访问接口
-- 其他 service 通过 skynet.call/send 调用
local skynet = require "skynet"
require "skynet.manager"
local mysql = require "skynet.db.mysql"
local redis = require "skynet.db.redis"

local mysql_db
local redis_db

-- ======== MySQL 初始化 ========
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
		-- 验证连接
		local ping_ok = db:ping()
		if not ping_ok then
			return nil, "mysql ping failed"
		end
		return db
	end)

	if ok and err then
		mysql_db = err
		skynet.error("[dbproxy] MySQL connected: " .. tostring(mysql_db:server_ver()))
	else
		skynet.error("[dbproxy] MySQL init failed: " .. tostring(err))
	end
end

-- ======== Redis 初始化 ========
local function init_redis()
	local ok, err = pcall(function()
		local db = redis.connect({
			host = skynet.getenv("redis_host") or "127.0.0.1",
			port = tonumber(skynet.getenv("redis_port") or 6379),
			auth = skynet.getenv("redis_password"),
		})
		-- 验证连接
		local pong = db:ping()
		if pong ~= "PONG" then
			return nil, "redis ping failed"
		end
		return db
	end)

	if ok and err then
		redis_db = err
		skynet.error("[dbproxy] Redis connected")
	else
		skynet.error("[dbproxy] Redis init failed: " .. tostring(err))
	end
end

-- ======== MySQL 命令 ========
local mysql_cmds = {}

function mysql_cmds.query(sql)
	if not mysql_db then
		return { badresult = true, err = "mysql not connected" }
	end
	local ok, result = pcall(mysql_db.query, mysql_db, sql)
	if not ok then
		skynet.error("[dbproxy] mysql query error:", tostring(result))
		init_mysql()
		return { badresult = true, err = tostring(result) }
	end
	if type(result) == "table" and result.badresult then
		skynet.error("[dbproxy] mysql badresult:", result.err, "errno:", result.errno)
	end
	return result
end

function mysql_cmds.execute(sql)
	return mysql_cmds.query(sql)
end

function mysql_cmds.quote(str)
	if not mysql_db then
		return "'" .. tostring(str):gsub("'", "\\'") .. "'"
	end
	return mysql_db.quote_sql_str(str)
end

function mysql_cmds.ping()
	if not mysql_db then
		return false
	end
	local ok, result = pcall(mysql_db.ping, mysql_db)
	return ok and result or false
end

-- 事务
function mysql_cmds.begin()
	if not mysql_db then
		return { badresult = true, err = "mysql not connected" }
	end
	return mysql_cmds.query("START TRANSACTION")
end

function mysql_cmds.commit()
	if not mysql_db then
		return { badresult = true, err = "mysql not connected" }
	end
	return mysql_cmds.query("COMMIT")
end

function mysql_cmds.rollback()
	if not mysql_db then
		return { badresult = true, err = "mysql not connected" }
	end
	return mysql_cmds.query("ROLLBACK")
end

-- ======== Redis 命令 ========
local redis_cmds = {}

-- Redis 通用调用：dbproxy.redis_call("set", "key", "value")
function redis_cmds.call(command, ...)
	if not redis_db then
		return { badresult = true, err = "redis not connected" }
	end
	local fn = redis_db[string.lower(command)]
	if not fn then
		return { badresult = true, err = "unknown redis command: " .. tostring(command) }
	end
	local ok, result = pcall(fn, redis_db, ...)
	if not ok then
		init_redis()
		return { badresult = true, err = tostring(result) }
	end
	return result
end

-- 带过期时间的 SET
function redis_cmds.setex(key, value, ttl)
	return redis_cmds.call("setex", key, ttl or 3600, value)
end

-- 获取并转成数字
function redis_cmds.get_int(key)
	local v = redis_cmds.call("get", key)
	if type(v) == "string" then
		return tonumber(v) or 0
	end
	return 0
end

-- 自增 ID 生成
function redis_cmds.gen_id(key)
	return redis_cmds.call("incr", key or "global:id")
end

-- 批量 pipeline 执行
function redis_cmds.pipeline(ops)
	if not redis_db then
		return { badresult = true, err = "redis not connected" }
	end
	local resp = {}
	local ok, result = pcall(redis_db.pipeline, redis_db, ops, resp)
	if not ok then
		return { badresult = true, err = tostring(result) }
	end
	return resp
end

-- ======== 心跳保活 ========
local function heartbeat()
	if mysql_db then
		pcall(mysql_db.ping, mysql_db)
	end
	if redis_db then
		pcall(redis_db.ping, redis_db)
	end
	skynet.timeout(300, heartbeat)
end

-- ======== 服务分发 ========
skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, ...)
		-- 按前缀路由: "mysql.xxx" 或 "redis.xxx"
		local prefix, subcmd = cmd:match("^([^.]+)%.(.+)$")
		if prefix == "mysql" then
			local f = mysql_cmds[subcmd]
			if f then
				skynet.ret(skynet.pack(f(...)))
			else
				skynet.error("[dbproxy] unknown mysql cmd: " .. tostring(subcmd))
			end
		elseif prefix == "redis" then
			local f = redis_cmds[subcmd]
			if f then
				skynet.ret(skynet.pack(f(...)))
			else
				skynet.error("[dbproxy] unknown redis cmd: " .. tostring(subcmd))
			end
		else
			skynet.error("[dbproxy] unknown cmd: " .. tostring(cmd))
		end
	end)

	-- 初始化连接
	init_mysql()
	init_redis()

	skynet.register ".dbproxy"
	skynet.error("[dbproxy] service started")

	-- 30 秒心跳保活
	skynet.timeout(300, heartbeat)
end)
