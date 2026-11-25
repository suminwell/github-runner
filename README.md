# GitHub Runner

在 macOS、Windows、Linux 本机安装一个开机自启的管理服务。服务自动发现当前 GitHub 账号加入的组织，为有管理权限的组织创建并维护 Runner，供该组织的仓库执行 GitHub Actions。

每个平台都分为 `x64` 和 `arm64` 两个目录，Runner 名称和自定义标签统一为 `local-<OS>-<架构>`：

| 平台 | x64 | arm64 |
| --- | --- | --- |
| macOS | `local-macos-x64` | `local-macos-arm64` |
| Windows | `local-windows-x64` | `local-windows-arm64` |
| Linux | `local-linux-x64` | `local-linux-arm64` |

每个组织独立注册、独立运行；不同组织可以同时派活。

## 一行安装

本仓库已公开，以下通用入口从 `main` 下载并安装，自动检测本机原生架构，选择对应的 `<平台>/<架构>/` 目录。使用私有 fork 时请参考下一节；未认证访问私有仓库会返回 404。

Linux（普通用户终端）：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/linux/install.sh | sh
```

macOS（普通用户终端）：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/macos/install.sh | sh
```

Windows（**以管理员身份打开 Windows PowerShell**）：

```powershell
irm https://raw.githubusercontent.com/suminwell/github-runner/main/windows/install.ps1 | iex
```

也可以直接选择架构入口。例如 Linux：

```sh
# x64
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/linux/x64/bin/install.sh | sh
# ARM64
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/linux/arm64/bin/install.sh | sh
```

macOS 对应 `macos/x64/bin/install.sh` 和 `macos/arm64/bin/install.sh`；Windows 对应 `windows/x64/bin/install.ps1` 和 `windows/arm64/bin/install.ps1`。指定架构与本机不匹配时，安装器会停止并提示，不会安装错误架构的 Runner。

执行一次安装命令后，脚本会：

1. 准备 Python 运行环境，检查 `gh`；缺少或版本低于 2.62 时下载官方 GitHub CLI，并校验发布资产的 SHA-256。
2. 检查 GitHub 登录状态；未登录时引导浏览器授权，申请组织 Runner 所需权限。
3. 下载并校验官方 Actions Runner，Linux 另执行官方依赖安装脚本。
4. 安装系统后台服务，设置开机自启和异常退出恢复。
5. 启动组织发现，为可管理的组织注册 Runner，并生成各组织的启动脚本。

“一行安装”仍包含必要的交互：首次 GitHub 登录、macOS/Linux 的 `sudo` 密码。安装完成后可以关闭终端，后台服务继续运行。

支持 x64 / ARM64。Linux 需要使用 systemd 的现代 glibc 发行版（如 Ubuntu 22.04+、Debian 12+），不支持 Alpine；WSL 需要启用 systemd，且 Windows 启动后还需要实际启动该 WSL 发行版。macOS 建议 13+；Windows 建议 Windows 10/11 或 Server 2019+。缺少 Python 时，Unix 安装器会使用系统包管理器或 Homebrew；Windows 使用独立的官方 Python 嵌入式运行时，不修改系统 Python。

## 私有仓库安装

