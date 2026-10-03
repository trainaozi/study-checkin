#!/usr/bin/env bash
# ============================================================================
#  一键推送到 GitHub 远程仓库
#  项目：晨露学习打卡（单文件 PWA）
#
#  特点：
#    - 幂等：没改动时不报错，正常退出
#    - 安全：推送被拒绝不自动强推，先给出中文处置指引
#    - 全中文提示，错误信息附带可执行的下一步
#
#  执行权限：
#    Linux / macOS / Git Bash：  chmod +x push.sh && ./push.sh
#    Windows PowerShell：       bash push.sh        （无需 chmod）
#    不给执行权限时：            bash push.sh <任意参数>  直接用 bash 解释器运行
# ============================================================================

set -uo pipefail

# ------------------------------ 可配置项 ------------------------------------
REMOTE_NAME="${REMOTE_NAME:-origin}"     # 远程名，默认 origin
BRANCH="${BRANCH:-main}"                 # 目标分支，默认 main
AUTO_COMMIT="${AUTO_COMMIT:-yes}"        # yes=自动 add+commit；no=仅推送已有提交
COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"     # 留空则自动生成
# ---------------------------------------------------------------------------

# ------------------------------ 终端配色 ------------------------------------
#  约定：所有提示一律走 stderr。
#  原因：stage_and_commit 用 msg="$(prompt_commit_message)" 捕获返回值，
#  若提示混进 stdout 会被当作提交信息（曾导致提交记录变成整块面板文本）。
#  正常运行时 stderr 同样显示在终端，不影响观感。
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;36m'; N='\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi
ok()   { printf "${G}✔${N} %s\n" "$1" >&2; }
warn() { printf "${Y}!${N} %s\n" "$1" >&2; }
err()  { printf "${R}✘${N} %s\n" "$1" >&2; }
info() { printf "${B}›${N} %s\n" "$1" >&2; }

# ------------------------------ 前置检查 ------------------------------------
preflight() {
  # 1. git 是否可用
  if ! command -v git >/dev/null 2>&1; then
    err "未找到 git 命令。"
    echo "  请先安装 Git：https://git-scm.com/downloads"
    echo "  安装后重新打开终端再试。"
    exit 1
  fi

  # 2. 是否在 git 仓库中
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    err "当前目录不是 Git 仓库。"
    echo "  当前路径：$(pwd)"
    echo "  若要初始化新仓库，执行：git init"
    exit 1
  fi

  # 3. 是否有冲突残留（有 MERGE_HEAD 说明上次操作被打断）
  if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    err "检测到未完成的合并操作。"
    echo "  请先解决冲突："
    echo "    git status              # 查看冲突文件"
    echo "    git add <文件>          # 标记已解决"
    echo "    git commit              # 完成合并（或 git merge --abort 放弃）"
    exit 1
  fi

  # 4. 是否有 rebase/cherry-pick 残留
  local gd; gd="$(git rev-parse --git-dir)"
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    err "检测到未完成的 rebase 操作。"
    echo "  继续：git rebase --continue    放弃：git rebase --abort"
    exit 1
  fi
  if [ -f "$gd/CHERRY_PICK_HEAD" ]; then
    err "检测到未完成的 cherry-pick。"
    echo "  继续：git cherry-pick --continue    放弃：git cherry-pick --abort"
    exit 1
  fi
}

