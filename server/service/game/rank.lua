-- rank: 排行榜服务
-- Redis ZSET 存储排行数据，定时全量重算
-- 支持的排行榜类型: level, gold, diamond
local skynet = require "skynet"
require "ylog"
require "skynet.manager"

local CMD = {}
local mongoproxy = ".mongoproxy"
local redisproxy = ".redisproxy"

-- 配置
local RECALCULATE_INTERVAL = 300  -- 全量重算间隔（秒）
local CACHE_TTL = 60              -- Top N 缓存 TTL（秒）
local DEFAULT_TOP_N = 50          -- 默认 Top N 数量
local BOARD_TYPES = { "level", "gold", "diamond" }

-- 排行榜对应 MongoDB player 集合的字段名
local FIELD_MAP = {
	level   = "level",
	gold    = "gold",
	diamond = "diamond",
}

-- ======== 内部函数 ========

-- 获取 Redis key
local function zset_key(board_type)
	return "rank:" .. board_type
end

local function cache_key(board_type, top_n)
	return "rank:" .. board_type .. ":top" .. top_n
end

-- 从 Redis 读取缓存的 Top N
local function get_cached_top(board_type, top_n)
	local key = cache_key(board_type, top_n)
	local ok, result = pcall(skynet.call, redisproxy, "lua", "call", "GET", key)
	if ok and result then
		ok, result = pcall(require("json").decode, result)
		if ok then
			return result
		end
	end
	return nil
end

-- 缓存 Top N 到 Redis
local function set_cached_top(board_type, top_n, data)
	local key = cache_key(board_type, top_n)
	local ok = pcall(skynet.call, redisproxy, "lua", "setex", key, require("json").encode(data), CACHE_TTL)
	return ok
end

-- 从 MongoDB 获取全量排行数据
local function fetch_all_from_mongo(board_type)
	local field = FIELD_MAP[board_type]
	if not field then return nil end

	-- 只查询有该字段的玩家，按字段降序排列，取前 DEFAULT_TOP_N 个
	local projection = { player_id = 1, nickname = 1, [field] = 1 }
	local sort = { [field] = -1 }
	local ok, result = pcall(skynet.call, mongoproxy, "lua", "mongo.find", "player", {}, projection, DEFAULT_TOP_N, sort)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

