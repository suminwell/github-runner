# GitHub Runner

使用系统自带的 **Shell / PowerShell** 安装和维护 GitHub Actions Runner。项目不需要 Python、C# 服务宿主，也没有跨平台公共代码目录。

每个平台只提供一套安装和管理脚本，自动识别 x64 / arm64，为当前 GitHub 账号可管理的组织注册 Runner。名称格式为 `local-<OS>-<架构>-<INDEX>`，序号从 1 开始：

| 平台 | x64 名称示例 | arm64 名称示例 |
| --- | --- | --- |
| Linux | `local-linux-x64-1` | `local-linux-arm64-1` |
| macOS | `local-macos-x64-1` | `local-macos-arm64-1` |
| Windows | `local-windows-x64-1` | `local-windows-arm64-1` |

编号按组织、OS、架构分别计算。首次注册时分页读取组织的全部 Runner，包括离线 Runner；相同前缀的最大序号加 1，没有则使用 1。例如已有 `local-linux-x64-1`、`local-linux-x64-3`，下一台注册为 `local-linux-x64-4`，不补空缺。安装器启动服务后完成组织查询和注册。

编号保存到本机状态中，重复安装、服务重启、系统重启均复用已有编号。每个 Runner 同时带有完整名称标签和不带序号的架构标签，例如 `local-linux-x64-1` 与 `local-linux-x64`。

## 一行安装

Linux / macOS，使用普通用户终端，入口自动识别操作系统和架构：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/install.sh | sh
```

Windows，以管理员身份打开 Windows PowerShell：

```powershell
irm https://raw.githubusercontent.com/suminwell/github-runner/main/install.ps1 | iex
```

同一个安装地址支持两种架构，无需选择架构目录。macOS 在 Rosetta 环境下也会识别原生 ARM64；下载的 GitHub CLI 和 Actions Runner 与本机架构匹配。

已克隆项目时，在项目根目录执行 `sh install.sh`；Windows 管理员 PowerShell 执行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。入口会使用本地源码。原有的 `linux/install.sh`、`macos/install.sh`、`windows/install.ps1` 地址仍可直接使用。

执行后自动完成：

1. 检查 GitHub CLI `gh`，缺少或低于 2.62 时下载官方版本并校验 SHA-256。macOS/Linux 还需要 `jq`，缺少时通过系统包管理器或 Homebrew 安装。
2. 检查 GitHub 登录，未登录则引导浏览器授权；首次授权会申请 `admin:org,repo`。
3. 下载并校验官方 Actions Runner；Linux 执行官方脚本安装 .NET 所需系统库。
4. 配置开机启动和退出恢复，开始发现组织、注册 Runner。

首次安装仍需要 GitHub 授权、Unix 的 sudo 密码或 Windows 管理员权限。完成后可以关闭终端。

Linux 需要使用 systemd 的现代 glibc 发行版，例如 Ubuntu 22.04+、Debian 12+，以及 Bash、curl、tar、util-linux 的 `flock`；不支持 Alpine。macOS 使用系统 Bash 3.2、launchd 和 `shlock`。Windows 使用系统 Windows PowerShell 5.1、任务计划程序。项目自身不要求安装其他语言运行时。

## 目录与工作数据

```text
install.sh                     # Linux / macOS 统一安装入口
install.ps1                    # Windows 统一安装入口
linux/
├── install.sh
└── service.sh
macos/                         # 同样的 Shell 结构
windows/                       # 对应 install.ps1、service.ps1
.test/                         # Shell / PowerShell 开发测试
```

各平台的 `install.sh` / `install.ps1` 包含完整安装流程，`service.sh` / `service.ps1` 包含完整管理逻辑。没有架构子目录，也不依赖其他平台的代码。

默认安装目录：

| 平台 | 目录 | 开机托管 |
| --- | --- | --- |
| Linux | `~/.local/share/github-runner/linux` | systemd 系统服务，以安装用户运行 |
| macOS | `~/.local/share/github-runner/macos` | LaunchDaemon，以安装用户运行 |
| Windows | `C:\ProgramData\local-github-runner\windows` | 开机计划任务，以 LocalService 运行 |

运行后，以 Linux x64 为例：

```text
linux/
├── install.sh
├── service.sh
├── bin/
│   └── organization-a/
│       ├── runner.sh           # 长期运行，负责 Runner 退出后的重启
│       └── runner/             # 官方程序、配置及 _diag 日志
├── data/
│   └── organization-a/
│       └── repository-one/
│           └── repository-one/ # 官方默认 checkout / GITHUB_WORKSPACE
├── logs/service.log
└── .state/                    # 访问凭据、配置、注册状态及下载缓存
```

数据归属路径为 `<平台>/data/<组织>/<仓库>/`。官方 Runner 默认在其中再创建同名 checkout 子目录，另外管理组织工作目录下的 `_temp`、`_actions`、`_tool` 等目录。

仓库创建、改名和工作区创建由官方 Runner 根据实际任务处理。改名后使用新目录，旧数据保留。组织改名通过稳定的组织 ID 识别；Runner 空闲后重新注册到新路径，正在执行任务时推迟处理。不同组织的同名仓库分别存放，不会共用工作目录。

## 仓库如何派活

```yaml
name: Local build
on: workflow_dispatch
jobs:
  build:
    runs-on: [self-hosted, local-linux-x64-1]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Build on my local runner"