# ------------------------- 变更检测与提交 ----------------------------------
stage_and_commit() {
  local staged untracked modified
  # 已暂存 / 已修改 / 未跟踪
  staged="$(git diff --cached --name-only 2>/dev/null)"
  modified="$(git diff --name-only 2>/dev/null)"
  untracked="$(git ls-files --others --exclude-standard 2>/dev/null)"

  if [ -z "$staged$modified$untracked" ]; then
    info "工作区干净，没有需要提交的改动。"
    return 2
  fi

  echo
  info "检测到以下改动："
  # 只展示前 12 条，避免刷屏
  {
    [ -n "$staged" ]    && echo "${G}  已暂存修改：${N}" && echo "$staged"    | sed 's/^/    /'
    [ -n "$modified" ]  && echo "${Y}  未暂存修改：${N}" && echo "$modified"  | sed 's/^/    /'
    [ -n "$untracked" ] && echo "${B}  新增未跟踪：${N}" && echo "$untracked" | sed 's/^/    /'
  } | head -40
  local total
  total=$(printf '%s\n%s\n%s\n' "$staged" "$modified" "$untracked" | grep -c . || true)
  [ "$total" -gt 12 ] && echo "    …… 另有 $((total - 12)) 个文件未显示"
  echo

  if [ "$AUTO_COMMIT" != "yes" ]; then
    info "AUTO_COMMIT=no，跳过自动提交，直接进入推送。"
    return 0
  fi

  # 密钥文件兜底检查（.gitignore 之外的意外提交）
  local danger
  danger="$(printf '%s\n%s\n%s\n' "$staged" "$modified" "$untracked" \
            | grep -Ei '(^|/)(\.env|id_rsa|\.pem|.*\.key|credentials)' || true)"
  if [ -n "$danger" ]; then
    err "改动中疑似包含敏感文件，已中止："
    echo "$danger" | sed 's/^/    /'
    echo "  请确认这些文件确实需要提交，或把它们加入 .gitignore 后重试。"
    exit 1
  fi

  # 全部加入暂存区
  if [ -n "$modified$untracked" ]; then
    info "正在 git add -A …"
    if ! git add -A; then
      err "git add 失败。"
      echo "  可能原因：文件被占用、权限不足，或路径过长（Windows 需开启长路径支持）。"
      exit 1
    fi
  fi

  # 提交信息优先级：
  #   1) 环境变量 COMMIT_MESSAGE（供自动化调用）
  #   2) 交互式输入（终端下提示填写本次更新内容）
  #   3) 沿用上一次提交信息
  #   4) 按改动数量自动生成
  local msg="$COMMIT_MESSAGE"
  if [ -z "$msg" ]; then
    # 结果写全局变量而非 stdout：
    # 若用 $(...) 接收，函数内的 exit 1 只退出子 shell，主流程会继续往下推送。
    PROMPT_ABORTED=""
    prompt_commit_message
    if [ -n "$PROMPT_ABORTED" ]; then
      err "$PROMPT_ABORTED"
      echo "  提示：可用 COMMIT_MESSAGE=\"你的说明\" ./push.sh 直接指定，或 AUTO_COMMIT=no 仅推送。"
      exit 1
    fi
    msg="$PROMPT_RESULT"
  fi
  if [ -z "$msg" ]; then
    msg="$(git log -1 --pretty=%s 2>/dev/null | head -1)"
  fi
  if [ -z "$msg" ]; then
    local n; n="$(git diff --cached --name-only | wc -l | tr -d ' ')"
    msg="更新本地文件（${n} 个）"
  fi

  info "正在提交：$msg"
  if ! git commit -m "$msg"; then
    err "提交失败。"
    echo "  可能是提交信息为空或含特殊字符，请换一条信息重试。"
    exit 1
  fi
  ok "提交完成：$msg"
  return 0
}

# ------------------------- 提交信息交互输入 --------------------------------
#  结果写入全局变量（不使用 stdout，避免被 $(...) 捕获）：
#    PROMPT_RESULT   —— 用户填写的提交信息
#    PROMPT_ABORTED  —— 非空表示用户连续空输入、已放弃，调用方应退出
#
#  设计要点：
#   - 非交互环境（管道、CI、cron）自动跳过，不阻塞等待输入
#   - 空输入允许重试，连续 3 次为空则放弃（不静默用旧信息提交）
#   - 去除首尾空格与空字节，避免 git commit 因参数异常失败
#   - 函数内绝不 exit：$(...) 子 shell 会吞掉退出码导致主流程继续执行
PROMPT_RESULT=""
PROMPT_ABORTED=""
prompt_commit_message() {
  PROMPT_RESULT=""
  PROMPT_ABORTED=""
  # 非交互终端（无 tty）不打扰：CI/管道场景下自动跳过
  if [ ! -t 0 ]; then
    return 0
  fi
  if [ "$AUTO_COMMIT" != "yes" ]; then
    return 0
  fi

  local n
  n="$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  printf "${B}┌─ 本次更新内容（%s 个文件）${N}\n" "$n"
  echo "  简短说明这次改了什么，会作为 Git 提交记录。"
  # 显示改动概览帮助回忆
  local summary
  summary="$(git diff --cached --stat 2>/dev/null | tail -1)"
  [ -n "$summary" ] && echo "  ${summary}"
  echo

  local input attempt
  for attempt in 1 2 3; do
    if [ $attempt -eq 1 ]; then
      printf "${G}  >${N} "
    else
      printf "  ${G}(%s/3) 再输入一次 >${N} " "$attempt"
    fi
    # read 不带 -p（部分 sh 无此选项）；失败视为空输入继续重试
    if ! IFS= read -r input; then
      input=""
    fi
    # 去掉首尾空白
    input="$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # 剔除空字节，防止 git commit 参数异常
    input="$(printf '%s' "$input" | tr -d '\000')"

    if [ -n "$input" ]; then
      printf "└─ %s\n\n" "$input"
      PROMPT_RESULT="$input"
      return 0
    fi
    warn "内容不能为空，请填写本次更新了什么。"
  done

  PROMPT_ABORTED="连续 3 次未填写更新内容，已中止（避免提交无说明的记录）。"
  return 1
}

