# Git 推送指南 · 学习打卡网站更新

每次修改完代码（或由 AI 助手改完并本地提交后），用下面三条命令把更新发布到线上网站：
**`git push` 到 GitHub → Actions 自动部署（约 1–2 分钟）→ 网站自动更新。**

> 网站地址：https://trainaozi.github.io/study-checkin/

---

## 一、每次更新的标准三连

在 **Git Bash**（或任意终端）里执行：

```bash
cd "C:/Users/29021/WorkBuddy/学习小打卡"

git add -A
git commit -m "更新说明，例如：修复删除同步问题"
git push origin main
```

- 第一行：进入项目目录（注意路径有中文，必须加引号）
- `git add -A`：把所有改动加入暂存区
- `git commit -m "说明"`：生成一个本地提交（说明文字随意写，方便以后回顾）
- `git push origin main`：**推送到 GitHub**，之后自动部署

推送后等 1–2 分钟，刷新 https://trainaozi.github.io/study-checkin/ 即可看到新版本。

> 💡 本地所有已准备好的提交都在 `main` 分支上，`git push` 会一次性全部推上去。

---

## 二、首次使用：先配置认证（三选一）

`git push` 需要验证你的 GitHub 身份。**不需要给我 token、不需要改 gist token 的权限**，选一种方式配置一次即可长期使用。

### 方式 A：GitHub CLI 浏览器登录（最省事，推荐 ✅）

只要电脑上装了 GitHub CLI（本机已装），在 Git Bash 里执行：

```bash
gh auth login
```

按提示操作：
1. 选择 **GitHub.com** → 回车
2. 选择 **HTTPS** → 回车
3. 提示 Authenticate Git with your GitHub credentials? 选 **Yes**
4. 选 **Login with a web browser** → 回车 → 复制显示的一次性码 → 回车会自动打开浏览器
5. 在浏览器里粘贴一次性码并授权

完成后执行一次：

```bash
gh auth setup-git
```

以后再 `git push` 就直接用，不需要任何 token。想退出时执行 `gh auth logout`。

> 如果提示 `gh: command not found`，说明终端还没刷新 PATH，重开一个终端窗口，或改用完整路径：
> `"/c/Program Files/GitHub CLI/gh.exe" auth login`

### 方式 B：SSH 密钥（一劳永逸，不碰任何 token）

在 Git Bash 里执行：

```bash
ssh-keygen -t ed25519 -C "3992902334@qq.com"
```

一路回车即可（有旧密钥会问是否覆盖，选 n）。然后：

```bash
cat ~/.ssh/id_ed25519.pub
```

复制输出的整行内容（`ssh-ed25519 AAAA...` 开头），打开
https://github.com/settings/ssh/new ，Title 随便填（如 `my-pc`），把内容粘贴进 Key 框，点 Add SSH key。

最后把仓库 remote 切换成 SSH 地址（只需做一次）：

```bash
cd "C:/Users/29021/WorkBuddy/学习小打卡"
git remote set-url origin git@github.com:trainaozi/study-checkin.git
```

之后 `git push origin main` 就永远不用输任何密码或 token。

### 方式 C：一次性临时 token（不想装任何东西时）

1. 打开 https://github.com/settings/tokens → **Generate new token (classic)**
2. 勾选 **`repo`** 和 **`workflow`**，其余不勾，生成并复制（`ghp_...`）
3. 用这个 token 推一次：

```bash
cd "C:/Users/29021/WorkBuddy/学习小打卡"
git push https://ghp_你的token@github.com/trainaozi/study-checkin.git main
```

4. 推完**立刻回 token 页面把它 Revoke 掉**（只用这一次）

> 你的 gist 同步 token **保持不变**，继续给 App 云同步用，互不影响。

---

## 三、验证是否发布成功

```bash
# 看推送是否成功（显示 main -> main 即成功）
git push origin main

# 或者看 GitHub 上最近的提交
"/c/Program Files/GitHub CLI/gh.exe" run list -R trainaozi/study-checkin
```

网页端：刷新 https://trainaozi.github.io/study-checkin/ ，看到新内容即上线成功。
GitHub 仓库页面 → Actions 标签页也能看到 "Deploy to GitHub Pages" 的运行记录（绿色对勾=成功）。

---

## 四、常见问题

| 现象 | 原因与解决 |
|------|-----------|
| `push` 报 403 / 401 | 凭证没有仓库权限：用方式 A 或 B 重新配置认证，或换方式 C 的临时 token |
| `fatal: not a git repository` | 不在项目目录里：先 `cd "C:/Users/29021/WorkBuddy/学习小打卡"` |
| `branch 'main' set up to track` | 第一次推 `origin/main`，属正常提示，以后直接 `git push` 即可 |
| 推完网站没变化 | 等 1–2 分钟让 Actions 构建；去仓库 Actions 页看是否失败 |
| 手机要更新网站吗？ | 不用。手机只负责使用 App，网站更新只从电脑 push 一次即可 |
| 我改了文件忘了提交 | 先 `git status` 看改动，再按"标准三连"执行 |

---

## 五、这套流程背后的原理（了解即可）

- 本地仓库 `main` 分支存放网站源码（`index.html` = 单文件应用本体）
- 仓库里 `.github/workflows/deploy.yml` 是部署流水线：**每次 push 到 main，GitHub 自动把仓库内容发布到 Pages**
- 所以"更新网站" = "把新代码 push 到 main"，剩下的 GitHub 全自动