```

上例指定组织内的 Linux x64 第 1 台机器。改成 `runs-on: [self-hosted, local-linux-x64]`，则允许该组织内任意一台 Linux x64 Runner 接活。GitHub 按标签及 Runner Group 的访问规则分配任务，不能按 Runner 名称直接派活，所以脚本同时设置对应标签。

每台机器为每个组织注册一个 Runner，多台相同 OS / 架构的机器用序号区分。单个 Runner 同时执行一个 job，不同组织可以同时派活。Java、Docker、Node.js、Xcode、Android SDK 等项目工具链需要按构建需求准备。

## 自动发现与恢复

- 默认每 300 秒分页查询当前账号的活跃组织成员关系，为有 Runner 管理权限的组织注册或恢复 Runner。个人账号名下仓库不在范围内。
- 组织所有者或获得相应授权的角色才能注册。已有登录缺少权限时，执行 `gh auth refresh -h github.com -s admin:org,repo` 后重新安装；启用 SSO 的组织还需为凭据授权。
- 新 Runner 使用默认 Runner Group。仓库是否有权使用它，尤其公开仓库，仍由组织的访问策略决定；安装器不会自动放宽策略。
- 同一组织内不同 OS、架构独立编号。多台机器同时安装遇到重名时，重新读取组织列表并递增，最多尝试 5 次，之后留待下一轮重试；不会使用 `--replace` 抢占其他机器。
- 本机注册被远程删除或本地配置丢失时，优先恢复本机保存的编号；该编号已被其他机器占用时，再取当前最大序号加 1。旧版无序号注册在空闲时更新为带序号名称。
- 发现失败或断网时保留已有注册和工作数据。失去成员关系后停止对应进程，保留本地目录。
- 每个组织的 Runner 启动脚本独立运行，默认退出 30 秒后重启；主服务检查并恢复这些脚本。GitHub API 查询期间，已启动的脚本仍能重启自己的 Runner。
- Linux/macOS 由系统恢复主服务。Windows 使用开机触发、失败重启和每分钟检查的计划任务，`IgnoreNew` 和文件锁保证单实例。它托管常驻 `service.ps1`，不需要编译服务宿主。
- 重启时读取保存的注册状态；对残留子进程同时校验 PID 和进程启动时间再清理，避免误杀复用 PID 的无关进程。

系统重启不能恢复被中断的 job 进度。macOS 开启 FileVault 后仍需先解锁启动磁盘；WSL 发行版需要启用并实际启动 systemd。Windows LocalService 没有管理员权限、交互桌面、个人映射盘或个人钥匙串环境。

## 状态、日志和配置

以下 Linux/Windows 示例使用 x64，macOS 示例使用 arm64，请按本机架构替换。

```sh
# Linux
sudo systemctl status "local-github-runner-$(id -u)-x64.service"
bash ~/.local/share/github-runner/linux/service.sh status
tail -f ~/.local/share/github-runner/linux/logs/service.log