# ------------------------------ 远程处理 ------------------------------------
ensure_remote() {
  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    ok "远程仓库：$REMOTE_NAME → $(git remote get-url "$REMOTE_NAME")"
    return 0
  fi

  warn "未找到远程仓库 '$REMOTE_NAME'。"

  # 尝试复用其它已配置的远程
  local other
  other="$(git remote 2>/dev/null | head -1)"
  if [ -n "$other" ]; then
    warn "检测到已配置的远程：$other"
    if [ "$other" != "$REMOTE_NAME" ]; then
      printf "  是否把 '$REMOTE_NAME' 指向同一地址？(y/N) "
      read -r ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        git remote add "$REMOTE_NAME" "$(git remote get-url "$other")" && ok "已关联 $REMOTE_NAME → $other"
      else
        REMOTE_NAME="$other"
        warn "改用远程：$REMOTE_NAME"
      fi
    fi
    return 0
  fi

  # 没有任何远程：询问地址
  echo
  echo "  本项目线上地址：https://trainaozi.github.io/study-checkin/"
  echo "  仓库地址推测：  git@github.com:trainaozi/study-checkin.git"
  echo
  printf "  请输入远程仓库地址（直接回车用上面推测的 SSH 地址）："
  read -r url
  url="${url:-git@github.com:trainaozi/study-checkin.git}"

  if ! git remote add "$REMOTE_NAME" "$url"; then
    err "关联远程失败。"
    exit 1
  fi
  ok "已关联：$REMOTE_NAME → $url"
}

# ------------------------------ 分支处理 ------------------------------------
ensure_branch() {
  local cur
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [ "$cur" = "HEAD" ]; then
    err "当前处于 detached HEAD 状态（不在任何分支上）。"
    echo "  请先切回分支：git checkout main"
    exit 1
  fi

  if [ "$cur" != "$BRANCH" ]; then
    warn "当前分支是 '$cur'，目标分支是 '$BRANCH'。"
    printf "  是否切换到 '$BRANCH'？(y/N) "
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if git checkout "$BRANCH" 2>/dev/null; then
        ok "已切换到 $BRANCH"
      else
        warn "分支 '$BRANCH' 不存在，已切换到 $cur 并继续。"
        BRANCH="$cur"
      fi
    else
      warn "保持当前分支 $cur，推送到 origin/$cur"
      BRANCH="$cur"
    fi
  fi

  # 首次推送需建立上游追踪
  if ! git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    info "首次推送：将建立上游追踪 origin/$BRANCH"
  fi
}

# ------------------------------ 推送 ----------------------------------------
do_push() {
  info "正在推送到 $REMOTE_NAME/$BRANCH …"
  local out
  # -u 建立/更新上游追踪；2>&1 合并输出用于错误识别
  if out="$(git push -u "$REMOTE_NAME" "$BRANCH" 2>&1)"; then
    ok "推送成功"
    printf '%s\n' "$out" | sed 's/^/  /'
    return 0
  fi

  # ---- 推送失败：按原因分类处理 ----
  printf '%s\n' "$out" | sed 's/^/  /'
  echo

  # 权限/认证问题
  if grep -qiE 'permission denied|authentication failed|could not read username|terminal prompts disabled' <<<"$out"; then
    err "认证失败：没有写入远程仓库的权限。"
    echo "  可能原因与对策："
    echo "   1) SSH 未配置密钥 —— 生成并添加公钥："
    echo "      ssh-keygen -t ed25519 -C \"你的邮箱\""
    echo "      cat ~/.ssh/id_ed25519.pub    # 复制内容到 GitHub → Settings → SSH keys"
    echo "   2) 改用 HTTPS + 个人访问令牌："
    echo "      git remote set-url $REMOTE_NAME https://github.com/trainaozi/study-checkin.git"
    echo "      推送时用户名填 GitHub 用户名，密码处粘贴 token（需 repo 权限）"
    echo "   3) 确认该仓库确实属于你，且已授予写权限"
    exit 1
  fi

  # 远程不存在
  if grep -qiE 'repository not found|could not read from remote repository' <<<"$out"; then
    err "远程仓库不存在或地址错误。"
    echo "  当前地址：$(git remote get-url "$REMOTE_NAME" 2>/dev/null)"
    echo "  本项目线上地址：https://trainaozi.github.io/study-checkin/"
    echo "  请核对仓库名与账号是否正确。确需改地址："
    echo "    git remote set-url $REMOTE_NAME <正确的地址>"
    exit 1
  fi

  # 远程有新提交（非快进）
  if grep -qiE 'non-fast-forward|fetch first|updates were rejected' <<<"$out"; then
    err "推送被拒绝：远程有本地没有的新提交。"
    echo "  建议做法（推荐第 1 种，安全）："
    echo "   1) 先拉取并合并远程改动（保留双方提交）："
    echo "      git pull --rebase $REMOTE_NAME $BRANCH"
    echo "      解决冲突后重新运行本脚本"
    echo "   2) 若确定本地改动应覆盖远程（会丢弃远程提交，谨慎）："
    echo "      git push --force-with-lease $REMOTE_NAME $BRANCH"
    echo "      用 --force-with-lease 而非 -f：远程有他人新提交时会拒绝，避免误覆盖。"
    exit 1
  fi

  # 文件体积超限
  if grep -qiE 'exceeds|file.*too large|size limit' <<<"$out"; then
    err "有文件超过 GitHub 的大小限制（单文件 100MB / 仓库 1GB）。"
    echo "  本项目 index.html 约 1.3MB，正常不会触发；若确实过大请检查异常文件。"
    exit 1
  fi

  # 网络问题
  if grep -qiE 'could not resolve host|connection timed out|network is unreachable|failed to connect' <<<"$out"; then
    err "网络连接失败。"
    echo "  请检查网络后重试。若使用 SSH，可能被网络拦截，"
    echo "  可改用 HTTPS：git remote set-url $REMOTE_NAME https://github.com/trainaozi/study-checkin.git"
    exit 1
  fi

  # 其它未知错误
  err "推送失败（未识别的错误），完整输出见上方。"
  echo "  可先手动执行排查：git push -v $REMOTE_NAME $BRANCH"
  exit 1
}

