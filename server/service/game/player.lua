-- player: 玩家数据服务
-- MongoDB 持久化 + Redis 缓存
-- 缓存策略: cache-aside, 写入时失效
-- 缓存热点字段: nickname, level, gold, diamond, vip_level
local skynet = require "skynet"
require "ylog"
require "skynet.manager"

local DB = ".redisproxy"
local MONGO = ".mongoproxy"

-- 缓存 TTL（秒）
local CACHE_TTL = 3600

-- 热点字段列表（缓存的字段）
local HOT_FIELDS = { "nickname", "level", "exp", "gold", "diamond", "vip_level" }

-- Redis HGETALL 返回平铺数组 {f1,v1,f2,v2,...} → 转为 Lua 表
local function hgetall_to_table(raw)
	if type(raw) ~= "table" then
		return {}
	end
	local t = {}
	for i = 1, #raw, 2 do
		local k = raw[i]
		local v = raw[i + 1]
		if k then
			t[k] = v
		end
	end
	return t
end

-- 写入缓存
local function cache_set(player_id, data)
	local keys = {}
	for _, field in ipairs(HOT_FIELDS) do
		local v = data[field]
		if v ~= nil then
			table.insert(keys, field)
			table.insert(keys, tostring(v))
		end
	end
	if #keys == 0 then
		return
	end
	-- HSET player:{id} field1 val1 field2 val2 ...
	skynet.call(DB, "lua", "call", "HSET", "player:" .. player_id, table.unpack(keys))
	skynet.call(DB, "lua", "call", "EXPIRE", "player:" .. player_id, CACHE_TTL)
end

-- 清除缓存
local function cache_del(player_id)
	skynet.call(DB, "lua", "call", "DEL", "player:" .. player_id)
end

local CMD = {}

-- 获取完整玩家数据（读 MongoDB，不缓存全量）
-- player.get(1) → { player_id, nickname, level, ... } | nil
function CMD.get(player_id)
	if not player_id then
		return nil
	end
	local player = skynet.call(MONGO, "lua", "mongo.find_one", "player", { player_id = player_id })
	if player and player.badresult then
		return nil
	end
	return player
end

-- 获取热点数据（Redis 缓存 → MongoDB 回源）
-- player.get_brief(1) → { nickname, level, gold, diamond, vip_level }
function CMD.get_brief(player_id)
	if not player_id then
		return nil
	end

	-- 1. 读缓存
	local cached = skynet.call(DB, "lua", "call", "HGETALL", "player:" .. player_id)
	if type(cached) == "table" and #cached > 0 then
		local data = hgetall_to_table(cached)
		-- 数值类型回转为 number
		if data.level then data.level = tonumber(data.level) end
		if data.exp then data.exp = tonumber(data.exp) end
		if data.gold then data.gold = tonumber(data.gold) end
		if data.diamond then data.diamond = tonumber(data.diamond) end
		if data.vip_level then data.vip_level = tonumber(data.vip_level) end
		data.player_id = player_id
		return data
	end

	-- 2. 缓存未命中，读 MongoDB
	local player = skynet.call(MONGO, "lua", "mongo.find_one", "player", { player_id = player_id })
	if not player or player.badresult then
		return nil
	end

	-- 3. 回写缓存
	cache_set(player_id, player)

	-- 4. 仅返回热点字段
	local brief = { player_id = player_id }
	for _, field in ipairs(HOT_FIELDS) do
		brief[field] = player[field]
	end
	return brief
end

-- 更新玩家字段（MongoDB + 清除缓存）
-- player.update(1, { level = 10, exp = 1000 })
function CMD.update(player_id, fields)
	if not player_id or not fields or not next(fields) then
		return { badresult = true, err = "invalid params" }
	end

	-- 同时更新 updated_at
	fields.updated_at = os.time()

	local result = skynet.call(MONGO, "lua", "mongo.update_one", "player",
		{ player_id = player_id }, { ["$set"] = fields })

	if result and result.badresult then
		return result
	end

	-- 清除缓存
	cache_del(player_id)

	return { ok = true }
end

-- 原子增减（MongoDB $inc + 清除缓存）
-- player.incr(1, "gold", 100)    → 加金币
-- player.incr(1, "gold", -50)   → 减金币
-- player.incr(1, "exp", 500)    → 加经验
function CMD.incr(player_id, field, amount)
	if not player_id or not field then
		return { badresult = true, err = "invalid params" }
	end

	amount = tonumber(amount) or 1

	local result = skynet.call(MONGO, "lua", "mongo.update_one", "player",
		{ player_id = player_id },
		{ ["$inc"] = { [field] = amount }, ["$set"] = { updated_at = os.time() } })

	if result and result.badresult then
		return result
	end

	-- 清除缓存
	cache_del(player_id)

	return { ok = true }
end

-- 写入缓存（登录成功后调用）
-- player.cache(1, { nickname = "test", level = 1, ... })
function CMD.cache(player_id, data)
	if not player_id or not data then
		return
	end
	cache_set(player_id, data)
	return { ok = true }
end

skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = assert(CMD[cmd], "unknown player cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	skynet.register ".player"
	skynet.error("[player] service started")
end)