# macOS
sudo launchctl print "system/com.suminwell.github-runner.$(id -u).arm64"
bash ~/.local/share/github-runner/macos/service.sh status
```

```powershell
# Windows，管理员 PowerShell
Get-ScheduledTask LocalGitHubRunner-x64
Get-ScheduledTaskInfo LocalGitHubRunner-x64
& "$env:ProgramData\local-github-runner\windows\service.ps1" -Mode Status
Get-Content "$env:ProgramData\local-github-runner\windows\logs\service.log" -Encoding UTF8 -Wait
```

`status` 查询 GitHub 返回的真实 `online`、`offline`、`busy` 状态。服务启动不等于 Runner 已成功注册。详细 Runner 日志位于 `bin/<组织>/runner/_diag/`；管理日志按 5 MiB 轮换，保留三份历史。

编辑 `<平台>/.state/settings.json` 可设置：

- `organizations`：组织白名单，例如 `["ceenware","ceenads"]`，默认 `[]` 表示不筛选。
- `poll_seconds`：组织发现间隔，默认 300，最低 10 秒。
- `restart_seconds`：Runner 重试间隔，默认 30，最低 1 秒。

更改配置后重启主服务或计划任务。

为支持无交互开机，凭据保存在 `.state/github-token`。Unix 使用受限文件权限，Windows ACL 仅允许安装用户、管理员、SYSTEM 和 LocalService。管理凭据不传入构建子进程的环境变量，也不写入日志；同一 OS 身份的任务仍能读取本机文件，因此只应接入可信组织和可信 workflow。

## 更新、私有源码与停止

再次执行安装命令会更新脚本和保存的凭据，保留组织状态、编号及 `data`。请在没有 job 运行时升级，因为停止旧服务会中断任务。

上一版 `<平台>/<架构>/` 布局会自动迁移到 `<平台>/`：停止属于本安装的服务或计划任务，移动数据和状态，再重新配置 Runner 的工作路径。已有带序号的注册保留编号，无序号的旧注册转换为新名称。通用架构标签保持兼容。若新旧目录同时存在，或发现其他架构的旧安装，安装器停止并提示处理，不合并或覆盖数据。更早版本的安装应先停用其旧服务并备份，再处理目录迁移。

安装根目录可用 `LOCAL_RUNNER_HOME` 指定，安装器会追加 `<平台>`：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/install.sh | LOCAL_RUNNER_HOME=/srv/github-runner sh
```

私有 fork 需要先通过 `gh auth login` 登录并克隆，然后执行根目录的入口，本地源码会自动传给平台安装器。例如 Linux / macOS：

```sh
gh repo clone suminwell/github-runner && cd github-runner && sh install.sh
```

Windows 管理员 PowerShell 在项目根目录执行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。也可用 `LOCAL_RUNNER_SOURCE_DIR` 明确指定源码目录；`LOCAL_RUNNER_BASE_URL` 可设为固定提交的 raw URL，固定下载版本。设置后，入口和平台安装器都使用指定来源。

停用自动启动并停止管理进程：

```sh
# Linux
sudo systemctl disable --now "local-github-runner-$(id -u)-x64.service"
# macOS
sudo launchctl bootout "system/com.suminwell.github-runner.$(id -u).arm64"
sudo launchctl disable "system/com.suminwell.github-runner.$(id -u).arm64"
```

```powershell
# Windows
Disable-ScheduledTask LocalGitHubRunner-x64
Stop-ScheduledTask LocalGitHubRunner-x64
& "$env:ProgramData\local-github-runner\windows\service.ps1" -Mode Stop
```

Windows 的 `-Mode Stop` 会在确认主进程已停止后，按保存的 PID 和启动时间清理本安装的残留子进程。关闭本机服务不会删除 GitHub 上的注册记录，可在组织 Settings → Actions → Runners 中移除。

## 开发验证

```sh
bash .test/shell.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .test/powershell.ps1
```

测试使用临时目录和假 GitHub API，对同一套脚本分别模拟 x64、arm64，验证编号分配、分页、并发冲突重试、改名、状态恢复、目录迁移、参数传递和真实子进程重启，不注册真实 Runner、不安装本机服务。CI 分别运行 Linux、macOS、Windows 的测试；模拟架构测试不等于两种原生硬件均已验收。

真实组织权限、workflow 接活及系统重启恢复仍需在对应机器进行集成验收。