# ------------------------------ 结果提示 ------------------------------------
show_result() {
  local url="https://trainaozi.github.io/study-checkin/"
  echo
  ok "全部完成"
  echo
  echo "  线上地址：$url"
  echo "  提示：GitHub Actions 自动部署，通常 1–2 分钟生效。"
  echo "  验证：命令行执行  curl -sI $url | head -1"
  echo
}

# ------------------------------ 主流程 --------------------------------------
main() {
  echo "============================================"
  echo "  晨露学习打卡 · 一键推送到 GitHub"
  echo "============================================"

  preflight
  echo
  info "仓库路径：$(pwd)"

  # 处理改动（含提交）
  stage_and_commit
  local rc=$?
  if [ $rc -eq 2 ]; then
    # 无改动：仍可推送已有提交
    info "无新提交，将尝试推送本地已有提交。"
  fi

  echo
  ensure_remote
  echo
  ensure_branch
  echo
  do_push
  show_result
}

main "$@"

# ============================================================================
#  运行方式
# ----------------------------------------------------------------------------
#  【Git Bash / Linux / macOS】
#     chmod +x push.sh        # 首次使用需赋予执行权限（只需做一次）
#     ./push.sh               # 运行
#     省略 chmod 也可直接：  bash push.sh
#
#  【Windows PowerShell / CMD】
#     bash push.sh            # Git Bash 下无需 chmod
#     或在资源管理器右键 → 属性 → 勾选「解除锁定」后双击运行
#
#  【可配置环境变量】（默认值见脚本顶部，可按需覆盖）
#     REMOTE_NAME=origin  指定远程名
#     BRANCH=main         指定目标分支
#     AUTO_COMMIT=no      只推送已有提交，不自动 add/commit
#     COMMIT_MESSAGE="说明"  指定提交信息（留空则沿用上次提交信息风格）
#
#     示例：跳过自动提交，只推送已有提交
#       AUTO_COMMIT=no ./push.sh
#     示例：推送 develop 分支并指定提交信息
#       BRANCH=develop COMMIT_MESSAGE="修复打卡页布局" ./push.sh
#
#  【提交信息】脚本会先列出本次改动的文件，然后提示你填写「这次更新了什么」。
#     输入直接回车 = 沿用上一次的提交信息风格（省事）
#     连续 3 次留空 = 中止本次推送（避免产生无说明的提交记录）
#     非交互环境（管道 / CI）自动跳过提问，不阻塞
#
#  【安全说明】
#     - 脚本不会自动强推（--force）。远程有他人新提交时会中止并给出处置方案，
#       需你确认后手动执行 git push --force-with-lease。
#     - 检测到 .env / id_rsa / *.key 等敏感文件时会中止提交。
#     - 执行前请确认工作区内容，脚本会先列出全部待提交文件供核对。
# ============================================================================
