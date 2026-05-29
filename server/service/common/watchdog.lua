-- watchdog: 连接管理器
-- 使用 skynet 内置 gate.lua 管理 TCP 连接
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agents = {}  -- fd -> agent

function SOCKET.open(fd, addr)
	skynet.error("[watchdog] new connection from " .. addr)
	local agent = skynet.newservice("agent/agent")
	agents[fd] = agent
	skynet.call(agent, "lua", "start", {
		gate = gate,
		client = fd,
		watchdog = skynet.self(),
	})
end

local function close_agent(fd)
	local agent = agents[fd]
	agents[fd] = nil
	if agent then
		skynet.call(gate, "lua", "kick", fd)
		skynet.send(agent, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	skynet.error("[watchdog] socket close", fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	skynet.error("[watchdog] socket error", fd, msg)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	skynet.error("[watchdog] socket warning", fd, size)
end

-- 内置 gate 在 forward 后数据直连 agent，此处不会收到 data
function SOCKET.data(fd, msg)
	-- do nothing
end

function CMD.start(conf)
	return skynet.call(gate, "lua", "open", {
		address = "0.0.0.0",
		port = conf.port,
		maxclient = conf.maxclient or 256,
		watchdog = skynet.self(),
	})
end

function CMD.close(fd)
	close_agent(fd)
end

function CMD.shutdown()
	local count = 0
	for _ in pairs(agents) do
		count = count + 1
	end
	skynet.error("[watchdog] shutting down, disconnecting " .. count .. " players")
	for fd, _ in pairs(agents) do
		close_agent(fd)
	end
	skynet.error("[watchdog] all players disconnected, skynet exiting...")
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			if f then
				f(...)
			end
		else
			local f = assert(CMD[cmd], "unknown cmd: " .. tostring(cmd))
			if session ~= 0 then
				skynet.ret(skynet.pack(f(subcmd, ...)))
			else
				f(subcmd, ...)
			end
		end
	end)

	gate = skynet.newservice("gate")
	skynet.error("[watchdog] gate service created")
end)
