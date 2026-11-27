# GitHub Runner

用 Shell / PowerShell 安装和管理 GitHub Actions 自托管 Runner，统一管理命令为 **`ghr`**。自动识别 Linux、macOS、Windows 和 x64 / arm64，每个组织运行一个独立 Runner，由常驻 `service` 管理。

## 一行安装

Linux（普通用户或 root）/ macOS（普通用户），执行：

```sh
curl -fsSL https://raw.githubusercontent.com/suminwell/github-runner/main/install.sh | sh
```

Windows，在管理员 PowerShell 执行：

```powershell
irm https://raw.githubusercontent.com/suminwell/github-runner/main/install.ps1 | iex
```

安装时会询问**程序安装目录**，直接回车使用默认值。该目录固定维护 `bin/`、`conf/` 和 `runner/`。首次安装的数据和日志默认保存在**执行安装命令时的当前目录**下的 `data/`、`logs/`。

| 平台 | 默认程序安装目录 | 开机托管 |
| --- | --- | --- |
| Linux 普通用户 | `~/.local/share/github-runner/linux` | systemd 系统服务，以安装用户运行 |
| Linux root | `/opt/github-runner/linux` | systemd 系统服务，以专用普通账户 `ghrunner` 运行 |
| macOS | `~/.local/share/github-runner/macos` | LaunchDaemon，以安装用户运行 |
| Windows | `C:\ProgramData\local-github-runner\windows` | 计划任务，以 LocalService 运行 |

安装器自动安装或更新 GitHub CLI `gh`（最低 2.62），缺少登录时引导授权，然后下载官方 Actions Runner、校验 SHA-256、配置开机启动。下载失败或取消登录后可直接重试，保留首次安装时的数据目录选择。Linux/macOS 缺少 `jq` 时通过系统包管理器或 Homebrew 安装；Linux 同时安装官方 Runner 所需系统依赖。

首次安装需要 GitHub 授权、Unix 普通用户的 sudo 权限或 Windows 管理员权限；Linux root 安装无需 sudo。无交互输入时使用默认安装目录；也可设置 `LOCAL_RUNNER_HOME` 跳过目录询问，安装器会追加平台名。重复安装会保留已有配置、编号和数据。

Linux root 安装自动创建锁定登录的系统账户 `ghrunner`，HOME 为 `/var/lib/github-runner/home`，工作流以该普通账户运行，不授予 sudo 权限。安装、登录 GitHub 和 `ghr` 管理命令仍由 root 执行；普通管理用户使用 `sudo ghr ...`。已有普通用户安装应继续以原用户升级，不会自动转换账户。若机器已有同名的非本项目账户，安装器拒绝复用。

root 安装目录及其父目录必须由 root 拥有，且其他用户不能写入。`bin/` 和 `conf/` 中的脚本、配置和凭据由 root 管理；专用账户只读配置，可写 `runner/`、`bin/.cache/`、`conf/runtime/` 和数据、日志。root 安装额外需要 `runuser`、`useradd` 和 POSIX ACL，缺少 `acl` 时会自动安装。即使从 `/root/...` 执行，数据和日志仍默认放在当前目录；安装器给专用账户添加必要的父目录穿越权限和 `data/logs` 写权限，不开放父目录的列表权限，不递归更改已有文件权限。父目录中本来允许读取的文件，在知道路径后可能变得可访问；建议在 `/srv/builds` 等专用构建目录执行安装。需要 root 自动授权的目录及其父目录也须由 root 管理，防止任务替换路径；专用账户本来就能读写的目录可直接使用。已有数据内部若使用其他账户的私有权限，需自行授权。`ghr config --dir` 同样处理新目录权限，重启后切换。

卸载 root 安装时保留专用账户及 HOME，避免遗留数据和日志变成无主文件；重新安装复用原 UID。账户记录保存在 root 管理的 `/var/lib/github-runner/account.json`，不随 `config --dir` 改变。

