-- handlers/rank.lua — 排行榜系统协议处理
local skynet = require "skynet"
local const = require "const"

local H = {}

function H.rank_top(ctx, args, response, err_response)
	local ok, result = pcall(skynet.call, ".rank", "lua", "get_board", args.board_type or "level", args.top_n or 10)
	if ok then
		response({ ok = true, entries = result.entries or {}, update_time = result.update_time or 0 })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "rank_top failed")
	end
end

function H.rank_self(ctx, args, response, err_response)
	local ok, result = pcall(skynet.call, ".rank", "lua", "get_rank", ctx.player_id, args.board_type or "level")
	if ok then
		response({ ok = true, rank = result.rank, score = result.score, total = result.total })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "rank_self failed")
	end
end

return H
