# GitHub Runner

用 Shell / PowerShell 安装和管理 GitHub Actions 自托管 Runner，统一管理命令为 **`ghr`**。自动识别 Linux、macOS、Windows 和 x64 / arm64，每个组织运行一个独立 Runner，由常驻 `service` 管理。

## 一行安装

Linux / macOS，在普通用户终端执行：

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
| Linux | `~/.local/share/github-runner/linux` | systemd 系统服务，以安装用户运行 |
| macOS | `~/.local/share/github-runner/macos` | LaunchDaemon，以安装用户运行 |
| Windows | `C:\ProgramData\local-github-runner\windows` | 计划任务，以 LocalService 运行 |

安装器自动安装或更新 GitHub CLI `gh`（最低 2.62），缺少登录时引导授权，然后下载官方 Actions Runner、校验 SHA-256、配置开机启动。Linux/macOS 缺少 `jq` 时通过系统包管理器或 Homebrew 安装；Linux 同时安装官方 Runner 所需系统依赖。

首次安装需要 GitHub 授权、Unix 的 sudo 权限或 Windows 管理员权限。无交互输入时使用默认安装目录；也可设置 `LOCAL_RUNNER_HOME` 跳过目录询问，安装器会追加平台名。重复安装会保留已有配置、编号和数据。

Linux 需要 systemd、glibc、Bash、curl、tar、util-linux 的 `flock`，不支持 Alpine；macOS 使用系统 Bash 3.2、launchd、`shlock`；Windows 使用 Windows PowerShell 5.1 和任务计划程序。无需 Python 或 C# 服务宿主。

## 管理命令

安装成功后会显示：

```text
ghr status: 获取runner状态
ghr start: 启动runner
ghr stop: 停止runner
ghr restart: 重启runner
ghr logs [-f]: 查询日志，-f是跟踪最新日志
ghr config --dir <PATH>: 设置data和logs的父目录，默认为当前目录，重启后生效（也支持 --dir=<PATH>）
ghr uninstall: 卸载runner
```

- `status`：显示管理进程、本机各组织 Runner 的 GitHub `online/offline/missing`、是否忙碌和本机运行状态。网络或权限失败显示 `unknown`，不会误报离线。
- `start`：启动管理服务并启用开机自动启动。已运行时不会重启，也不会提前应用待生效配置。
- `stop`：关闭自动启动，停止管理服务及各组织的 Runner，保留注册和数据。正在运行的 job 会被中断。
- `restart`：先停止再启动，并应用保存的目录配置。
- `logs`：显示管理日志最后 200 行；`logs -f` 持续跟踪新增日志，日志轮换后继续跟踪，按 Ctrl+C 结束。
- `config --dir <PATH>`：设置数据和日志的父目录，也支持 `config --dir=<PATH>`；`config` 或 `config --dir .` 使用当前目录。路径包含空格时用引号括起。
- `uninstall`：停止进程，注销本机记录的 GitHub Runner，移除系统服务、命令、脚本和配置；所有工作数据与日志保留。GitHub 注销失败时保留凭据和状态，修复网络或权限后再次执行卸载。其他机器的 Runner 不会被删除。

Unix 的入口为 `/usr/local/bin/ghr`，调用安装目录的 `bin/ghr.sh`。Windows 的 `bin/ghr.cmd` 调用 `bin/ghr.ps1`，安装器将其目录加入安装用户的 PATH。若已有终端找不到 `ghr`，重新打开终端；Unix 的 PATH 需要包含 `/usr/local/bin`。Windows 的启停、目录设置和卸载在管理员 PowerShell 中执行。

## 修改数据和日志目录

Linux / macOS：

```sh
ghr config --dir /srv/builds
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

每个平台维护四个职责独立的脚本，没有架构子目录或公共代码目录：

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

仓库创建、改名后的工作目录由官方 Runner 按实际任务创建；旧目录保留。同名仓库按组织隔离。官方 Runner 会在 `data/<组织>/<仓库>/` 下再创建同名 checkout 子目录，并在组织工作目录下维护 `_temp`、`_actions`、`_tool` 等目录。组织改名通过稳定的组织 ID 识别，空闲后更新本地组织目录。

## 权限、更新与开发

默认每 300 秒查询账号的活跃组织成员关系，为有 Runner 管理权限的组织注册；个人账号仓库不在范围内。首次登录申请 `admin:org,repo`；已有凭据缺少权限时执行 `gh auth refresh -h github.com -s admin:org,repo` 并重新安装，启用 SSO 的组织还需授权。Runner 使用默认 Runner Group，安装器不会放宽组织的仓库访问策略。

编辑 `conf/settings.json` 可设置 `organizations` 白名单（默认 `[]`）、`poll_seconds`（默认 300，最低 10）、`restart_seconds`（默认 30，最低 1）。修改后执行 `ghr restart`。

凭据保存在受权限保护的 `conf/github-token`，不会传给构建子进程或写入日志。同一 OS 身份的任务仍能读取本机文件，只应接入可信组织和 workflow。Windows LocalService 不具有管理员权限、交互桌面或个人钥匙串；Java、Docker、Xcode 等构建工具链需自行准备。

再次执行安装命令即可更新，请在没有 job 运行时升级。旧版架构目录、`.state` 和组织程序目录会迁移到新布局，保留注册和数据；存在冲突目录时停止，不覆盖。此前安装的工作数据默认保留原位置，新安装默认使用当前目录。

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
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .test/powershell.ps1
```

测试使用临时目录、假 GitHub API 和系统服务接口，验证注册编号、目录升级、真实子进程恢复、启停、配置生效、日志跟踪和卸载；不安装本机服务，不注册真实 Runner。CI 在 Linux、macOS、Windows 上运行，分别模拟 x64/arm64 配置。真实组织接单、两种原生硬件及系统重启恢复仍需集成验收。
