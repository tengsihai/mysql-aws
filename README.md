# mysql-aws

用 [Flyway](https://flywaydb.org/) 管理 AWS RDS MySQL 的**业务表 SQL**。

> **仓库边界**：本仓库只维护 DDL / DML 迁移脚本与迁移流水线。
> RDS 实例、VPC、安全组、跳板机等基础设施由
> [tengsihai/terraform-aws](https://github.com/tengsihai/terraform-aws) 管理，
> 本仓库不出现任何 Terraform / CloudFormation 定义。

---

## 1. 目录结构

```
mysql-aws/
├── flyway.conf                     # Flyway 配置（非敏感项；口令绝不写在这里）
├── sql/
│   ├── V1__init_schema.sql         # 初始建表
│   └── V2__seed_test_data.sql      # 自检表种子数据
├── scripts/
│   ├── migrate.sh                  # 统一迁移入口（本地与 CI 同一条代码路径）
│   ├── check-conventions.sh        # 命名规范 + 密钥泄露检查（零凭据）
│   └── create-iam-role.sh          # 一次性创建 OIDC 迁移角色
├── infra/
│   ├── trust-policy.json           # 角色信任策略模板
│   └── migrate-policy.json         # 角色权限策略模板
└── .github/workflows/
    ├── validate.yml                # PR 校验（无 AWS 凭据）
    └── migrate.yml                 # 合并进环境分支后真正迁移
```

---

## 2. 分支模型

**分支名就是环境名。** 合并进哪条分支，就发哪个环境。

```
功能分支 ──PR──> dev / staging / prod ──合并──> 触发 migrate.yml ──> 对应环境的 RDS
   │                    │
   │                    └── 只读的 validate.yml 也会在这些分支上跑
   │
   └── PR 上跑 validate.yml：规范检查 + 在临时 MySQL 里把迁移真跑一遍

main  = 发布后的归档分支，不触发任何部署
```

| 分支 | 作用 | 触发的流水线 |
| --- | --- | --- |
| `dev` | dev 环境的部署分支 | `validate.yml` + `migrate.yml` → `platform-dev-mysql` |
| `staging` | staging 环境的部署分支 | 同上（接入后生效，见 §4.3） |
| `prod` | 生产环境的部署分支 | 同上（接入后生效，见 §4.3） |
| `main` | 发布后归档，只读 | **不触发部署**；指向它的 PR 仍会跑 `validate.yml` |
| 其它 | 开发用的功能分支 | 只在 PR 时跑 `validate.yml` |

工作流用 `environment: ${{ github.ref_name }}` 把分支名直接映射成 GitHub
Environment，该 Environment 上的 `AWS_ROLE_ARN` 决定用哪个 IAM 角色——
所以「dev 分支只能用 dev 角色」由分支本身保证，不靠人记。

未接入的环境由仓库变量 `MIGRATE_ENVIRONMENTS` 控制（默认 `["dev"]`），
不在列表里的分支会直接跳过 job，不会产生红叉。

---

## 3. 流水线

### 3.1 `validate.yml` —— PR 阶段，零凭据

| Job | 做什么 |
| --- | --- |
| 规范与密钥检查 | 文件命名、版本号重复/空缺、有没有把口令写进 SQL/配置/工作流 |
| Flyway 实跑校验 | 起一个临时 MySQL 8.4 容器，把所有迁移真跑一遍，再 `validate` + `info`，最后断言种子数据正好 5 行 |

不使用任何 AWS 凭据，所以 **fork PR 也能跑**。

### 3.2 `migrate.yml` —— 合并进环境分支后

```
push 到 dev/staging/prod（合并进环境分支即触发，不按改动路径过滤）
  │
  ├─ check-conventions.sh        规范与密钥检查
  ├─ OIDC 换取 rds-migrate-<环境> 角色     （无长期密钥）
  └─ scripts/migrate.sh migrate
        ├─ 解析 flyway.conf 拿到主机/端口/库名
        ├─ 按端点反查 RDS 主账号密钥的 ARN
        ├─ 探测 RDS 是否直连可达；不可达就经跳板机建 SSM 端口转发
        ├─ 从 Secrets Manager 取口令 → FLYWAY_PASSWORD（日志里 add-mask）
        ├─ 执行 flyway migrate
        └─ 无论成败：回收 SSM 会话、把跳板机 ASG 容量还原成进入时的值
```

`concurrency` 按环境隔离（`rds-migrate-<分支>`），同一环境串行、不同环境并行，
并且**绝不取消进行中的迁移**——半途而废的 DDL 比排队等待糟糕得多。

---

## 4. 一次性配置

### 4.1 创建 IAM 角色（OIDC，无长期密钥）

```bash
./scripts/create-iam-role.sh
```

幂等，可重复执行。会打印出角色 ARN 和下面要填的 GitHub 配置。

角色只拿到迁移必需的权限：

| 权限 | 用途 |
| --- | --- |
| `secretsmanager:GetSecretValue`（限定 `rds!db-*`） | 取数据库口令 |
| `rds:DescribeDBInstances` | 按端点反查实例与密钥 ARN |
| `autoscaling:UpdateAutoScalingGroup`（限定跳板机 ASG） | 临时拉起 / 还原跳板机 |
| `ssm:StartSession`（限定 `Bastion` 标签实例 + 端口转发文档） | 建隧道 |
| `ssm:TerminateSession` / `Describe*` | 回收与探测会话 |

> 这个角色属于本仓库的 CI 基础设施。若希望统一由 terraform-aws 管理，
> 把 `infra/` 下两份 JSON 搬过去做成 IAM 资源即可，权限内容不变。

### 4.2 GitHub Environment 与仓库变量

**Settings → Environments → New environment**，环境名必须与分支名一致：

| Environment | 分支 | `AWS_ROLE_ARN` |
| --- | --- | --- |
| `dev` | `dev` | `arn:aws:iam::<账号>:role/rds-migrate-dev` |
| `staging` | `staging` | `arn:aws:iam::<账号>:role/rds-migrate-staging` |
| `prod` | `prod` | `arn:aws:iam::<账号>:role/rds-migrate-prod` |

每个 Environment 建议再加 **Deployment branches and tags → Selected branches**，
只允许同名分支——这样即使有人手工 dispatch，也发不到别的环境去。
`prod` 记得加 **Required reviewers**（dev 按惯例「合并即审批」，不加）。

**Settings → Secrets and variables → Actions → Variables**（仓库级）：

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `AWS_REGION` | `ap-northeast-1` | 可选，不配则用工作流里的默认值 |
| `MIGRATE_ENVIRONMENTS` | `["dev"]` | 参与迁移的环境，JSON 数组。接入新环境时改成 `["dev","staging"]` |

### 4.3 接入新环境的清单

1. terraform-aws 里把该环境的 RDS + 跳板机建出来
2. `ENVIRONMENT=staging ./scripts/create-iam-role.sh` 建角色
3. GitHub 建同名 Environment，填 `AWS_ROLE_ARN`，限定部署分支
4. 建同名分支 `staging`
5. 仓库变量 `MIGRATE_ENVIRONMENTS` 加进该环境名
6. 按环境改 `flyway.conf`（不同环境的 RDS 端点不同，见 §5.2）

---

## 5. 本地开发

### 5.1 前置条件

```bash
brew install flyway          # 会一并装上 openjdk
aws ssm install-plugin       # 或 brew install session-manager-plugin
```

跳板机平时缩到 0，需要时拉起来（用完记得改回 0）：

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-names platform-dev-bastion --desired-capacity 1
```

### 5.2 用法

```bash
./scripts/migrate.sh              # = flyway migrate
./scripts/migrate.sh info         # 看已执行 / 待执行版本
./scripts/migrate.sh validate     # 校验已执行脚本的 checksum
./scripts/migrate.sh repair       # 修复 checksum 不一致（谨慎）
./scripts/migrate.sh -target=1 info   # 透传任意 flyway 参数
```

脚本会自己判断要不要建隧道（`TUNNEL=auto`）：

- 已经通过 VPN / 内网能直连 RDS → 直接连，不动跳板机
- 直连不通（RDS 在私有子网，通常如此）→ 自动经跳板机建 SSM 端口转发到 `127.0.0.1:3307`

常用开关（环境变量）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TUNNEL` | `auto` | `auto` / `on` / `off` |
| `TUNNEL_LOCAL_PORT` | `3307` | 本地映射端口 |
| `AUTO_SCALE_BASTION` | `1` | ASG 为 0 时自动拉起 |
| `RESTORE_BASTION` | `1` | 结束时还原为进入时的 desired capacity |
| `MIGRATE_SECRET_ARN` | 空 | 显式指定密钥 ARN，跳过按端点反查 |

**口令永远来自 Secrets Manager**，脚本取到后只放进进程环境变量，
不落盘、不回显、不进 git；在 GitHub Actions 里还会额外 `::add-mask::`。

---

## 6. 迁移脚本规范

### 6.1 命名

```
sql/V<版本号>__<描述>.sql     版本化迁移（只执行一次）
sql/R__<描述>.sql             可重复迁移（每次校验变更后重跑）
```

- 版本号从 `V1` 开始递增，描述只用**字母、数字、下划线**
- 表名统一小写下划线，业务表以 `t_` 开头

### 6.2 铁律

1. **已执行过的文件不许改。** 改了 checksum 就对不上，后续 `validate` 直接失败。
   新增结构一律追加新版本 `V3`、`V4`……
2. **DDL 与 DML 分版本。** 建表一个版本、种子数据一个版本，
   这样 `flyway migrate -target=1` 能拿到只有结构的纯净库。
3. **不写 `IF NOT EXISTS`。** Flyway 用 `flyway_schema_history` 自己跟踪状态，
   写了只会把「表被外部删掉/改过」这种漂移悄悄掩盖掉。
4. **显式指定字符集与排序规则**（`utf8mb4` / `utf8mb4_0900_ai_ci`），
   不依赖实例默认值，避免环境间不一致。
5. **种子数据用普通 `INSERT`**，不用 `INSERT IGNORE`。
   写错了就该让流水线红掉，而不是被静默跳过。

### 6.3 改错已执行的文件怎么办

```bash
./scripts/migrate.sh repair
```

`repair` 会把历史表里的 checksum 更新成当前文件的内容。
**只在确认目标环境里的实际结构与新文件一致时才用**，否则等于把差异抹掉了。

---

## 7. 测试表

`sql/V1__init_schema.sql` 建的 `t_migration_check` 是**迁移链路自检表，不是业务表**：

| 用途 | 说明 |
| --- | --- |
| 验证发布链路 | DDL → 种子数据 → 校验 这条路是否打通 |
| 尽早暴露兼容问题 | 字段覆盖自增主键、唯一键、复合索引、`CHECK` 约束、`DECIMAL(18,2)` 精度边界、`JSON`、可空列、时间戳默认值与自动更新 |

`sql/V2__seed_test_data.sql` 写入 5 条覆盖不同分支的数据：

| biz_no | 场景 |
| --- | --- |
| `MIG-20261106-001` | 待处理 + 0 金额 + JSON 扩展字段 |
| `MIG-20261106-002` | 处理中 + 常规正数金额 |
| `MIG-20261106-003` | 已完成 + `payload` 为 `NULL` |
| `MIG-20261106-004` | 软删除行 + 负数金额（覆盖 `NULL` 与负值分支） |
| `MIG-20261106-005` | `DECIMAL(18,2)` 上界 `9999999999999999.99` |

**业务表请从 `V3` 开始追加，不要复用这张表。**

---

## 8. 当前状态

| 项 | 值 |
| --- | --- |
| RDS | `platform-dev-mysql`，MySQL 8.4.11，`db.t4g.micro`，单 AZ，不公开 |
| 数据库 / 账号 | `appdb` / `admin`（口令在 Secrets Manager，由 RDS 托管轮换） |
| 已应用版本 | `V1 init schema`、`V2 seed test data`（dev 环境已执行） |
| Flyway | 13.12.1（本地与 CI 锁同一版本） |
| 接入环境 | `dev` |
| IAM 角色 | `rds-migrate-dev`（OIDC，最小权限，已创建） |
| GitHub Environment | `dev`，部署分支限定为 `dev`，变量 `AWS_ROLE_ARN` 已填 |
| 仓库变量 | `MIGRATE_ENVIRONMENTS=["dev"]`、`AWS_REGION=ap-northeast-1` |

§4 的一次性配置**已完成**，新环境按 §4.3 的清单接入即可。

---

## 9. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `Validate failed: Migration checksum mismatch` | 改了已执行的文件。确认结构一致后 `./scripts/migrate.sh repair`，否则回滚文件内容 |
| `跳板机没有运行中的实例` | ASG 缩到 0 了，按 §5.1 拉起来，或保持 `AUTO_SCALE_BASTION=1` |
| `跳板机 SSM 未在 300s 内上线` | 实例角色没挂 `AmazonSSMManagedInstanceCore`，或 SSM Agent 没起来 |
| `等待 127.0.0.1:3307 就绪超时` | 端口被占用（改 `TUNNEL_LOCAL_PORT`），或 `session-manager-plugin` 没装 |
| `按端点 ... 没查到 RDS 主账号密钥` | 当前身份没有 `rds:DescribeDBInstances`，或密钥不是 RDS 托管的（此时显式设 `MIGRATE_SECRET_ARN`） |
| CI 里 `role-to-assume` 报错 | Environment 名与分支名不一致，或该 Environment 上没配 `AWS_ROLE_ARN` |
| 工作流直接跳过（灰色） | 分支不在 `MIGRATE_ENVIRONMENTS` 里 |
| `flyway.conf: Unknown configuration property` | 用的是 `-configFiles`（复数），`-configFile` 在 Flyway 13 不是合法参数 |

---

## 10. 安全约定

- **不写死任何密钥。** 口令来自 Secrets Manager，AWS 凭据来自 OIDC 短期凭证，
  全链路没有 AccessKey / 私钥 / 数据库口令入库
- `flyway.conf` 只放非敏感配置；`check-conventions.sh` 会在每次 PR 和每次迁移前
  扫描 SQL、配置与工作流，拦住 `IDENTIFIED BY`、`AKIA…`、私钥块、JDBC URL 带口令等写法
- IAM 角色按最小权限拆分，`ssm:StartSession` 只允许带 `Bastion` 标签的实例
  和端口转发那一个文档
- 跳板机实例没有任何入站规则，唯一访问路径是 SSM
