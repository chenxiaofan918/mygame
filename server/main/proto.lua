-- proto: sproto 协议定义
local sprotoparser = require "sprotoparser"

local proto = {}

proto.c2s = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}

login 1 {
	request {
		account 0 : string
		password 1 : string
	}
	response {
		ok 0 : boolean
		player_id 1 : integer
		token 2 : string
		nickname 3 : string
		level 4 : integer
	}
}

register 2 {
	request {
		account 0 : string
		password 1 : string
	}
	response {
		ok 0 : boolean
		player_id 1 : integer
	}
}

chat 3 {
	request {
		msg 0 : string
	}
	response {
		msg 0 : string
	}
}

ping 4 {}

enter_scene 10 {
	request {
		scene_id 0 : integer
	}
	response {
		ok 0 : boolean
	}
}

move 11 {
	request {
		x 0 : integer
		y 1 : integer
	}
}

]]

proto.s2c = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}

error 1 {
	response {
		code 0 : integer
		msg 1 : string
	}
}

chat_notify 10 {
	response {
		player_id 0 : integer
		msg 1 : string
	}
}

]]

return proto
