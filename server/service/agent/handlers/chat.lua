-- handlers/chat.lua — 聊天系统协议处理
local skynet = require "skynet"
local const = require "const"

local H = {}

function H.chat_send(ctx, args, response, err_response)
	if not args.msg then
		return err_response(const.ERROR.MISSING_PARAMS, "missing msg")
	end
	local brief = {}
	pcall(function()
		brief = skynet.call(".player", "lua", "get_brief", ctx.player_id)
	end)
	local nickname = (brief and brief.nickname) or tostring(ctx.player_id)
	local ok, result = pcall(skynet.call, ".chat", "lua", "send", ctx.player_id, nickname, args.channel or 1, args.target_id or 0, args.msg)
	if ok and result.ok then
		response({ ok = true })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "chat send failed")
	end
end

function H.chat_history(ctx, args, response, err_response)
	local ok, result = pcall(skynet.call, ".chat", "lua", "history", args.channel or 1, args.count or 20)
	if ok then
		response({ ok = true, messages = result.messages or {} })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "chat history failed")
	end
end

return H
