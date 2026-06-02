-- item_template: 物品模板
-- 数据由 tools/export_config.py 从 design/item.xlsx 生成
-- 本模块提供查询封装，兼容已有调用方（bag.lua 等）

local config = require "config.item"

local M = {}

-- 物品类型
M.TYPE = {
	CONSUMABLE = "consumable",
	EQUIPMENT  = "equipment",
	MATERIAL   = "material",
	CURRENCY   = "currency",
}

-- 品质
M.QUALITY = {
	NORMAL    = 1,
	FINE      = 2,
	RARE      = 3,
	EPIC      = 4,
	LEGENDARY = 5,
}

-- 装备槽位
M.EQUIP_SLOT = {
	WEAPON   = "weapon",
	CHEST    = "chest",
	HELMET   = "helmet",
	GLOVES   = "gloves",
	BOOTS    = "boots",
	RING     = "ring",
	NECKLACE = "necklace",
}

-- 获取单个物品模板
function M.get(item_id)
	return config[item_id]
end

-- 检查物品是否可堆叠
function M.is_stackable(item_id)
	local t = config[item_id]
	return t and t.stackable or false
end

-- 获取最大堆叠数
function M.get_max_stack(item_id)
	local t = config[item_id]
	return t and t.max_stack or 1
end

-- 获取使用效果
function M.get_use_effect(item_id)
	local t = config[item_id]
	return t and t.use_effect or nil
end

-- 获取装备属性
function M.get_attributes(item_id)
	local t = config[item_id]
	return t and t.attributes or nil
end

-- 获取物品种类列表
function M.get_by_type(item_type)
	local result = {}
	for _, t in pairs(config) do
		if t.type == item_type then
			table.insert(result, t)
		end
	end
	return result
end

-- 获取所有模板
function M.all()
	return config
end

return M
