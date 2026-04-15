# LVS-DR + Keepalived 裸机 x86 部署指南

本项目提供一套可直接部署到 x86 Linux 宿主机的 `LVS-DR + Keepalived` 高可用负载均衡方案，默认按两台 LB 节点组织：`lb1` 和 `lb2`。

整体设计保持不变：
- `keepalived/lb1/keepalived.conf`、`keepalived/lb2/keepalived.conf` 负责 VRRP 和 VIP 漂移，并原生加载 `virtual_server.conf`
- `keepalived/virtual_server.conf` 描述 IPVS 虚拟服务、Real Server 和 `TCP_CHECK`
- `Keepalived` 直接负责下发 IPVS 规则和执行后端健康检查

## 架构说明

- `lb1`：默认主节点，优先级更高
- `lb2`：默认备节点
- `Real Server`：你自己的物理机或虚拟机，需自行完成 LVS-DR 所需配置，例如在 `lo` 上绑定 `VIP/32`，并设置 `arp_ignore` / `arp_announce`

当前仓库没有现成的 `lb3` 配置。如果你需要三节点，可以在 `keepalived/lb2/keepalived.conf` 基础上复制出 `lb3` 并调整 `router_id`、`state`、`priority`。

## 目录说明

- `keepalived/`：VRRP 和虚拟服务配置
- `lb/`：节点身份识别 HTTP 应答脚本
- `scripts/`：裸机部署新增脚本
- `packaging/centos-offline/`：CentOS / RHEL 系离线打包和安装脚本
- `docs/centos-offline-install.md`：CentOS 完全离线安装说明
- `docs/script-reference-and-reload.md`：脚本用途与配置热更新说明
- `lvs-router.env.example`：宿主机环境变量示例文件

项目安装根目录在安装时输入，默认是 `/opt/lvs-router`。下文中的路径示例都以默认值为例：

- `/opt/lvs-router/bin`：项目脚本
- `/opt/lvs-router/keepalived`：Keepalived 与虚拟服务配置
- `/opt/lvs-router/lvs-router.env`：环境变量文件
- `/opt/lvs-router/logs`：统一日志目录
- `/opt/lvs-router/run`：项目运行时状态目录

## 依赖要求

目标机器需要具备以下软件：

- `keepalived`：实现 VRRP 协议，负责 VIP 漂移、主备选举和后端服务器健康检查
- `iproute2`：Linux 网络配置工具集（提供 `ip` 命令），用于管理网络接口和 IP 地址
- `ipvsadm`：IPVS 规则管理工具，用于创建和维护 LVS 负载均衡转发规则
- `socat`：多功能网络工具，在本项目中用于启动健康检查 HTTP 服务
- `modprobe`（kmod 包）：内核模块管理工具，用于加载 IPVS 相关内核模块

同时需要内核支持 IPVS，常见需要加载的模块包括：

- `ip_vs`：IPVS 核心模块
- `ip_vs_rr`：轮询调度算法模块
- `ip_vs_wrr`：加权轮询调度算法模块
- `ip_vs_sh`：源地址哈希调度算法模块

## 部署前配置

先修改以下配置文件，并同步到所有 LB 节点。

### 1. 修改 VRRP 配置

检查：

- `keepalived/lb1/keepalived.conf`
- `keepalived/lb2/keepalived.conf`

重点确认：

- `interface` 是否为实际网卡名，例如 `ens18`
- `virtual_ipaddress` 是否为你的业务 VIP
- `router_id` 是否唯一
- `priority` 是否符合主备顺序
- 主配置末尾是否保留 `include /opt/lvs-router/keepalived/virtual_server.conf`

### 2. 修改虚拟服务配置

编辑 `keepalived/virtual_server.conf`：

- `virtual_server <VIP> <PORT>` 改成实际业务 VIP 和端口
- `lb_algo` 选择调度算法
- `lb_kind` 选择转发模式，当前默认是 `DR`
- `real_server` 列表改成真实 RS 地址和端口

警告：如果你的拓扑是“LB 节点自己同时也是 `real_server`”，不要继续使用 `lb_algo rr`。
在这种情况下，`rr` 可能把请求轮到另一台同样也在运行 Keepalived/IPVS 的 LB 上，形成递归转发，表现为间歇性失败或按固定节奏失败。
当前模板默认改为 `lb_algo sh`，用源地址哈希降低这种递归转发风险；但更稳妥的拓扑仍然是让 LB 和真实 RS 分离。

### 3. 选择本机角色