-- 全量重建排行榜
local function recalculate_board(board_type)
	local field = FIELD_MAP[board_type]
	if not field then
		skynet.error("[rank] invalid board type: " .. tostring(board_type))
		return
	end

	local players = fetch_all_from_mongo(board_type)
	if not players or #players == 0 then
		skynet.error("[rank] no data for " .. board_type)
		return
	end

	-- 构建 ZSET 数据
	local members = {}
	local now = os.time()
	for _, p in ipairs(players) do
		local score = tonumber(p[field]) or 0
		table.insert(members, score)
		table.insert(members, p.player_id)
	end

	-- 批量写入 Redis ZSET
	local key = zset_key(board_type)
	pcall(skynet.call, redisproxy, "lua", "call", "DEL", key)
	if #members > 0 then
		pcall(skynet.call, redisproxy, "lua", "call", "ZADD", key, table.unpack(members))
	end

	-- 写入最后更新时间
	pcall(skynet.call, redisproxy, "lua", "call", "SET", key .. ":last_update", now)

	-- 构建 Top N 缓存
	local top_entries = {}
	for i, p in ipairs(players) do
		local score = tonumber(p[field]) or 0
		table.insert(top_entries, {
			rank = i,
			player_id = p.player_id,
			nickname = p.nickname or tostring(p.player_id),
			score = score,
		})
	end
	set_cached_top(board_type, DEFAULT_TOP_N, top_entries)

	skynet.error(string.format("[rank] %s recalculated: %d players", board_type, #players))
end

-- 全量重算定时器
local function start_recalc_timer()
	skynet.timeout(RECALCULATE_INTERVAL * 100, function()
		for _, bt in ipairs(BOARD_TYPES) do
			recalculate_board(bt)
		end
		start_recalc_timer()
	end)
end

-- ======== CMD ========

-- 获取排行榜
function CMD.get_board(board_type, top_n)
	top_n = top_n or 10
	if top_n > DEFAULT_TOP_N then
		top_n = DEFAULT_TOP_N
	end

	-- 尝试从缓存读取
	local cached = get_cached_top(board_type, top_n)
	if cached then
		local update_key = zset_key(board_type) .. ":last_update"
		local _, update_time = pcall(skynet.call, redisproxy, "lua", "get_int", update_key)
		return { entries = cached, update_time = update_time }
	end

	-- 缓存未命中，从 ZSET 读取
	local key = zset_key(board_type)
	local ok, result = pcall(skynet.call, redisproxy, "lua", "call", "ZREVRANGE", key, 0, top_n - 1, "WITHSCORES")
	if not ok or type(result) ~= "table" then
		return { entries = {}, update_time = 0 }
	end

	local entries = {}
	for i = 1, #result, 2 do
		local player_id = tonumber(result[i])
		local score = tonumber(result[i + 1]) or 0
		-- 获取昵称
		local brief = {}
		pcall(function()
			brief = skynet.call(".player", "lua", "get_brief", player_id)
		end)
		table.insert(entries, {
			rank = (#entries) + 1,
			player_id = player_id,
			nickname = (brief and brief.nickname) or tostring(player_id),
			score = score,
		})
	end

	-- 回填缓存
	if #entries > 0 then
		set_cached_top(board_type, top_n, entries)
	end

	local update_key = zset_key(board_type) .. ":last_update"
	local _, update_time = pcall(skynet.call, redisproxy, "lua", "get_int", update_key)
	return { entries = entries, update_time = update_time }
end

-- 获取玩家排名
function CMD.get_rank(player_id, board_type)
	local key = zset_key(board_type)
	local rank, score, total

	-- ZREVRANK 获取排名
	local ok1, r = pcall(skynet.call, redisproxy, "lua", "call", "ZREVRANK", key, player_id)
	if ok1 then
		rank = r
	end

	-- ZSCORE 获取分数
	local ok2, s = pcall(skynet.call, redisproxy, "lua", "call", "ZSCORE", key, player_id)
	if ok2 then
		score = tonumber(s) or 0
	end

	-- ZCARD 获取总数
	local ok3, c = pcall(skynet.call, redisproxy, "lua", "call", "ZCARD", key)
	if ok3 then
		total = c
	end

	return {
		rank = (rank and rank >= 0) and (rank + 1) or 0,
		score = score or 0,
		total = total or 0,
	}
end

-- 更新单个玩家分数（增量更新）
function CMD.update_score(player_id, board_type, score)
	local key = zset_key(board_type)
	pcall(skynet.call, redisproxy, "lua", "call", "ZADD", key, score, player_id)
	-- 使 Top N 缓存失效（下次读取重新生成）
	local cache_key_str = cache_key(board_type, DEFAULT_TOP_N)
	pcall(skynet.call, redisproxy, "lua", "call", "DEL", cache_key_str)
	return { ok = true }
end

-- 全量重算指定排行榜
function CMD.recalculate(board_type)
	recalculate_board(board_type)
	return { ok = true }
end

-- 全量重算所有排行榜
function CMD.recalculate_all()
	for _, bt in ipairs(BOARD_TYPES) do
		recalculate_board(bt)
	end
	return { ok = true }
end

-- ======== 服务启动 ========
skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = CMD[cmd]
		if f then
			skynet.ret(skynet.pack(f(...)))
		else
			skynet.error("[rank] unknown cmd: " .. tostring(cmd))
		end
	end)

	skynet.register ".rank"
	skynet.error("[rank] service started")

	-- 首次启动延迟 5 秒后执行全量重算（等所有服务就绪）
	skynet.timeout(50, function()
		for _, bt in ipairs(BOARD_TYPES) do
			recalculate_board(bt)
		end
		-- 启动定时重算
		start_recalc_timer()
	end)
end)
