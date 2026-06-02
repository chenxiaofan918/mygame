-- luacheck 配置
-- 安装: luarocks install luacheck
-- 运行: luacheck server/（或指定文件/目录）

-- Lua 标准（Skynet 使用 Lua 5.4 运行时）
std = "lua54"

-- 忽略规则（根据实际项目需求调整）
ignore = {
    -- 212: 未使用的参数
    -- Skynet 回调中 _session/_source/_fd 等约定俗成的占位参数
    "212",

    -- 431: 未使用的影子变量定义
    -- 如 local node = skynet.getenv("node") 后续未使用
    "431",

    -- 542: 空 if 分支
    -- 某些协议 handler 中 ping 等空实现
    "542",
}

-- 全局变量白名单
-- Skynet 框架将一些函数注入全局环境
globals = {
    "skynet",
}

-- 行宽限制（与 CODING_STANDARDS.md 一致）
max_line_length = 120

-- 允许的最大嵌套深度
max_loop_nesting = 4

-- 文件编码
-- (Windows 下避免 UTF-8 BOM 警告)
allow_defined_top = true
