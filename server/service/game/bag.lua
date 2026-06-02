-- bag: 玩家背包服务
-- MongoDB 持久化，Redis 生成 item uid
-- 全文档读写模式：每次修改后 $set 替换整个 items 数组
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local item_tpl = require "item_template"
local const = require "const"

local CMD = {}
local mongoproxy = ".mongoproxy"
local redisproxy = ".redisproxy"

-- 默认背包容量
local DEFAULT_CAPACITY = 100

-- ======== 内部函数 ========

-- 生成物品实例 UID
local function gen_item_uid()
	local ok, id = pcall(skynet.call, redisproxy, "lua", "gen_id", "item:uid")
	if ok then
		return "item_" .. id
	end
	return nil
end

-- 从 MongoDB 加载背包
local function load_bag(player_id)
	local ok, result = pcall(skynet.call, mongoproxy, "lua", "mongo.find_one", "bag", { player_id = player_id })
	if ok and result then
		return result
	end
	return nil
end

-- 保存背包（全量覆盖 items 数组）
local function save_bag(player_id, bag)
	if not bag._id then
		-- 新背包，insert
		pcall(skynet.call, mongoproxy, "lua", "mongo.insert_safe", "bag", {
			player_id = player_id,
			items = bag.items or {},
			capacity = bag.capacity or DEFAULT_CAPACITY,
			gold = bag.gold or 0,
			updated_at = os.time(),
		})
	else
		pcall(skynet.call, mongoproxy, "lua", "mongo.update_one", "bag",
			{ player_id = player_id },
			{ ["$set"] = {
				items = bag.items,
				capacity = bag.capacity,
				gold = bag.gold,
				updated_at = os.time(),
			}}
		)
	end
end

-- 查找可堆叠的物品槽位
local function find_stack_slot(items, item_id, max_stack)
	for i, item in ipairs(items) do
		if item.item_id == item_id and item.count < max_stack then
			return i, item
		end
	end
	return nil
end

-- 根据 uid 查找物品
local function find_by_uid(items, uid)
	for i, item in ipairs(items) do
		if item.uid == uid then
			return i, item
		end
	end
	return nil
end

-- 整理物品：按类型+品质排序，空闲槽位压缩
local function sort_items(items)
	local sorted = {}
	for _, item in ipairs(items) do
		table.insert(sorted, item)
	end
	table.sort(sorted, function(a, b)
		local ta = item_tpl.get(a.item_id)
		local tb = item_tpl.get(b.item_id)
		if not ta then return false end
		if not tb then return true end
		if ta.type ~= tb.type then
			return ta.type < tb.type
		end
		return (ta.quality or 1) > (tb.quality or 1)
	end)
	-- 重新编号 position
	for i, item in ipairs(sorted) do
		item.position = i
	end
	return sorted
end

-- ======== CMD ========

-- 获取背包数据
function CMD.get(player_id)
	local bp = load_bag(player_id)
	if not bp then
		return { items = {}, gold = 0, capacity = DEFAULT_CAPACITY }
	end
	return bp
end

