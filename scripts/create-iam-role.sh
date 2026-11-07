#!/usr/bin/env bash
#
# 一次性创建 GitHub Actions 用来跑数据库迁移的 IAM 角色（OIDC，无长期密钥）。
#
# 幂等：可以重复执行，角色与内联策略会被覆盖成当前文件的内容。
#
# 用法：
#   ./scripts/create-iam-role.sh                 # 默认 dev 环境
#   ENVIRONMENT=staging ./scripts/create-iam-role.sh
#
# 可覆盖的变量：
#   ENVIRONMENT        GitHub Environment 名，决定 sub 信任条件（默认 dev）
#   ROLE_NAME          角色名（默认 rds-migrate-<环境>）
#   GITHUB_OWNER       仓库属主（默认 tengsihai）
#   GITHUB_REPO        仓库名（默认 mysql-aws）
#   AWS_REGION         区域（默认 ap-northeast-1）
#   ASG_NAME           跳板机 ASG 名（默认 platform-dev-bastion）
#   BASTION_TAG_KEY    跳板机实例标签键（默认 Bastion）
#   BASTION_TAG_VALUE  跳板机实例标签值（默认 platform-dev-bastion）
#
# 注意：这个角色属于本仓库的 CI 基础设施。如果希望统一由 terraform-aws 管理，
#       把 infra/ 下的两份 JSON 搬过去做成 IAM 资源即可，权限内容不变。
#
set -euo pipefail

: "${ENVIRONMENT:=dev}"
: "${ROLE_NAME:=rds-migrate-${ENVIRONMENT}}"
: "${GITHUB_OWNER:=tengsihai}"
: "${GITHUB_REPO:=mysql-aws}"
: "${AWS_REGION:=ap-northeast-1}"
: "${AWS_DEFAULT_REGION:=${AWS_REGION}}"
: "${ASG_NAME:=platform-dev-bastion}"
: "${BASTION_TAG_KEY:=Bastion}"
: "${BASTION_TAG_VALUE:=platform-dev-bastion}"

export AWS_REGION AWS_DEFAULT_REGION

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TRUST_SRC="${REPO_ROOT}/infra/trust-policy.json"
POLICY_SRC="${REPO_ROOT}/infra/migrate-policy.json"

log()  { printf '\033[1;34m[iam]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[iam]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "缺少 aws CLI"
[[ -f "$TRUST_SRC" ]]  || die "找不到 $TRUST_SRC"
[[ -f "$POLICY_SRC" ]] || die "找不到 $POLICY_SRC"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "None" ]] || die "无法取得当前账号 ID"

# 把模板占位符替换成实际值。用 awk 而不是 sed，避免值里出现 & 或反斜杠时出问题。
render() {
  awk -v account="$ACCOUNT_ID" \
      -v region="$AWS_REGION" \
      -v owner="$GITHUB_OWNER" \
      -v repo="$GITHUB_REPO" \
      -v env="$ENVIRONMENT" \
      -v asg="$ASG_NAME" \
      -v tagkey="$BASTION_TAG_KEY" \
      -v tagval="$BASTION_TAG_VALUE" '
    {
      gsub(/__ACCOUNT_ID__/, account)
      gsub(/__REGION__/, region)
      gsub(/__GITHUB_OWNER__/, owner)
      gsub(/__GITHUB_REPO__/, repo)
      gsub(/__ENVIRONMENT__/, env)
      gsub(/__ASG_NAME__/, asg)
      gsub(/__BASTION_TAG_KEY__/, tagkey)
      gsub(/__BASTION_TAG_VALUE__/, tagval)
      print
    }' "$1"
}

trust_json=$(render "$TRUST_SRC")
policy_json=$(render "$POLICY_SRC")

# 渲染结果必须是合法 JSON，否则 IAM API 会给出很难读的报错
printf '%s' "$trust_json"  | python3 -m json.tool >/dev/null || die "trust-policy.json 渲染后不是合法 JSON"
printf '%s' "$policy_json" | python3 -m json.tool >/dev/null || die "migrate-policy.json 渲染后不是合法 JSON"

# ---------------------------------------------------------------------------
# 创建 / 更新角色
# ---------------------------------------------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "角色已存在，更新信任策略：$ROLE_NAME"
  printf '%s' "$trust_json" > "${TMPDIR:-/tmp}/trust-policy.$$.json"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${TMPDIR:-/tmp}/trust-policy.$$.json"
  rm -f "${TMPDIR:-/tmp}/trust-policy.$$.json"
else
  log "创建角色：$ROLE_NAME"
  printf '%s' "$trust_json" > "${TMPDIR:-/tmp}/trust-policy.$$.json"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --description "GitHub Actions Flyway migrations (${ENVIRONMENT}): read RDS secret, SSM port-forward via bastion, adjust bastion capacity" \
    --max-session-duration 3600 \
    --assume-role-policy-document "file://${TMPDIR:-/tmp}/trust-policy.$$.json" >/dev/null
  rm -f "${TMPDIR:-/tmp}/trust-policy.$$.json"
fi

log "写入内联策略：rds-migrate"
printf '%s' "$policy_json" > "${TMPDIR:-/tmp}/migrate-policy.$$.json"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name rds-migrate \
  --policy-document "file://${TMPDIR:-/tmp}/migrate-policy.$$.json" >/dev/null
rm -f "${TMPDIR:-/tmp}/migrate-policy.$$.json"

role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

cat <<EOF

角色已就绪：
  角色名  : ${ROLE_NAME}
  角色ARN : ${role_arn}

接下来在 GitHub 仓库里配置（一次性）：
  Settings → Environments → 新建环境「${ENVIRONMENT}」
  Settings → Environments → ${ENVIRONMENT} → Variables
      AWS_ROLE_ARN = ${role_arn}

（若该环境是生产环境，记得同时加上 Required reviewers，dev 按惯例「合并即审批」。）
EOF
