-- =============================================================================
-- V1__init_schema —— 初始建表
--
-- 仓库边界：
--   本仓库只维护业务表 DDL。RDS 实例、VPC、安全组、跳板机等基础设施由
--   terraform-aws 仓库管理，本文件不涉及任何基础设施定义。
--
-- 命名与版本约定：
--   1. 表名统一小写下划线，业务表以 `t_` 开头。
--   2. 已经执行过的迁移文件禁止再修改：改了内容 checksum 就对不上，
--      后续 flyway validate 会直接失败。新增结构一律追加新版本 V3、V4……
--   3. 这里刻意不写 `IF NOT EXISTS`。Flyway 用 flyway_schema_history 自己跟踪
--      状态，写 IF NOT EXISTS 只会把「表被外部删掉/改过」这种漂移悄悄掩盖掉，
--      让流水线绿灯但实际结构已经不对。
--   4. 显式指定字符集 utf8mb4 与排序规则，避免依赖实例默认值导致环境间不一致。
--   5. DDL 与 DML 分开成版本：建表在 V1，种子数据在 V2，
--      这样既能单独跑 `flyway migrate -target=1` 拿到纯净结构，也便于回溯。
--
-- 本版本内容：
--   t_migration_check —— 迁移链路自检表（非业务表）
--     用途：验证「DDL → 种子数据 → 校验」这条发布链路是否打通。
--     字段刻意覆盖了自增主键、唯一键、复合索引、CHECK 约束、DECIMAL 精度、
--     JSON、可空列、时间戳默认值与自动更新，便于尽早暴露 MySQL 版本/方言兼容问题。
--     业务表请从 V3 开始追加，不要复用这张表。
-- =============================================================================

CREATE TABLE `t_migration_check` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
    `biz_no`      VARCHAR(64)     NOT NULL                COMMENT '业务编号，全局唯一',
    `name`        VARCHAR(128)    NOT NULL                COMMENT '名称',
    `status`      TINYINT UNSIGNED NOT NULL DEFAULT 0     COMMENT '状态：0=待处理 1=处理中 2=已完成',
    `amount`      DECIMAL(18, 2)  NOT NULL DEFAULT 0.00   COMMENT '金额，18 位精度 2 位小数',
    `payload`     JSON            NULL                    COMMENT '扩展字段，JSON 类型，可为 NULL',
    `remark`      VARCHAR(255)    NULL     DEFAULT NULL   COMMENT '备注，可为 NULL',
    `is_deleted`  TINYINT(1)      NOT NULL DEFAULT 0      COMMENT '软删除标记：0=否 1=是',
    `created_at`  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `updated_at`  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',

    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_biz_no` (`biz_no`),
    KEY `idx_status_created_at` (`status`, `created_at`),

    CONSTRAINT `chk_status` CHECK (`status` IN (0, 1, 2)),
    CONSTRAINT `chk_is_deleted` CHECK (`is_deleted` IN (0, 1))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '迁移链路自检表（非业务表，仅用于验证发布链路）';