-- 添加物品
function CMD.add(player_id, item_id, count)
	local tpl = item_tpl.get(item_id)
	if not tpl then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end
	count = count or 1
	if count <= 0 then
		return { ok = false, err = const.ERROR.INVALID_ITEM_TYPE }
	end

	local bp = load_bag(player_id)
	if not bp then
		-- 自动初始化
		bp = { player_id = player_id, items = {}, capacity = DEFAULT_CAPACITY, gold = 0 }
	end

	local items = bp.items or {}
	local new_items = {}

	if tpl.stackable then
		local max_stack = tpl.max_stack or 99
		local remaining = count

		-- 先尝试堆叠到已有物品上
		while remaining > 0 do
			local idx, existing = find_stack_slot(items, item_id, max_stack)
			if idx then
				local can_add = max_stack - existing.count
				local add = math.min(can_add, remaining)
				existing.count = existing.count + add
				remaining = remaining - add
				table.insert(new_items, existing)
			else
				break
			end
		end

		-- 剩余的需要创建新物品
		while remaining > 0 do
			if #items + #new_items >= (bp.capacity or DEFAULT_CAPACITY) then
				return { ok = false, err = const.ERROR.BACKPACK_FULL }
			end
			local add = math.min(remaining, max_stack)
			local uid = gen_item_uid()
			if not uid then
				return { ok = false, err = const.ERROR.SERVICE_UNAVAILABLE }
			end
			local new_item = {
				uid = uid,
				item_id = item_id,
				count = add,
				position = #items + #new_items + 1,
				equipped = false,
				extra = nil,
			}
			table.insert(new_items, new_item)
			remaining = remaining - add
		end
	else
		-- 不可堆叠，每个占一个槽位
		for i = 1, count do
			if #items + #new_items >= (bp.capacity or DEFAULT_CAPACITY) then
				return { ok = false, err = const.ERROR.BACKPACK_FULL }
			end
			local uid = gen_item_uid()
			if not uid then
				return { ok = false, err = const.ERROR.SERVICE_UNAVAILABLE }
			end
			table.insert(new_items, {
				uid = uid,
				item_id = item_id,
				count = 1,
				position = #items + #new_items + 1,
				equipped = false,
				extra = nil,
			})
		end
	end

	-- 合并回 items 数组
	for _, item in ipairs(new_items) do
		table.insert(items, item)
	end
	bp.items = items

	-- 保存
	save_bag(player_id, bp)

	return { ok = true, items = new_items }
end

-- 删除物品
function CMD.remove(player_id, uid, count)
	count = count or 1
	local bp = load_bag(player_id)
	if not bp then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end

	local items = bp.items or {}
	local idx, item = find_by_uid(items, uid)
	if not idx then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end

	if item.count < count then
		return { ok = false, err = const.ERROR.ITEM_NOT_ENOUGH }
	end

	item.count = item.count - count
	if item.count <= 0 then
		table.remove(items, idx)
		-- 重新编号 position
		for i, v in ipairs(items) do
			v.position = i
		end
	end

	bp.items = items
	save_bag(player_id, bp)
	return { ok = true }
end

-- 使用物品
function CMD.use(player_id, uid, count)
	count = count or 1
	local bp = load_bag(player_id)
	if not bp then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end

	local items = bp.items or {}
	local idx, item = find_by_uid(items, uid)
	if not idx then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end
	if item.count < count then
		return { ok = false, err = const.ERROR.ITEM_NOT_ENOUGH }
	end

	local tpl = item_tpl.get(item.item_id)
	if not tpl then
		return { ok = false, err = const.ERROR.ITEM_NOT_FOUND }
	end
	if not tpl.use_effect then
		return { ok = false, err = const.ERROR.CANNOT_USE_ITEM }
	end

	-- 扣除物品
	item.count = item.count - count
	if item.count <= 0 then
		table.remove(items, idx)
		for i, v in ipairs(items) do
			v.position = i
		end
	end

	bp.items = items
	save_bag(player_id, bp)

	-- 返回使用效果
	local effects = {}
	for k, v in pairs(tpl.use_effect) do
		table.insert(effects, { type = k, value = v * count })
	end

	return { ok = true, effects = effects }
end

-- 排序
function CMD.sort(player_id)
	local bp = load_bag(player_id)
	if not bp then
		return { ok = true, items = {} }
	end
	local items = sort_items(bp.items or {})
	bp.items = items
	save_bag(player_id, bp)
	return { ok = true, items = items }
end

-- 初始化背包（创建新玩家时调用）
function CMD.init(player_id)
	pcall(skynet.call, mongoproxy, "lua", "mongo.insert_safe", "bag", {
		player_id = player_id,
		items = {},
		capacity = DEFAULT_CAPACITY,
		gold = 0,
		updated_at = os.time(),
	})
	return { ok = true }
end

-- ======== 服务启动 ========
skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = CMD[cmd]
		if f then
			skynet.ret(skynet.pack(f(...)))
		else
			skynet.error("[bag] unknown cmd: " .. tostring(cmd))
		end
	end)

	skynet.register ".bag"
	skynet.error("[bag] service started")
end)