每台 LB 节点都需要一份环境文件，安装后固定放在安装目录下的 `lvs-router.env`。可以从仓库中的 `lvs-router.env.example` 复制生成。
`start.sh`、`stop.sh`、`status.sh`、`restart.sh` 会自动读取这份文件。

`lb1` 示例：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb1/keepalived.conf
HEALTHY_HTTP_PORT=45555
ROUTER_HTTP_DOCROOT=/opt/lvs-router/run/router-http
IPVS_MODULES="ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh"
```

`lb2` 只需要把 `KEEPALIVED_CONF` 改成：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb2/keepalived.conf
```

## 裸机安装步骤

以下步骤需要在每台 LB 宿主机上执行。

### 1. 安装系统依赖

按你的发行版安装所需软件包。示例：

Ubuntu / Debian：

```bash
sudo apt update
sudo apt install -y keepalived iproute2 ipvsadm socat kmod
```

CentOS / Rocky / AlmaLinux：

```bash
sudo dnf install -y keepalived iproute ipvsadm socat kmod
```

### 2. 复制项目文件

把整个项目目录复制到目标 LB 机器，例如 `/root/lvs-router-src`。

### 3. 安装脚本和配置

在项目目录执行：

```bash
chmod +x scripts/*.sh lb/*.sh
sudo ./scripts/install-host-assets.sh
```

安装脚本会提示输入安装目录；直接回车时默认使用 `/opt/lvs-router`。
随后会自动扫描 `keepalived/` 下现有的 `lb*` 配置目录，并提示选择当前机器的 LB 角色。
例如输入 `1` 表示 `lb1`，输入 `2` 表示 `lb2`；如果存在 `lb3`、`lb4` 也会一并显示并可直接选择。直接回车时默认优先选择 `lb1`。
在复制文件前，安装脚本会先检查运行依赖是否已经可用，包括 `keepalived`、`ip`、`ipvsadm`、`socat` 和 `modprobe`。
如果你使用默认安装目录 `/opt/lvs-router`，安装脚本不会再错误改写成 `/opt/opt/lvs-router`。
当前模板会在 `lb1` / `lb2` 主配置末尾通过 `include` 原生加载 `virtual_server.conf`，因此 `TCP_CHECK` 会由 Keepalived 直接执行。
如果安装目录下已经存在上一版 `lvs-router`，安装脚本会先尝试执行旧的 `bin/stop.sh` 停掉旧进程，清空本机旧的 IPVS 规则，然后直接删除整个安装目录再重新安装。

这一步会完成：

- 停止安装目录下旧的 `lvs-router` 进程
- 清空旧的 IPVS 规则
- 删除整个旧安装目录并重建
- 将项目脚本安装到安装目录下的 `bin`
- 将 `keepalived/` 配置复制到安装目录下的 `keepalived`
- 将环境文件样例安装到安装目录下的 `lvs-router.env`

### 4. 编辑宿主机环境文件

编辑：

```bash
sudo vi /opt/lvs-router/lvs-router.env
```

至少确认以下变量：

- `KEEPALIVED_CONF`
- `HEALTHY_HTTP_PORT`
- `IPVS_MODULES`

### 5. 手工启动

```bash
sudo /opt/lvs-router/bin/start.sh
```

脚本会在后台拉起 `router-id-server.sh` 和 `keepalived`，然后立即退出。
正式启动前会先执行一次 `keepalived -t -f "$KEEPALIVED_CONF"` 配置校验；校验失败时不会留下半启动状态。

启动成功后会在 `/opt/lvs-router/run/pids/` 下生成：

- `keepalived.pid`
- `router-id-server.pid`

重启：

```bash
sudo /opt/lvs-router/bin/restart.sh
```

`restart.sh` 会先执行 `stop.sh` 清理已有进程和 `/run/keepalived.pid`，再重新启动。

查看状态：

```bash
sudo /opt/lvs-router/bin/status.sh
```

如果你的目标机是在这次修复之前安装的，建议重新执行一次安装脚本；否则至少手工检查：

- `/opt/lvs-router/keepalived/lb1/keepalived.conf`
- `/opt/lvs-router/keepalived/lb2/keepalived.conf`

确认其中没有 `/opt/opt/lvs-router`，并且 `global_defs` 内包含：

```bash
enable_script_security
script_user root
```

## 启动说明

统一由安装目录下的 `bin/start.sh` 拉起所有组件，启动流程如下：

