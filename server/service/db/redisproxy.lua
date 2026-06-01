-- redisproxy: Redis 代理服务
-- 令牌/在线状态/限流/缓存，全部走 Redis
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local redis = require "skynet.db.redis"

local redis_db

local function init_redis()
	local ok, err = pcall(function()
		local db = redis.connect({
			host = skynet.getenv("redis_host") or "127.0.0.1",
			port = tonumber(skynet.getenv("redis_port") or 6379),
			auth = skynet.getenv("redis_password"),
		})
		local pong = db:ping()
		if pong ~= "PONG" then
			return nil, "redis ping failed"
		end
		return db
	end)

	if ok and err then
		redis_db = err
		skynet.error("[redisproxy] connected")
	else
		skynet.error("[redisproxy] init failed: " .. tostring(err))
	end
end

local CMD = {}

-- 通用调用：redisproxy.call("set", "key", "value")
function CMD.call(command, ...)
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

-- SETEX key value ttl
function CMD.setex(key, value, ttl)
	return CMD.call("setex", key, ttl or 3600, value)
end

-- GET 并转数字
function CMD.get_int(key)
	local v = CMD.call("get", key)
	if type(v) == "string" then
		return tonumber(v) or 0
	end
	return 0
end

-- 自增 ID 生成
function CMD.gen_id(key)
	return CMD.call("incr", key or "global:id")
end

-- 批量 pipeline
function CMD.pipeline(ops)
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

skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = assert(CMD[cmd], "unknown redisproxy cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	init_redis()

	skynet.register ".redisproxy"
	skynet.error("[redisproxy] service started")

	-- 30 秒心跳保活
	local function heartbeat()
		if redis_db then
			pcall(redis_db.ping, redis_db)
		end
		skynet.timeout(300, heartbeat)
	end
	skynet.timeout(300, heartbeat)
end)
