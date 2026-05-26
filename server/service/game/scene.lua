-- scene: 场景服务（每个场景一个实例）
local skynet = require "skynet"

local CMD = {}
local players = {}  -- player_id -> true

function CMD.enter(player_id)
	players[player_id] = true
	skynet.error("player " .. player_id .. " enter scene " .. skynet.self())
	-- TODO: 广播场景通知
	return { ok = true }
end

function CMD.leave(player_id)
	players[player_id] = nil
	skynet.error("player " .. player_id .. " leave scene")
	return { ok = true }
end

function CMD.players()
	local list = {}
	for pid, _ in pairs(players) do
		table.insert(list, pid)
	end
	return list
end

function CMD.broadcast(msg)
	for pid, _ in pairs(players) do
		-- TODO: 发送消息给场景内玩家
	end
	return { ok = true }
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f = assert(CMD[cmd], "unknown scene cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	skynet.error("scene service started: " .. skynet.self())
end)
