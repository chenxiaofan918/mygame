-- chat: 聊天服务
-- Redis 存聊天历史，内存维护在线玩家 agent 映射
-- 支持世界频道、系统频道、私聊
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local const = require "const"

local CMD = {}
local redisproxy = ".redisproxy"

-- 在线玩家 agent 映射: player_id -> agent_address
local player_agents = {}

-- 发言冷却: player_id -> timestamp
local last_chat_time = {}

-- 配置
local MSG_MAX_LEN = 200       -- 消息最大长度
local RATELIMIT_INTERVAL = 1  -- 发言冷却（秒）
local WORLD_HISTORY_MAX = 50  -- 世界频道历史上限

-- ======== 内部函数 ========

-- 消息长度校验
local function validate_msg(msg)
	if #msg > MSG_MAX_LEN then
		return false, const.ERROR.MSG_TOO_LONG
	end
	if #msg == 0 then
		return false, const.ERROR.MISSING_PARAMS
	end
	return true
end

-- 限流检查
local function check_ratelimit(player_id)
	local now = os.time()
	local last = last_chat_time[player_id]
	if last and now - last < RATELIMIT_INTERVAL then
		return false
	end
	last_chat_time[player_id] = now
	return true
end

-- 保存聊天历史到 Redis
local function save_history(channel, entry)
	local key = "chat:history:" .. channel
	local ok = pcall(skynet.send, redisproxy, "lua", "call", "LPUSH", key, entry)
	if ok then
		pcall(skynet.send, redisproxy, "lua", "call", "LTRIM", key, 0, WORLD_HISTORY_MAX)
	end
end

-- 从 Redis 读取聊天历史
local function load_history(channel, count)
	local key = "chat:history:" .. channel
	local ok, result = pcall(skynet.call, redisproxy, "lua", "call", "LRANGE", key, 0, (count or 20) - 1)
	if ok and type(result) == "table" then
		local messages = {}
		for _, entry in ipairs(result) do
			local ok2, decoded = pcall(require("json").decode, entry)
			if ok2 then
				table.insert(messages, decoded)
			end
		end
		return messages
	end
	return {}
end

-- 推送消息给指定玩家
local function push_to_player(player_id, channel, from_id, from_name, msg, timestamp)
	local agent = player_agents[player_id]
	if agent then
		pcall(skynet.send, agent, "lua", "push_chat", channel, from_id, from_name, msg, timestamp)
	end
end

-- 广播给世界频道所有在线玩家
local function broadcast_world(from_id, from_name, msg, timestamp)
	for pid, _ in pairs(player_agents) do
		push_to_player(pid, const.CHAT_CHANNEL.WORLD, from_id, from_name, msg, timestamp)
	end
end

-- ======== CMD ========

-- 发送消息
function CMD.send(player_id, nickname, channel, target_id, msg)
	-- 校验
	local valid, err = validate_msg(msg)
	if not valid then
		return { ok = false, err = err }
	end
	if not check_ratelimit(player_id) then
		return { ok = false, err = const.ERROR.CHAT_TOO_FAST }
	end

	local now = os.time()
	local entry = require("json").encode({
		from_id = player_id,
		from_name = nickname,
		msg = msg,
		timestamp = now,
	})

	if channel == const.CHAT_CHANNEL.WORLD then
		-- 世界频道：保存历史 + 广播
		save_history("world", entry)
		broadcast_world(player_id, nickname, msg, now)
		return { ok = true }

	elseif channel == const.CHAT_CHANNEL.SYSTEM then
		-- 系统频道（仅服务端可发，客户端发系统消息视为世界消息）
		save_history("world", entry)
		broadcast_world(player_id, nickname, msg, now)
		return { ok = true }

	elseif channel == const.CHAT_CHANNEL.PRIVATE then
		-- 私聊：只推送给目标玩家和自己
		if not target_id or target_id == 0 then
			return { ok = false, err = const.ERROR.MISSING_PARAMS }
		end
		local target_agent = player_agents[target_id]
		if not target_agent then
			return { ok = false, err = const.ERROR.PLAYER_OFFLINE }
		end
		push_to_player(target_id, channel, player_id, nickname, msg, now)
		-- 也给发送者自己推送一份（让发送者看到自己发了什么）
		push_to_player(player_id, channel, player_id, nickname, msg, now)
		return { ok = true }
	end

	return { ok = false, err = const.ERROR.INVALID_ITEM_TYPE }
end

-- 获取聊天历史
function CMD.history(channel, count)
	local key_map = {
		[const.CHAT_CHANNEL.WORLD] = "world",
		[const.CHAT_CHANNEL.SYSTEM] = "system",
	}
	local key = key_map[channel]
	if not key then
		return { messages = {} }
	end
	return { messages = load_history(key, count) }
end

-- 注册在线玩家
function CMD.register(player_id, agent_addr)
	player_agents[player_id] = agent_addr
	skynet.error(string.format("[chat] player %d registered (online: %d)", player_id, #player_agents))
	return { ok = true }
end

-- 注销在线玩家
function CMD.unregister(player_id)
	player_agents[player_id] = nil
	last_chat_time[player_id] = nil
	skynet.error(string.format("[chat] player %d unregistered (online: %d)", player_id, #player_agents))
	return { ok = true }
end

-- 获取在线人数
function CMD.online_count()
	local count = 0
	for _ in pairs(player_agents) do
		count = count + 1
	end
	return count
end

-- ======== 服务启动 ========
skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = CMD[cmd]
		if f then
			skynet.ret(skynet.pack(f(...)))
		else
			skynet.error("[chat] unknown cmd: " .. tostring(cmd))
		end
	end)

	skynet.register ".chat"
	skynet.error("[chat] service started")
end)
