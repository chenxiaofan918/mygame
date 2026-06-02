-- handlers/bag.lua — 背包系统协议处理
local skynet = require "skynet"
local const = require "const"
local json = require "json"

local function format_items(items)
	local result = {}
	for _, item in ipairs(items or {}) do
		table.insert(result, {
			uid = item.uid,
			item_id = item.item_id,
			count = item.count,
			position = item.position or 0,
			equipped = item.equipped or false,
			extra = item.extra and json.encode(item.extra) or "",
		})
	end
	return result
end

local H = {}

function H.bag_list(ctx, args, response, err_response)
	local ok, result = pcall(skynet.call, ".bag", "lua", "get", ctx.player_id)
	if ok then
		response({
			ok = true,
			items = format_items(result.items),
			gold = result.gold or 0,
			capacity = result.capacity or 100,
		})
	else
		err_response(const.ERROR.SERVICE_UNAVAILABLE, "bag service error")
	end
end

function H.bag_add(ctx, args, response, err_response)
	if not args.item_id then
		return err_response(const.ERROR.MISSING_PARAMS, "missing item_id")
	end
	local ok, result = pcall(skynet.call, ".bag", "lua", "add", ctx.player_id, args.item_id, args.count or 1)
	if ok and result.ok then
		response({ ok = true, items = format_items(result.items) })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "bag_add failed")
	end
end

function H.bag_remove(ctx, args, response, err_response)
	if not args.uid then
		return err_response(const.ERROR.MISSING_PARAMS, "missing uid")
	end
	local ok, result = pcall(skynet.call, ".bag", "lua", "remove", ctx.player_id, args.uid, args.count or 1)
	if ok and result.ok then
		response({ ok = true })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "bag_remove failed")
	end
end

function H.bag_use(ctx, args, response, err_response)
	if not args.uid then
		return err_response(const.ERROR.MISSING_PARAMS, "missing uid")
	end
	local ok, result = pcall(skynet.call, ".bag", "lua", "use", ctx.player_id, args.uid, args.count or 1)
	if ok and result.ok then
		response({ ok = true, effects = result.effects or {} })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "bag_use failed")
	end
end

function H.bag_sort(ctx, args, response, err_response)
	local ok, result = pcall(skynet.call, ".bag", "lua", "sort", ctx.player_id)
	if ok and result.ok then
		response({ ok = true, items = format_items(result.items) })
	else
		local code = (result and result.err) or const.ERROR.FAIL
		err_response(code, "bag_sort failed")
	end
end

return H
