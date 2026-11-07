#!/usr/bin/env bash
#
# 迁移文件规范 + 密钥泄露检查。
#
# 不需要任何 AWS 凭据，也不需要数据库，所以在 PR 阶段就能跑。
# 它拦的是「提交前就能发现」的问题：
#   1. 迁移文件命名不符合 Flyway 版本规范
#   2. 同一个版本号被用了两次（否则要等到 flyway 执行才报错，太晚）
#   3. 已经存在的迁移文件被人改了内容（checksum 会对不上）
#   4. SQL / 配置 / 工作流里出现明文口令、AccessKey、私钥
#
# 兼容 bash 3.2（macOS 自带版本），不用 mapfile，不用管道子 shell 计数。
#
# 用法：./scripts/check-conventions.sh
#
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT" || exit 1

errors=0
warnings=0

err()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; errors=$((errors + 1)); }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; warnings=$((warnings + 1)); }
ok()   { printf '\033[1;32m[通过]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. 收集迁移文件
# ---------------------------------------------------------------------------
if [[ ! -d sql ]]; then
  err "缺少 sql/ 目录"
  exit 1
fi

files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && files+=("$f")
done < <(find sql -maxdepth 1 -type f -name '*.sql' | sort)

if (( ${#files[@]} == 0 )); then
  err "sql/ 目录下没有任何 .sql 迁移文件"
  exit 1
fi

# 文件名列表（去掉目录前缀）
names=()
for f in "${files[@]}"; do
  names+=("$(basename "$f")")
done

# ---------------------------------------------------------------------------
# 2. 文件名规范：V<数字>__<描述>.sql 或 R__<描述>.sql
# ---------------------------------------------------------------------------
bad_names=0
for base in "${names[@]}"; do
  if [[ ! "$base" =~ ^V[0-9]+__[A-Za-z0-9_]+\.sql$ && ! "$base" =~ ^R__[A-Za-z0-9_]+\.sql$ ]]; then
    err "文件名不符合 Flyway 版本规范：${base}（应为 V<数字>__<描述>.sql 或 R__<描述>.sql，描述只用字母数字下划线）"
    bad_names=$((bad_names + 1))
  fi
done
if (( bad_names == 0 )); then
  ok "迁移文件命名符合规范（${#files[@]} 个文件）"
fi

# ---------------------------------------------------------------------------
# 3. 版本号重复
# ---------------------------------------------------------------------------
versions=()
for base in "${names[@]}"; do
  if [[ "$base" =~ ^V([0-9]+)__ ]]; then
    versions+=("${BASH_REMATCH[1]}")
  fi
done

# 排序去重后找重复
sorted_versions=$(printf '%s\n' "${versions[@]:-}" | sed '/^$/d' | sort -n -u)
dup_versions=$(printf '%s\n' "${versions[@]:-}" | sed '/^$/d' | sort -n | uniq -d)

if [[ -n "$dup_versions" ]]; then
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    matched=""
    for base in "${names[@]}"; do
      [[ "$base" =~ ^V${v}__ ]] && matched="$matched $base"
    done
    err "版本号 V${v} 被多个文件使用：$matched"
  done <<<"$dup_versions"
else
  ok "版本号无重复"
fi

# ---------------------------------------------------------------------------
# 4. 版本号连续性（只警告：Flyway 允许留空号给未来版本）
# ---------------------------------------------------------------------------
if [[ -n "$sorted_versions" ]]; then
  expected=1
  gaps=()
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    while (( expected < v )); do
      gaps+=("V${expected}")
      expected=$((expected + 1))
    done
    expected=$((v + 1))
  done <<<"$sorted_versions"

  if (( ${#gaps[@]} > 0 )); then
    warn "版本号存在空缺：${gaps[*]}（Flyway 默认 outOfOrder=false 不会因此报错，确认是有意留白即可）"
  else
    ok "版本号从 V1 开始连续"
  fi
fi

# ---------------------------------------------------------------------------
# 5. 是否改动了已存在的迁移文件
#    「目标环境是否已执行过」在数据库里，本地拿不到，所以这里只做 git 层面的提示。
#
#    比较基准按场景取：
#      PR   → 目标分支（GITHUB_BASE_REF），能看出这次 PR 改了哪些已有迁移
#      push → HEAD^（合并提交的第一个父节点 = 合并前的环境分支尖端）
#      其它 → origin/main
# ---------------------------------------------------------------------------
if git rev-parse --git-dir >/dev/null 2>&1; then
  base_ref=""
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    # PR 场景：origin/<目标分支>
    if git rev-parse --verify -q "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
      base_ref="origin/${GITHUB_BASE_REF}"
    fi
  elif git rev-parse --verify -q 'HEAD^' >/dev/null 2>&1; then
    # push 场景：合并前的环境分支尖端
    base_ref="HEAD^"
  else
    for ref in origin/main main; do
      if git rev-parse --verify -q "$ref" >/dev/null 2>&1; then
        base_ref="$ref"
        break
      fi
    done
  fi

  if [[ -n "$base_ref" ]]; then
    changed=$(git diff --name-only --diff-filter=M "$base_ref" -- 'sql/*.sql' 2>/dev/null || true)
    if [[ -n "$changed" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        warn "已改动历史迁移文件：$f —— 若它在目标环境已执行过，checksum 会对不上，需先执行 flyway repair"
      done <<<"$changed"
    else
      ok "没有改动已存在的迁移文件（基准：${base_ref}）"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. 密钥泄露检查
# ---------------------------------------------------------------------------
secret_patterns=(
  'IDENTIFIED[[:space:]]+BY'
  'IDENTIFIED[[:space:]]+WITH'
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'aws_secret_access_key'
  '-----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY-----'
  'jdbc:mysql://[^[:space:]/@]+:[^[:space:]@]+@'
)

leak_hits=0

check_file_for_secrets() {
  local f=$1 pat line
  for pat in "${secret_patterns[@]}"; do
    if grep -nEi -- "$pat" "$f" >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        err "$f:$line"
        leak_hits=$((leak_hits + 1))
      done < <(grep -nEi -- "$pat" "$f" | head -n 3)
    fi
  done
}

while IFS= read -r f; do
  [[ -n "$f" ]] && check_file_for_secrets "$f"
done < <(find sql -type f -name '*.sql' 2>/dev/null)

# 配置文件里绝不能出现密码项
if [[ -f flyway.conf ]]; then
  if grep -nE '^[[:space:]]*flyway\.password[[:space:]]*=' flyway.conf >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      err "flyway.conf:$line —— 口令必须来自 Secrets Manager，禁止写进配置文件"
      leak_hits=$((leak_hits + 1))
    done < <(grep -nE '^[[:space:]]*flyway\.password[[:space:]]*=' flyway.conf)
  else
    ok "flyway.conf 中没有 password 配置项"
  fi
fi

# 工作流里不能出现明文 AWS 密钥
wf_hits=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if grep -nE 'aws_secret_access_key|AKIA[0-9A-Z]{16}|SECRET_ACCESS_KEY:[[:space:]]*[^$]' "$f" >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      err "$f:$line"
      wf_hits=$((wf_hits + 1))
    done < <(grep -nE 'aws_secret_access_key|AKIA[0-9A-Z]{16}|SECRET_ACCESS_KEY:[[:space:]]*[^$]' "$f" | head -n 3)
  fi
done < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
leak_hits=$((leak_hits + wf_hits))

if (( leak_hits == 0 )); then
  ok "未发现明文口令 / AccessKey / 私钥"
fi

# ---------------------------------------------------------------------------
printf '\n'
if (( errors > 0 )); then
  printf '\033[1;31m检查失败：%d 个错误，%d 个警告\033[0m\n' "$errors" "$warnings" >&2
  exit 1
fi
printf '\033[1;32m检查通过：%d 个警告\033[0m\n' "$warnings"
exit 0
