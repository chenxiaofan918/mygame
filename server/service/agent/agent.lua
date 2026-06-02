-- agent: 玩家代理服务，sproto 协议
-- 状态机: unauth → auth → disconnected
local skynet = require "skynet"
require "ylog"
local socket = require "skynet.socket"
local sprotoloader = require "sprotoloader"
local const = require "const"
local proto = require "proto_stub"

-- 注册模块协议处理器
require("handlers.init")

local client_fd
local ctx = { player_id = nil }
local state = "unauth"  -- unauth | auth
local watchdog
local timed_out = false

-- sproto host
local host = sprotoloader.load(1):host "package"
local core = require "sproto.core"

-- 预取 error 响应类型（异步推送用，无 request session）
local s2c = sprotoloader.load(2)
local error_resp_type = s2c:queryproto("error").response

-- ======== 封包发送 ========
local function raw_send_error(code, msg)
	local header = core.encode(host.__package, { type = 1, session = 0 })
	local content = core.encode(error_resp_type, { code = code, msg = msg })
	local data = core.pack(header .. content)
	local package = string.pack(">s2", data)
	socket.write(client_fd, package)
end

-- 服务器推送辅助：向客户端推送 s2c 消息
local function s2c_push(proto_name, fields)
	local resp_type = s2c:queryproto(proto_name).response
	local content = core.encode(resp_type, fields)
	local header = core.encode(host.__package, { type = 0, session = 0 })
	local data = core.pack(header .. content)
	local package = string.pack(">s2", data)
	socket.write(client_fd, package)
end

-- ======== 未认证超时 ========
local function start_unauth_timeout()
	skynet.timeout(60000, function()
		if state == "unauth" then
			timed_out = true
			raw_send_error(const.ERROR.UNAUTHORIZED, "login timeout")
			skynet.call(watchdog, "lua", "close", client_fd)
		end
	end)
end

-- ======== 未认证状态 ========
local unauth_handlers = {}

function unauth_handlers.login(args, response, err_response)
	local account = args.account
	local password = args.password
	if not account or not password then
		return err_response(const.ERROR.MISSING_PARAMS, "missing account or password")
	end

	local ok, result = pcall(skynet.call, ".login", "lua", "login", account, password)
	if not ok then
		return err_response(const.ERROR.SERVICE_UNAVAILABLE, "login service unavailable")
	end
	if not result.ok then
		return err_response(const.ERROR.LOGIN_FAILED, result.err or "login failed")
	end

	ctx.player_id = result.player_id
	state = "auth"

	-- 注册到聊天服务
	pcall(skynet.send, ".chat", "lua", "register", ctx.player_id, skynet.self())

	skynet.error("[agent] player auth ok: " .. ctx.player_id)

	if response then
		response({
			ok = true,
			player_id = ctx.player_id,
			token = result.token,
			nickname = result.nickname,
			level = result.level,
		})
	end
end

function unauth_handlers.register(args, response, err_response)
	local account = args.account
	local password = args.password
	if not account or not password then
		return err_response(const.ERROR.MISSING_PARAMS, "missing account or password")
	end

	local ok, result = pcall(skynet.call, ".login", "lua", "register", account, password)
	if not ok then
		return err_response(const.ERROR.SERVICE_UNAVAILABLE, "login service unavailable")
	end
	if not result.ok then
		return err_response(const.ERROR.REGISTER_FAILED, result.err or "register failed")
	end

	skynet.error("[agent] new player: " .. result.player_id)
	if response then
		response({ ok = true, player_id = result.player_id })
	end
end

-- 注册 login/register 到协议分发系统
proto.register("login", function(_, args, response, err_response)
	return unauth_handlers.login(args, response, err_response)
end)
proto.register("register", function(_, args, response, err_response)
	return unauth_handlers.register(args, response, err_response)
end)

-- ======== 已认证状态 ========
local auth_handlers = {}

function auth_handlers.ping()
	-- ping 无需响应
end

-- 预认证白名单：未登录状态下允许的协议
local unauth_whitelist = {
	login = true,
	register = true,
}

-- ======== 消息分发 ========
local function request_handler(name, args, response, err_response)
	-- 未认证状态下只允许 login/register
	if state == "unauth" and not unauth_whitelist[name] then
		return err_response(const.ERROR.UNAUTHORIZED, "please login first")
	end

	-- 优先查模块注册的 handler
	if proto.has_handler(name) then
		local ok, err = pcall(proto.dispatch, name, ctx, args, response, err_response)
		if not ok then
			skynet.error("[agent] handler error:", err)
		end
		return
	end

	-- 查本地 handler
	local f = auth_handlers[name]
	if f then
		local ok, err = pcall(f, args, response, err_response)
		if not ok then
			skynet.error("[agent] handler error:", err)
		end
		return
	end

	err_response(const.ERROR.UNKNOWN_CMD, "unknown command: " .. tostring(name))
end

-- ======== CMD ========
local CMD = {}

function CMD.start(conf)
	client_fd = conf.client
	watchdog = conf.watchdog
	-- 向内置 gate 注册 forward，客户端数据直接发往本 agent
	skynet.call(conf.gate, "lua", "forward", client_fd, 0)
	skynet.error("[agent] new connection: fd=" .. client_fd)
	start_unauth_timeout()
end

function CMD.disconnect()
	skynet.error("[agent] disconnect: player=" .. tostring(ctx.player_id))
	if ctx.player_id then
		pcall(skynet.send, ".chat", "lua", "unregister", ctx.player_id)
		if not timed_out then
			pcall(skynet.send, ".login", "lua", "logout", ctx.player_id)
		end
	end
	skynet.exit()
end

-- 服务端推送：聊天消息
function CMD.push_chat(channel, from_id, from_name, msg, timestamp)
	if not ctx.player_id then return end
	s2c_push("chat_message", {
		channel = channel,
		from_id = from_id,
		from_name = from_name,
		msg = msg,
		timestamp = timestamp,
	})
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, command, ...)
		local f = CMD[command]
		if f then
			if session ~= 0 then
				skynet.ret(skynet.pack(f(...)))
			else
				f(...)
			end
		end
	end)

	-- client 协议：skynet.redirect 过来的原始 socket 数据
	skynet.register_protocol {
		name = "client",
		id = skynet.PTYPE_CLIENT,
		unpack = function(msg, sz)
			return host:dispatch(msg, sz)
		end,
		dispatch = function(fd, _, type, ...)
			skynet.ignoreret()
			if fd ~= client_fd then
				return
			end
			if type == "REQUEST" then
				local name, args, response_func, ud, session = ...
				local function send_response(args)
					local data = response_func(args, ud)
					if data then
						local package = string.pack(">s2", data)
						socket.write(client_fd, package)
					end
				end
				local function send_err(code, msg)
					local header = core.encode(host.__package, { type = 1, session = session })
					local content = core.encode(error_resp_type, { code = code, msg = msg })
					local data = core.pack(header .. content)
					local package = string.pack(">s2", data)
					socket.write(client_fd, package)
				end
				request_handler(name, args, send_response, send_err)
			end
		end,
	}
end)