私有仓库不能用未认证的 `curl` 直接取得安装脚本。先安装 [GitHub CLI](https://cli.github.com/)，执行 `gh auth login`，登录具有本仓库读取权限的账号，然后执行：

Linux：

```sh
gh repo clone suminwell/github-runner && cd github-runner && LOCAL_RUNNER_SOURCE_DIR="$PWD" sh linux/install.sh
```

macOS：

```sh
gh repo clone suminwell/github-runner && cd github-runner && LOCAL_RUNNER_SOURCE_DIR="$PWD" sh macos/install.sh
```

Windows（管理员 PowerShell）：

```powershell
gh repo clone suminwell/github-runner; if ($LASTEXITCODE -eq 0) { Set-Location github-runner; $env:LOCAL_RUNNER_SOURCE_DIR = (Get-Location).Path; & powershell -NoProfile -ExecutionPolicy Bypass -File windows/install.ps1 }
```

已克隆源码时，直接在项目根目录设置 `LOCAL_RUNNER_SOURCE_DIR` 并运行对应安装脚本即可。

## 目录结构

源码中的 `common/` 保存共用管理逻辑；每个平台的两个架构目录都包含安装和服务脚本：

```text
macos/
├── install.sh              # 自动识别架构的通用入口
├── x64/bin/{install,service}.sh
└── arm64/bin/{install,service}.sh
windows/
├── install.ps1
├── x64/bin/{install,service}.ps1
└── arm64/bin/{install,service}.ps1
linux/
├── install.sh
├── x64/bin/{install,service}.sh
└── arm64/bin/{install,service}.sh
```

安装后的程序、数据、日志、凭据和包缓存均保存在 `<平台>/<架构>/` 下，无需保留源码目录。

默认安装位置：

| 平台 | 安装目录 | 系统托管方式 |
| --- | --- | --- |
| Linux | `~/.local/share/github-runner/linux/<架构>` | systemd 系统服务，以安装用户运行 |
| macOS | `~/.local/share/github-runner/macos/<架构>` | LaunchDaemon，以安装用户运行 |
| Windows | `C:\ProgramData\local-github-runner\windows\<架构>` | Windows Service，以 LocalService 运行 |

以 Linux x64 为例，运行后目录类似：

```text
linux/x64/
├── bin/
│   ├── install.sh
│   ├── service.sh
│   ├── manager.py
│   ├── install_service.py
│   ├── organization-a/
│   │   ├── runner.sh
│   │   └── runner/             # 官方 Runner 程序、配置和 _diag 日志
│   └── organization-b/
│       ├── runner.sh
│       └── runner/
├── data/
│   ├── organization-a/
│   │   ├── repository-one/
│   │   │   └── repository-one/ # 默认 GITHUB_WORKSPACE / checkout 路径
│   │   └── repository-two/
│   │       └── repository-two/
│   └── organization-b/
│       └── repository-one/
│           └── repository-one/
├── logs/
│   └── service.log
└── .state/                     # 凭据、配置、包缓存和服务状态
```

macOS 同样使用 `service.sh` / `runner.sh`；Windows 使用 `service.ps1` / `runner.ps1`，另有一个与 Windows 服务管理器通信的服务宿主程序。

仓库数据的完整归属目录为 `<平台>/<架构>/data/<组织名称>/<仓库名称>/`，例如 `linux/arm64/data/ceenware/example/`。官方 Runner 默认会在其下再创建一个同名 checkout 子目录；这是 GitHub 的标准工作区结构，不需要修改 workflow。`_temp`、`_actions`、`_tool` 等内部目录由 Runner 在组织工作目录内管理。

仓库改名后，下一次任务使用当前仓库名自动创建新目录，旧目录保留。仓库创建、改名和 checkout 目录分配由官方 Runner 根据实际任务处理，不需要提前轮询或克隆每个仓库。组织改名通过稳定的组织 ID 识别，空闲后重新配置到新路径；繁忙时延后处理。旧目录不自动迁移或删除。

## 仓库如何派活

在组织仓库的 `.github/workflows/build.yml` 中使用标签：

```yaml
name: Local build
on: workflow_dispatch
jobs:
  build:
    runs-on: [self-hosted, local-linux-x64]
    steps:
      - uses: actions/checkout@v4
      - run: pwd
      - run: echo "Build on my local Linux machine"
```

根据实际机器架构选择上表中的标签，例如 Apple Silicon macOS 使用 `runs-on: [self-hosted, local-macos-arm64]`，x64 Windows 使用 `runs-on: [self-hosted, local-windows-x64]`。GitHub 根据标签和 Runner Group 的仓库访问规则分配任务，不能直接根据 Runner 名称派活。

安装器不准备项目自身的编译工具链。Java、Docker、Node.js、Xcode、Android SDK 等按项目需要安装。每个组织的每个 OS / 架构组合有独立 Runner，单个 Runner 同时执行一个 job；不同组织或架构的 Runner 可同时执行，要预留机器资源。

## 组织与权限

- 服务每 300 秒通过 GitHub API 分页发现当前账号的活跃组织成员关系，再尝试注册或恢复 Runner。仅有成员身份并不代表可以管理 Runner；组织所有者或具有相应权限的角色才可成功注册。
- 新登录默认申请 `admin:org` 和 `repo`。已有登录若权限不足，可执行 `gh auth refresh -h github.com -s admin:org,repo` 后重新运行安装器。使用 PAT 时，需要能管理组织 self-hosted runners 的权限；组织若启用 SSO，还需要为凭据授权。
- 新 Runner 使用组织默认 Runner Group。新仓库能否使用它取决于该 Group 的访问策略。公开仓库通常需要组织管理员显式允许，本项目不会自动放宽此设置。
- 默认自动发现全部可见组织；个人账号名下的仓库不在接入范围内。只接入指定组织时，编辑 `<平台>/<架构>/.state/settings.json` 的 `organizations`，例如 `["ceenware", "ceenads"]`，然后重启服务。空数组表示不筛选。
- 同一组织的每种 OS / 架构组合维护一个固定名称。x64 与 arm64 的 Runner 可以同时注册，不会互相占用名称。本项目不会用 `--replace` 抢占另一台机器的同名 Runner；发生冲突时，在 GitHub 确认并移除不用的旧 Runner 后，服务会自动重试。
- 暂时断网、API 限流或无权限会记录日志并在下一轮重试，不会因此清空本地工作数据。失去组织成员关系后会停止该组织本机进程并保留目录。

## 常驻与重启恢复

系统启动 → 对应架构的系统服务启动 `<平台>/<架构>/bin/service.sh` / `service.ps1` → 管理进程读取该架构的持久化状态并发现组织 → 启动每个 `bin/<组织>/runner.sh` / `runner.ps1`。

系统服务名也包含架构：Linux 为 `local-github-runner-<UID>-<架构>.service`，macOS 为 `com.suminwell.github-runner.<UID>.<架构>`，Windows 为 `LocalGitHubRunner-<架构>`。

管理服务异常退出由系统恢复。组织 Runner 退出后由管理服务重新启动，重试间隔至少 30 秒，避免错误状态下持续刷进程。组织发现使用独立线程，网络请求不会阻塞本地 Runner 的退出检测。官方 Runner 自更新仍由其标准启动脚本处理。

开机服务不依赖用户先登录桌面。macOS 开启 FileVault 时，需要先解锁启动磁盘；工作目录所在磁盘也需要可用。系统断电或重启时正在运行的 job 仍可能失败，服务恢复不等于恢复 job 执行进度。

Unix 服务以安装用户身份执行；Windows 的 LocalService 没有管理员权限或你的交互桌面环境。依赖特定用户会话、钥匙串或网络映射盘的构建需要另行配置。

## 查看状态与日志

以下 Linux / Windows 示例使用 x64，macOS 示例使用 arm64。请按本机架构替换路径和服务名中的 `x64` / `arm64`。

Linux：

```sh
sudo systemctl status "local-github-runner-$(id -u)-x64.service"
~/.local/share/github-runner/linux/x64/bin/service.sh status
tail -f ~/.local/share/github-runner/linux/x64/logs/service.log
```

macOS：

```sh
sudo launchctl print "system/com.suminwell.github-runner.$(id -u).arm64"
~/.local/share/github-runner/macos/arm64/bin/service.sh status
tail -f ~/.local/share/github-runner/macos/arm64/logs/service.log
```

Windows（管理员 PowerShell）：

```powershell
Get-Service LocalGitHubRunner-x64
& "$env:ProgramData\local-github-runner\windows\x64\bin\service.ps1" status
Get-Content "$env:ProgramData\local-github-runner\windows\x64\logs\service.log" -Wait
```

`status` 查询 GitHub 实际返回的 `online` / `offline` 和 `busy` 状态；系统服务已启动不代表组织已成功注册。详细 Runner 日志在 `bin/<组织>/runner/_diag/`。管理日志按 5 MiB 轮换，保留三份历史。

安装器为无交互的开机服务保存一份 GitHub 凭据到 `.state/github-token`。Unix 目录权限为 700、文件为 600；Windows ACL 只允许安装用户、管理员、SYSTEM 和 LocalService。凭据不放在仓库、启动参数或任务进程环境变量中。**同一 OS 身份运行的任务仍有能力读取本机文件，因此只能接入可信组织和可信 workflow，不能把此部署作为不可信代码的隔离沙箱。**

## 升级、配置与停止

再次运行安装命令会更新管理程序、刷新保存的 GitHub 凭据并重启服务，保留组织状态和 `data`。请在没有任务运行时升级，重启可能中断任务。

如果已经安装过没有架构目录的旧版，请先停止旧服务，然后执行新的安装命令。新版会在架构目录内独立注册 `local-<OS>-<架构>`，不会移动旧的凭据、注册状态或 `data`；旧数据保留。确认旧任务结束后，可在 GitHub 删除不再使用的 `local-<OS>`，并把 workflow 的标签改成新名称。

旧版服务的停止方式（仅用于升级旧版）：

```sh
# Linux 旧版
sudo systemctl disable --now "local-github-runner-$(id -u).service"
# macOS 旧版
sudo launchctl bootout "system/com.suminwell.github-runner.$(id -u)"
sudo launchctl disable "system/com.suminwell.github-runner.$(id -u)"
```

```powershell
# Windows 旧版，管理员 PowerShell
Stop-Service LocalGitHubRunner
Set-Service LocalGitHubRunner -StartupType Disabled
```

自定义安装位置可以在执行安装命令前设置 `LOCAL_RUNNER_HOME`；安装器会在该目录下再创建 `<平台>/<架构>` 目录。例如 Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/linux/install.sh | LOCAL_RUNNER_HOME=/srv/github-runner sh
```

该目录需要安装用户可写。`LOCAL_RUNNER_BASE_URL` 可指定固定提交的 raw URL，实现固定版本安装；`LOCAL_RUNNER_SOURCE_DIR` 可指定已克隆源码的绝对路径。`settings.json` 的 `poll_seconds` 可调整组织发现周期（最低 10 秒）。更改配置后重启系统服务。

停止并关闭自动启动（保留程序、凭据和工作数据）：

```sh
# Linux
sudo systemctl disable --now "local-github-runner-$(id -u)-x64.service"

# macOS
sudo launchctl bootout "system/com.suminwell.github-runner.$(id -u).arm64"
sudo launchctl disable "system/com.suminwell.github-runner.$(id -u).arm64"
```

```powershell
# Windows，管理员 PowerShell
Stop-Service LocalGitHubRunner-x64
Set-Service LocalGitHubRunner-x64 -StartupType Disabled
```

关闭服务不会自动删除 GitHub 上的 Runner 注册记录，需要时可在组织 Settings → Actions → Runners 移除。需要恢复服务时重新执行安装器。

## 开发验证

```sh
python3 -m unittest discover -s tests -v
```

测试使用假的 GitHub API 和临时目录，验证实际管理逻辑与子进程恢复，不注册真实 Runner、不安装本机服务。CI 在 Linux、macOS、Windows 上执行这些测试，并检查 Shell / PowerShell 语法和 Windows 服务宿主编译。

真实账号权限、三平台系统重启、Runner 在线状态以及实际 workflow 的 checkout 路径需要在对应环境进行集成验收，不能仅凭单元测试或服务启动判定通过。

实现依据：[GitHub self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)、[组织 Runner API](https://docs.github.com/en/rest/actions/self-hosted-runners)、[Runner 工作区分配源码](https://github.com/actions/runner/blob/main/src/Runner.Worker/TrackingConfig.cs)。