符合 [GitHub 官方支持范围](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#linux) 的 Linux（例如 Ubuntu 20.04+、Debian 10+、RHEL/CentOS/Oracle Linux 8+）直接在宿主机运行；新部署建议选择仍在维护的 Ubuntu 24.04、Debian 12 或 RHEL 9。低于这些版本的 glibc 发行版（例如 **CentOS 7**、Ubuntu 18.04）自动改用下面的 **Docker 模式**；Alpine/musl 仍不支持。

安装器在提权、创建账户或停止旧服务之前拒绝不支持的系统。安装依赖后，还会以实际运行账户执行官方 `Runner.Listener --version` 和包内各个 glibc 版 `node --version`，检查 C++、glibc 和运行环境是否真正可用。检查失败时打印完整的版本缺失错误，退出安装并保留配置供修复后重试，不启用新服务；未知发行版也必须通过二进制运行检查。已有旧系统上的失败安装可用 `ghr stop` 停止重试。Linux 管理命令使用兼容 systemd 219 的属性查询和启停方式，供历史安装停止、卸载使用；新安装仍需满足上述系统要求。

Linux 需要 systemd、glibc、Bash、curl、tar、util-linux 的 `flock`，不支持 Alpine；只有 `yum` 的系统（CentOS 7）缺少 `jq` 时，安装器下载固定 SHA-256 的官方静态 jq 1.8.1 到 `bin/tools/`；macOS 使用系统 Bash 3.2、launchd、`shlock`；Windows 使用 Windows PowerShell 5.1 和任务计划程序。无需 Python 或 C# 服务宿主。

## 旧版 Linux：Docker 模式

官方 Runner 基于 .NET 8，并且 Actions 使用 Node 20/24，需要较新的 glibc 和 libstdc++。CentOS 7（glibc 2.17）等旧系统无法直接运行，替换系统库也不能解决。安装器检测到这类系统时自动改用 Docker 模式：

- 宿主机的 systemd 只负责启停一个容器；管理进程、官方 Runner 和所有 job 都在本地构建的 Ubuntu 22.04 镜像 `local-github-runner:<架构>` 中运行，以安装用户或 `ghrunner` 的 UID 运行，不以 root 运行。
- 安装目录、数据目录和 HOME 以**相同路径**挂载进容器，并共享宿主机的进程号空间和网络，所以 `ghr status/stop/logs/config` 等命令用法不变。
- 镜像内带有 git、curl、jq、python3、Docker CLI（含 buildx、compose）等常用工具；宿主机上安装的工具在 job 中不可用。需要更多工具时，可基于 `linux/Dockerfile` 构建自定义镜像，安装时用 `LOCAL_RUNNER_DOCKER_IMAGE=<镜像>` 指定。
- **job 默认可以使用宿主机的 Docker**（`docker build`、`container:` 和 service 容器都可用），因为路径相同，job 里 `docker run -v "$PWD":/src` 也能挂载正确的目录。代价是：能运行 job 的人通过 Docker 套接字可以获得宿主机 root 权限，`ghrunner` 账户隔离在此模式下不再构成安全边界。只应让受信任的仓库使用这台 Runner。

Docker 需要 20.10.10 或更高版本。安装器在改动任何内容之前完成以下检查和确认：

1. 未安装 Docker：从 Docker 官方源自动安装最新的 docker-ce（CentOS 7 上为 26.1.x，Debian/Ubuntu 系使用对应发行版的仓库）。
2. 已安装旧版本 Docker（例如 CentOS 7 自带的 1.13）：说明升级会替换旧软件包并重启 Docker 守护进程，正在运行的容器会停止，旧存储驱动下的镜像可能不再显示，然后询问是否升级。**不同意则终止安装，主机不做任何改动。**
3. CentOS 7 的官方软件源已下线时：询问是否把 `CentOS-*.repo` 备份到 `/etc/yum.repos.d/ghr-backup-<时间>/`，并把基础源指向 CentOS 7.9.2009 归档源（vault）。不同意同样终止安装。
4. 其他旧发行版没有自动安装 Docker 的路径时，提示手动安装 Docker 后重试。

软件源按机器公网 IP 所在地区自动选择：中国大陆使用阿里云的 docker-ce、CentOS vault 和 Ubuntu 镜像源，其他地区使用官方源。也可用 `LOCAL_RUNNER_REGION=cn` 或 `global` 指定。基础镜像先尝试 `ubuntu:22.04`（会使用 Docker 守护进程已配置的 registry-mirrors），在中国大陆还会依次尝试 `docker.m.daocloud.io` 和 `docker.1ms.run` 的镜像；都不可用时，用 `LOCAL_RUNNER_DOCKER_BASE=<可访问的 ubuntu:22.04 镜像>` 指定。job 自己拉取的镜像不受这些设置影响，大陆主机需要自行给 Docker 配置镜像加速。

无交互输入时不会自动同意升级或修改软件源；无人值守安装可设置 `LOCAL_RUNNER_ASSUME_YES=yes`，表示同意上述全部询问。也可以在受支持的系统上设置 `LOCAL_RUNNER_RUNTIME=docker` 主动使用 Docker 模式；之后重复安装会沿用已记录的模式，设置 `LOCAL_RUNNER_RUNTIME=native` 重新安装可切回原生运行（仅限受支持的系统）。WSL 内不支持 Docker 模式。

`ghr status` 的第一个表格会显示 `Runtime  Docker (...)`。`ghr uninstall` 保留 Docker 和镜像，因为同一主机上的其他安装可能还在使用；确认不再需要后自行执行 `docker rmi local-github-runner:<架构>`。

## WSL2 安装与 Windows 未登录时启动

支持 **WSL2 + systemd**，Runner 名称仍为 `local-linux-<架构>-<序号>`。WSL1 不支持。安装器会在申请 sudo、安装依赖和修改服务之前检查运行条件；不会自动覆盖 `/etc/wsl.conf` 或关闭其他 WSL 任务。

先在 Windows 执行 `wsl --update`，在目标发行版的 `/etc/wsl.conf` 中合并以下内容，保留已有配置：

```ini
[boot]
systemd=true
```

保存正在进行的工作后，在 Windows 执行 `wsl --terminate <发行版名称>`，重新打开该发行版，并使用上面的 Linux 一行安装命令。建议把安装目录、`data` 和 `logs` 放在 Linux 文件系统，例如 `/home/你的用户/`；`/mnt/c` 等 Windows 挂载目录的权限语义和构建性能不同。

**systemd 仅负责发行版启动后的 runner 自启，不能保证 Windows 开机启动发行版，也不能单独保持 WSL 存活。**因此安装器会直接从 WSL 调用 Windows PowerShell，自动带入发行版、Linux 用户和安装目录，并在 Windows 本机弹出 UAC 提权及账户密码提示。root 安装时 Windows 任务使用专用 Linux 账户 `ghrunner` 保活，Windows 账户仍是发行版所属的账户；推荐使用默认 `/opt/github-runner/linux`，确保 Windows 可读取桥接脚本。所有 WSL 支持代码都放在 `linux/`；无需进入 `windows/`，也无需另开 PowerShell 手动执行安装命令。

若取消了提示或需要更新任务凭据，在同一个 WSL 发行版内重试：

```sh
ghr wsl setup
```

此步骤使用拥有该发行版的 Windows 账户，输入该 **Windows 账户密码（不是 PIN 或 Linux sudo 密码）**，注册 `LocalGitHubRunner-WSL-<标识>` 计划任务。该账户需要能以自身身份提权完成一次性注册；UAC 若切换成另一个 Windows 账户，脚本会拒绝继续，避免操作错误的发行版。密码通过 COM 接口交给 Windows 任务计划程序管理，不写入 ghr 配置、日志或传到 Linux。任务使用 `Password` 登录方式和普通用户权限，能够在 Windows 重启后、用户尚未登录时运行；开机触发、失败重启和每分钟检查确保恢复，`IgnoreNew` 避免重复启动。前台 `wsl.exe` 进程负责保活，Linux 的 systemd 继续统一管理各组织 runner。

配置完成后仍在 WSL 内使用 `ghr`：`status` 显示 Windows 任务状态，`stop` 禁用该任务并停止 runner，`start`/`restart` 重新启用，`uninstall` 删除本安装拥有的任务。保活进程看到停止标记或安装被删除时自行退出，不调用 `wsl --shutdown`，不停止其他发行版。需要启用 WSL 的 Windows 程序互操作，首次设置时 `powershell.exe` 应在 WSL 的 PATH 中；若关闭了互操作或从缺少互操作环境的 SSH 会话执行，命令会明确报错供重试。

只有 Linux 安装完成、尚未完成 Windows 配合设置时，安装命令会报告未完成，保留 Linux 安装供 `ghr wsl setup` 重试。Windows 密码变更后也使用此命令更新；仅有 PIN、没有可用账户密码，或组织策略禁止批处理登录时，应先处理账户条件。这里的自启不能恢复关机前被中断的 job，也不能让已关机或睡眠的主机继续接活。

**安全边界：**保活依赖 WSL 互操作，而互操作开启时，发行版内任何进程都能启动 `powershell.exe`、`cmd.exe` 等 Windows 程序，并以拥有该发行版的 Windows 账户身份运行，可访问该账户的 Windows 文件、凭据和网络权限。workflow job 也不例外，root 安装的专用账户 `ghrunner` 同样如此；保活任务还会让这一能力在 Windows 用户未登录时持续可用。因此 WSL runner 的隔离程度低于原生 Linux，只应运行受信任仓库的 workflow，并为该 Windows 账户只授予必要权限。WSL 默认追加到 PATH 的 `/mnt/...` Windows 目录不会写入 runner 服务的 PATH，避免 job 误用 Windows 版 `node`、`npm`、`git` 等工具；这只影响命令查找，不构成隔离。

`ghr wsl setup` 更新凭据会保留已有的停止状态。想主动关闭 WSL 时应先执行 `ghr stop`，否则启用中的宿主任务会在下一次检查时重新拉起发行版。

实现依据：[微软 WSL systemd 说明](https://learn.microsoft.com/en-us/windows/wsl/systemd)、[WSL 发行版按 Windows 用户隔离](https://learn.microsoft.com/en-us/windows/wsl/setup/environment)。自动测试覆盖临时文件、模拟任务管理，以及 Windows 上禁用的临时任务的参数回读和真实权限接口，测试后删除任务；不会启动真实 WSL，真实 WSL 无人登录重启仍需在目标 Windows 主机验证。

## 管理命令

安装成功后会显示：

```text
ghr status: 获取runner状态
ghr start: 启动runner
ghr stop: 停止runner
ghr restart: 重启runner
ghr logs [-f]: 查询日志，-f是跟踪最新日志
ghr config --dir [<PATH>]: 设置data和logs的父目录，默认为当前目录，重启后生效（--dir 可简写为 -d）
ghr uninstall: 卸载runner
```

- `status`：显示平台和架构、安装目录、Runner 程序目录、当前数据和日志目录、管理进程状态与 PID，并逐组织显示本机 Runner 在 GitHub 上的 `online/offline/missing/unknown`、是否忙碌、本地进程状态及 PID，最后汇总数量。网络或权限失败显示 `unknown`，不会误报离线。本地 `restarting` 表示组织管理进程仍在，但监听进程尚未启动或正在重启。
- `start`：启动管理服务并启用开机自动启动。已运行时不会重启，也不会提前应用待生效配置。
- `stop`：关闭自动启动，停止管理服务及各组织的 Runner，保留注册和数据。Linux 会核验原生服务已停止；查询或停止失败会显示错误并返回非零退出码。正在运行的 job 会被中断：Linux/macOS 先发送 TERM，等待官方 Runner 取消 job 并上报（最多 `stop_seconds` 秒）后再强制结束；Windows 直接强制结束。
- `restart`：先停止再启动，并应用保存的目录配置。
- `logs`：显示管理日志最后 200 行；`logs -f` 持续跟踪新增日志，日志轮换后继续跟踪，按 Ctrl+C 结束。
- `config --dir <PATH>` 或 `config -d <PATH>`：等价，设置数据和日志的父目录。`config`、`config --dir`、`config -d` 或路径为 `.` 时使用当前目录。路径包含空格时用引号括起；不支持 `--dir=<PATH>` 写法。
- `uninstall`：停止进程，注销本机记录的 GitHub Runner，移除系统服务、命令、脚本和配置；所有工作数据与日志保留。若注册成功后尚未保存组织状态就退出，会从本地官方 `.runner` 元数据补查组织和远端身份。身份无法确认或 GitHub 注销失败时保留凭据和状态，修复后再次执行卸载。其他机器的 Runner 不会被删除。

Unix 的入口为 `/usr/local/bin/ghr`，调用安装目录的 `bin/ghr.sh`。Windows 的 `bin/ghr.cmd` 调用 `bin/ghr.ps1`，安装器将其目录加入安装用户的 PATH。若已有终端找不到 `ghr`，重新打开终端；Unix 的 PATH 需要包含 `/usr/local/bin`。Windows 的启停、目录设置和卸载在管理员 PowerShell 中执行。

`ghr status` 输出示例：

```text
GitHub Runner status

ITEM                       VALUE
Platform                   linux / x64
Manager                    running (PID 4321)
Install directory          /home/user/.local/share/github-runner/linux
Runner directory           /home/user/.local/share/github-runner/linux/runner
Work directory             /srv/builds (active)
Data directory             /srv/builds/data
Logs directory             /srv/builds/logs
Configured work directory  /srv/builds
Configuration              no pending directory change

ORGANIZATION / RUNNER                GITHUB    BUSY  LOCAL       PID
organization-a
├── local-linux-x64-1                online    true  running     4350
├── local-macos-arm64-1              online    false other       -
└── local-windows-x64-1              offline   false other       -
organization-b
└── local-linux-x64-1                offline   false restarting  4360

SUMMARY                    VALUE
Organizations              2
GitHub                     1 online, 1 offline, 0 missing, 0 unknown; 1 busy
Other runners              2 (1 online, 1 offline); 0 busy
Local                      1 running, 1 restarting, 0 stopped/paused

restarting: organization worker is alive; listener is not running yet.
```

修改目录但尚未重启时，会标记 `Configuration: pending` 并列出下次启动使用的数据和日志目录；停止后则标明上次运行的目录。即使尚未注册任何组织，也会保留完整的安装和目录概览。WSL 还会显示 Windows 宿主任务状态。

## 修改数据和日志目录

Linux / macOS：

```sh
ghr config --dir /srv/builds
# 等价写法：ghr config -d /srv/builds
ghr restart
```

Windows：

```powershell
ghr config --dir "D:\Build Workspace"
ghr restart
```

重启后使用：

```text
指定目录/
├── data/
│   └── organization-a/
│       └── repository-one/
│           └── repository-one/  # 官方 checkout / GITHUB_WORKSPACE
└── logs/
    └── service.log
```

配置修改仅保存待生效的目录；当前管理服务及任务继续使用原目录。执行 `restart` 或 `stop` 后再 `start` 才切换，`status` 同时显示配置目录和上次启动使用的目录。旧数据、旧日志保留原位，不自动搬迁。`logs` 在重启前仍读取原目录的日志。

`bin`、`conf`、`runner` 固定在安装目录，不随 `config --dir` 移动。Windows 会给数据和日志目录添加 LocalService 所需权限。

## 源码与运行目录

每个平台维护职责独立的脚本，没有架构子目录或公共代码目录：

```text
install.sh                      # Linux/macOS 统一入口
install.ps1                     # Windows 统一入口
linux/                          # macos 同结构；windows 对应 .ps1
├── install.sh                  # 安装、更新、开机托管
├── service.sh                  # 发现组织、注册、管理各组织进程
├── runner.sh                   # 单个组织的监听与退出重试
└── ghr.sh                      # 用户管理命令
.test/                          # Shell / PowerShell 测试
```

安装后的程序目录：

```text
安装目录/
├── bin/
│   ├── install.sh
│   ├── service.sh
│   ├── runner.sh
│   ├── ghr.sh
│   ├── tools/                  # 按需安装的 gh
│   └── .cache/                 # 官方 Runner 下载缓存
├── conf/
│   ├── settings.json
│   ├── organizations.json
│   ├── github-token
│   └── ...                     # 进程记录及运行状态
└── runner/
    └── organization-a/
        ├── runner.sh           # 本组织的长期运行脚本
        └── app/                # 官方 Runner 程序、凭据及 _diag 日志
```

Windows 使用 `.ps1`，并包含 `bin/ghr.cmd` 和组织目录下的 `listener.ps1`。服务持续维护每个组织的 Runner：进程异常退出会恢复，系统重启后重新上线。Windows 使用开机触发、失败重启和每分钟检查的计划任务，文件锁与 `IgnoreNew` 避免重复启动。系统重启不会恢复已经中断的 job 进度；macOS FileVault 仍需先解锁启动磁盘。

Linux root 安装另有 `bin/account.sh`（来自 `linux/account.sh`），负责专用账户、目录授权和管理命令的权限切换；可写运行状态位于 `conf/runtime/`。普通用户安装保留原有 `conf/` 布局。Linux 安装还包含 `bin/wsl.sh`（来自 `linux/wsl.sh`，保活与命令桥接）和 `bin/wsl.ps1`（来自 `linux/wsl.ps1`，由 WSL 调用以管理 Windows 宿主任务）。普通 Linux 不配置宿主任务时不会调用 Windows 程序。WSL 完成宿主设置后在 `conf/wsl-host.json`（root 安装为 `conf/runtime/wsl-host.json`）保存非敏感任务信息，切换 `data/logs` 不改变此任务。`windows/` 始终只用于原生 Windows Runner 安装。

## Runner 编号与派活

名称为 `local-<OS>-<架构>-<INDEX>`，例如 `local-linux-x64-1`、`local-macos-arm64-2`、`local-windows-x64-1`。序号按组织、OS、架构分别计算：分页查询现有 Runner（包括离线记录），取最大编号加 1，没有则从 1 开始，不填补空缺。同机重复安装、重启保留编号；并发重名会重新查询、递增，不使用 `--replace` 抢占其他机器。

每个 Runner 同时带有完整名称标签和通用架构标签。指定某一台机器：

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

使用 `[self-hosted, local-linux-x64]` 可让组织内任意 Linux x64 Runner 接活。GitHub 按标签及 Runner Group 访问规则分配任务；单个 Runner 同时运行一个 job，不同组织可以同时派活。

仓库创建、改名后的工作目录由官方 Runner 按实际任务创建；旧目录保留。同名仓库按组织隔离。官方 Runner 会在 `data/<组织>/<仓库>/` 下再创建同名 checkout 子目录，并在组织工作目录下维护 `_temp`、`_actions`、`_tool` 等目录。组织改名通过稳定的组织 ID 识别，Runner 空闲后以原编号重新注册，并把 `runner/<旧名>` 程序目录迁到新名字；`data/<旧名>` 工作数据保留原位，新任务使用 `data/<新名>`。

## 权限、更新与开发

默认每 300 秒查询账号的活跃组织成员关系，为有 Runner 管理权限的组织注册；个人账号仓库不在范围内。对没有权限或持续出错的组织按指数退避重试（从 `poll_seconds` 翻倍到最多 1 小时），失败原因（gh 或官方 config 的最后一行错误，已去除凭据）写入 `logs/service.log`。GitHub API 调用限时 120 秒，Runner 注册限时 180 秒，网络卡死不会阻塞管理循环。首次登录申请 `admin:org,repo`；已有凭据缺少权限时执行 `gh auth refresh -h github.com -s admin:org,repo` 并重新安装，启用 SSO 的组织还需授权。Runner 使用默认 Runner Group，安装器不会放宽组织的仓库访问策略。

编辑 `conf/settings.json` 可设置 `organizations` 白名单（默认 `[]`）、`poll_seconds`（默认 300，最低 10）、`restart_seconds`（默认 30，最低 1）、`stop_seconds`（停止时等待 job 取消的秒数，默认 30，范围 1–60，仅 Linux/macOS）。修改后执行 `ghr restart`。

凭据保存在受权限保护的 `conf/github-token`，不会传给构建子进程或写入日志。同一 OS 身份的任务仍能读取本机文件，只应接入可信组织和 workflow。Windows 上 LocalService 对 `bin\` 只读，只能写入 `conf\`、`runner\`、`bin\.cache` 和数据、日志目录，且 `conf\settings.json`、`conf\github-token` 仅可读，防止任务篡改管理员执行的脚本和配置。Windows LocalService 不具有管理员权限、交互桌面或个人钥匙串；Java、Docker、Xcode 等构建工具链需自行准备。

再次执行安装命令即可更新，请在没有 job 运行时升级。通过 `ghr stop` 停止的安装在升级后仍保持停止，使用 `ghr start` 恢复。旧版架构目录、`.state` 和组织程序目录会迁移到新布局，保留注册和数据；存在冲突目录时停止，不覆盖。此前安装的工作数据默认保留原位置，新安装默认使用当前目录。

本地源码安装：

```sh
gh repo clone suminwell/github-runner
cd github-runner
sh install.sh
```

Windows 管理员 PowerShell 执行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。`LOCAL_RUNNER_SOURCE_DIR` 可指定源码目录，`LOCAL_RUNNER_BASE_URL` 可指定固定提交的 raw 地址。

开发验证：

```sh
bash .test/shell.sh
bash .test/wsl.sh
bash .test/install-retry.sh
bash .test/linux-compatibility.sh
bash .test/systemd-control.sh
bash .test/uninstall-recovery.sh
bash .test/status.sh
# 需要 Docker；只在一次性 Linux 容器内创建账户并验证 root 安装
bash .test/root-install.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .test/powershell.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .test/wsl.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .test/install-retry.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .test/uninstall-recovery.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .test/status.ps1
```

测试使用临时目录、假 GitHub API 和系统服务接口，验证注册编号、目录升级、真实子进程恢复、启停、配置生效、日志跟踪和卸载；不安装本机服务，不注册真实 Runner。CI 在 Linux、macOS、Windows 上运行，分别模拟 x64/arm64 配置。root 安装测试在一次性 Debian 容器内使用真实 UID、ACL 和进程，模拟 GitHub、官方 Runner 下载内容及 systemd 接口，覆盖中断重试、普通账户接活、配置保护、启停、重装和卸载。真实组织接单、两种原生硬件及系统重启恢复仍需集成验收。
