# 通讯协议文档

> 自动生成 by `tools/sprotogen.py`  |  SHA-256: `0d96884cbc9728db...`

## 目录

- [bag](#bag)
- [chat](#chat)
- [common](#common)
- [login](#login)
- [rank](#rank)

---
## 共享类型

### `item_entry`

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| uid | 0 | `string` |  |
| item_id | 1 | `integer` |  |
| count | 2 | `integer` |  |
| position | 3 | `integer` |  |
| equipped | 4 | `boolean` |  |
| extra | 5 | `string` |  |

### `effect_entry`

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| type | 0 | `string` |  |
| value | 1 | `integer` |  |

### `chat_message_entry`

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| from_id | 0 | `integer` |  |
| from_name | 1 | `string` |  |
| msg | 2 | `string` |  |
| timestamp | 3 | `integer` |  |

### `package`

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| type | 0 | `integer` |  |
| session | 1 | `integer` |  |

### `rank_entry`

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| rank | 0 | `integer` |  |
| player_id | 1 | `integer` |  |
| nickname | 2 | `string` |  |
| score | 3 | `integer` |  |

---
## bag

### C2S（客户端请求）

#### `bag_list` (tag=30)

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| items | 1 | `item_entry` | 是 |
| gold | 2 | `integer` |  |
| capacity | 3 | `integer` |  |

#### `bag_add` (tag=31)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| item_id | 0 | `integer` |  |
| count | 1 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| items | 1 | `item_entry` | 是 |

#### `bag_remove` (tag=32)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| uid | 0 | `string` |  |
| count | 1 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |

#### `bag_use` (tag=33)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| uid | 0 | `string` |  |
| count | 1 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| effects | 1 | `effect_entry` | 是 |

#### `bag_sort` (tag=34)

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| items | 1 | `item_entry` | 是 |

---
## chat

### C2S（客户端请求）

#### `chat_send` (tag=40)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| channel | 0 | `integer` |  |
| target_id | 1 | `integer` |  |
| msg | 2 | `string` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |

#### `chat_history` (tag=41)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| channel | 0 | `integer` |  |
| count | 1 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| messages | 1 | `chat_message_entry` | 是 |

### S2C（服务端推送）

#### `chat_notify` (tag=10)

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| player_id | 0 | `integer` |  |
| msg | 1 | `string` |  |

#### `chat_message` (tag=11)

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| channel | 0 | `integer` |  |
| from_id | 1 | `integer` |  |
| from_name | 2 | `string` |  |
| msg | 3 | `string` |  |
| timestamp | 4 | `integer` |  |

---
## common

### C2S（客户端请求）

#### `ping` (tag=4)

#### `enter_scene` (tag=10)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| scene_id | 0 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |

#### `move` (tag=11)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| x | 0 | `integer` |  |
| y | 1 | `integer` |  |

### S2C（服务端推送）

#### `error` (tag=1)

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| code | 0 | `integer` |  |
| msg | 1 | `string` |  |

---
## login

### C2S（客户端请求）

#### `login` (tag=1)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| account | 0 | `string` |  |
| password | 1 | `string` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| player_id | 1 | `integer` |  |
| token | 2 | `string` |  |
| nickname | 3 | `string` |  |
| level | 4 | `integer` |  |

#### `register` (tag=2)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| account | 0 | `string` |  |
| password | 1 | `string` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| player_id | 1 | `integer` |  |

---
## rank

### C2S（客户端请求）

#### `rank_top` (tag=50)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| board_type | 0 | `string` |  |
| top_n | 1 | `integer` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| entries | 1 | `rank_entry` | 是 |
| update_time | 2 | `integer` |  |

#### `rank_self` (tag=51)

**请求:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| board_type | 0 | `string` |  |

**响应:**

| 字段 | Tag | 类型 | 数组 |
|------|-----|------|------|
| ok | 0 | `boolean` |  |
| rank | 1 | `integer` |  |
| score | 2 | `integer` |  |
| total | 3 | `integer` |  |

