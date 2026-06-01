local skynet = require "skynet"
require "ylog"
local gateserver = require "snax.gateserver"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

function handler.open(source, conf)
	watchdog = conf.watchdog or source
	return conf.address, conf.port
end

function handler.message(fd, msg, sz)
	-- recv a package, forward it
	local c = connection[fd]
	local agent = c.agent
	if agent then
		-- It's safe to redirect msg directly , gateserver framework will not free msg.
		skynet.redirect(agent, c.client, "client", fd, msg, sz)
	else
		skynet.send(watchdog, "lua", "socket", "data", fd, skynet.tostring(msg, sz))
		-- skynet.tostring will copy msg to a string, so we must free msg here.
		skynet.trash(msg,sz)
	end
end

function handler.connect(fd, addr)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

local function unforward(c)
	if c.agent then
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	local c = connection[fd]
	if c then
		unforward(c)
		connection[fd] = nil
	end
end

function handler.disconnect(fd)
	local c = connection[fd]
	skynet.error("[gate] disconnect fd=" .. fd .. " c=" .. tostring(c) .. " agent=" .. tostring(c and c.agent) .. " pending=" .. tostring(c and c.pending_close))
	if c and c.agent then
		close_fd(fd)
		skynet.send(watchdog, "lua", "socket", "close", fd)
	elseif c then
		c.pending_close = true
	end
end

function handler.error(fd, msg)
	local c = connection[fd]
	skynet.error("[gate] error fd=" .. fd .. " msg=" .. tostring(msg) .. " agent=" .. tostring(c and c.agent))
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "error", fd, msg)
end

function handler.warning(fd, size)
	skynet.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	gateserver.openclient(fd)
	-- 如果有延迟关闭请求，forward 完成后立即执行
	if c.pending_close then
		skynet.error("[gate] forward detected pending_close for fd=" .. fd)
		c.pending_close = nil
		close_fd(fd)
		skynet.send(watchdog, "lua", "socket", "close", fd)
	end
end

function CMD.accept(source, fd)
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	gateserver.closeclient(fd)
end

function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
