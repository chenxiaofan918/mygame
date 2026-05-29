-- ============================================
-- Game Database Schema
-- ============================================

CREATE DATABASE IF NOT EXISTS `game` DEFAULT CHARACTER SET utf8mb4;
USE `game`;

-- --------------------------------------------
-- 账号表
-- --------------------------------------------
CREATE TABLE IF NOT EXISTS `account` (
	`id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
	`account`    VARCHAR(64)     NOT NULL,
	`password`   VARCHAR(64)     NOT NULL,
	`salt`       VARCHAR(64)     NOT NULL,
	`created_at` DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY (`id`),
	UNIQUE KEY `uk_account` (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------
-- 玩家基础数据表
-- --------------------------------------------
CREATE TABLE IF NOT EXISTS `player` (
	`id`         BIGINT UNSIGNED NOT NULL,
	`nickname`   VARCHAR(32)     NOT NULL DEFAULT '',
	`level`      INT UNSIGNED    NOT NULL DEFAULT 1,
	`exp`        BIGINT UNSIGNED NOT NULL DEFAULT 0,
	`vip_level`  INT UNSIGNED    NOT NULL DEFAULT 0,
	`gold`       BIGINT UNSIGNED NOT NULL DEFAULT 0,
	`diamond`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
	`created_at` DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
	`updated_at` DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
	PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