1. 调用安装目录下的 `bin/load-ipvs-modules.sh`
2. 调用 `ipvsadm -C` 清空本机残留的 IPVS 规则
3. 调用安装目录下的 `bin/host-prep.sh`
4. 启动安装目录下的 `bin/router-id-server.sh`
5. 启动 `keepalived -nl -f ${KEEPALIVED_CONF}`

这样做是为了避免机器上遗留的旧 IPVS 规则影响当前 Keepalived 新下发的虚拟服务和轮询结果。

日志统一输出到安装目录下的 `logs`：

- `/opt/lvs-router/logs/start.log`
- `/opt/lvs-router/logs/router-id-server.log`
- `/opt/lvs-router/logs/keepalived.log`

## 验证步骤

### 1. 检查服务状态

```bash
sudo /opt/lvs-router/bin/status.sh
```

### 2. 检查 VIP

在当前 MASTER 节点查看：

```bash
ip addr show <你的网卡名>
```

应能看到与 `keepalived.conf` 中一致的 VIP。

### 3. 检查 IPVS 规则

```bash
ipvsadm -Ln
```

应能看到 `virtual_server.conf` 中配置的 VIP、端口和 RS 列表。
这些规则由 Keepalived 原生创建和维护。

### 4. 检查健康端口

在 LB 本机或同网段机器执行：

```bash
curl -s http://<LB_IP>:45555
```

应返回对应节点的 `router_id`。

### 5. 检查 VIP 对外服务

在能访问 VIP 的客户端执行：

```bash
curl -v http://<VIP>:<PORT>
```

## 运行时修改配置

### 修改 `keepalived/lb1/keepalived.conf` 或 `keepalived/lb2/keepalived.conf`

最稳妥的生效方式是重启整套脚本拉起的进程：

```bash
sudo /opt/lvs-router/bin/stop.sh
sudo /opt/lvs-router/bin/start.sh
```

如果只是希望 Keepalived 进程重读配置，也可以向 Keepalived 发送 `HUP` 信号，但这种方式不会重新执行 `host-prep.sh`：

```bash
sudo pkill -HUP keepalived
```

### 修改 `keepalived/virtual_server.conf`

这份文件已经被 `lb1/lb2` 的主配置通过 `include` 原生纳入 Keepalived。
因此，更新其中的 `virtual_server`、`real_server`、`weight` 或 `TCP_CHECK` 后，需要让 Keepalived 重新加载配置。

推荐做法：

```bash
sudo pkill -HUP keepalived
```

如果你同时修改了 VIP、接口或其他更关键的宿主机相关配置，仍建议直接重启整套服务：

```bash
sudo /opt/lvs-router/bin/stop.sh
sudo /opt/lvs-router/bin/start.sh
```

重载或重启后建议检查：

```bash
ip addr show <你的网卡名>
ipvsadm -Ln
tail -n 50 /opt/lvs-router/logs/keepalived.log
```

更完整的脚本说明和热更新建议见 `docs/script-reference-and-reload.md`。

## 故障切换验证

可以在当前主节点执行：

```bash
sudo /opt/lvs-router/bin/stop.sh
```

然后在备节点验证：

```bash
ip addr show <你的网卡名>
ipvsadm -Ln
curl -s http://<LB_IP>:45555
```

## 停止与清理

停止服务：

```bash
sudo /opt/lvs-router/bin/stop.sh
```

如果只想清理 IPVS 规则，可执行：

```bash
sudo /opt/lvs-router/bin/stop.sh
```

## 离线环境部署说明

如果目标 x86 Linux 机器无法联网，主思路是分发：

- 本仓库脚本与配置文件
- 目标发行版对应的离线软件包
- 或者预先配置好的内网软件仓库

推荐步骤：

1. 在可联网机器准备依赖包
2. 将项目目录复制到目标机器
3. 离线安装 `keepalived`、`ipvsadm`、`iproute2`、`socat`、`kmod`
4. 执行 `scripts/install-host-assets.sh`
5. 手工执行 `/opt/lvs-router/bin/start.sh`

如果目标环境是 CentOS / RHEL 系，并且你希望生成一个可搬运的离线依赖包，请优先使用：

```bash
./packaging/centos-offline/build-bundle.sh
```

默认会在 `packaging/centos-offline/` 下生成 `lvs-router-centos-offline/` 和 `lvs-router-centos-offline.tar.gz`，内容只包含离线安装 `keepalived`、`iproute`、`ipvsadm`、`socat`、`kmod` 所需的 RPM 及清单文件。

详细步骤见 `docs/centos-offline-install.md`。
