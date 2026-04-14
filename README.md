# LVS-DR + Keepalived 裸机 x86 部署指南

本项目提供一套可直接部署到 x86 Linux 宿主机的 `LVS-DR + Keepalived` 高可用负载均衡方案，默认按两台 LB 节点组织：`lb1` 和 `lb2`。

整体设计保持不变：
- `keepalived/lb1/keepalived.conf`、`keepalived/lb2/keepalived.conf` 负责 VRRP 和 VIP 漂移
- `keepalived/virtual_server.conf` 描述 IPVS 虚拟服务和 Real Server
- `lb/ipvs-state.sh` 由 `notify_master` / `notify_backup` / `notify_fault` 触发，在主备切换时写入或清理 IPVS 规则

## 架构说明

- `lb1`：默认主节点，优先级更高
- `lb2`：默认备节点
- `Real Server`：你自己的物理机或虚拟机，需自行完成 LVS-DR 所需配置，例如在 `lo` 上绑定 `VIP/32`，并设置 `arp_ignore` / `arp_announce`

当前仓库没有现成的 `lb3` 配置。如果你需要三节点，可以在 `keepalived/lb2/keepalived.conf` 基础上复制出 `lb3` 并调整 `router_id`、`state`、`priority`。

## 目录说明

- `keepalived/`：VRRP 和虚拟服务配置
- `lb/`：LVS 规则同步脚本和健康检查应答脚本
- `scripts/`：裸机部署新增脚本
- `systemd/`：裸机部署新增的 systemd 单元
- `packaging/centos-offline/`：CentOS / RHEL 系离线打包和安装脚本
- `docs/centos-offline-install.md`：CentOS 完全离线安装说明
- `lvs-router.env.example`：宿主机环境变量示例文件

项目安装根目录在安装时输入，默认是 `/opt/lvs-router`。下文中的路径示例都以默认值为例：

- `/opt/lvs-router/bin`：项目脚本
- `/opt/lvs-router/keepalived`：Keepalived 与虚拟服务配置
- `/opt/lvs-router/systemd`：systemd unit 源文件
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

如果你的发行版默认启用了 systemd，本仓库提供的 unit 文件可以直接使用。

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
- `notify_*` 是否仍指向安装目录下的 `bin/ipvs-state.sh`

### 2. 修改虚拟服务配置

编辑 `keepalived/virtual_server.conf`：

- `virtual_server <VIP> <PORT>` 改成实际业务 VIP 和端口
- `lb_algo` 选择调度算法
- `lb_kind` 选择转发模式，当前默认是 `DR`
- `real_server` 列表改成真实 RS 地址和端口

### 3. 选择本机角色

每台 LB 节点都需要一份环境文件，安装后固定放在安装目录下的 `lvs-router.env`。可以从仓库中的 `lvs-router.env.example` 复制生成。

`lb1` 示例：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb1/keepalived.conf
VIRTUAL_SERVER_CONF=/opt/lvs-router/keepalived/virtual_server.conf
HEALTHY_HTTP_PORT=45555
IPVS_STATE_FILE=/opt/lvs-router/run/ipvs-state/current_service
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

### 3. 安装脚本、配置和 systemd 单元

在项目目录执行：

```bash
chmod +x scripts/*.sh lb/*.sh
sudo ./scripts/install-host-assets.sh
```

安装脚本会提示输入安装目录；直接回车时默认使用 `/opt/lvs-router`。
在复制文件前，安装脚本会先检查运行依赖是否已经可用，包括 `keepalived`、`ip`、`ipvsadm`、`socat`、`modprobe` 和 `systemctl`。

这一步会完成：

- 将项目脚本安装到安装目录下的 `bin`
- 将 `keepalived/` 配置复制到安装目录下的 `keepalived`
- 将 systemd unit 源文件安装到安装目录下的 `systemd`
- 在 `/etc/systemd/system` 创建指向安装目录中 `lvs-router.service` 的链接
- 将环境文件样例安装到安装目录下的 `lvs-router.env`

### 4. 编辑宿主机环境文件

编辑：

```bash
sudo vi /opt/lvs-router/lvs-router.env
```

至少确认以下变量：

- `KEEPALIVED_CONF`
- `VIRTUAL_SERVER_CONF`
- `HEALTHY_HTTP_PORT`
- `IPVS_MODULES`

### 5. 启用并启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl enable lvs-router.service
sudo systemctl start lvs-router.service
```

## 服务说明

### `lvs-router.service`

统一由安装目录下的 `bin/start.sh` 拉起所有组件，启动流程如下：

1. 调用安装目录下的 `bin/host-prep.sh`
2. 调用安装目录下的 `bin/ipvs-state.sh backup`
3. 调用安装目录下的 `bin/load-ipvs-modules.sh`
4. 启动安装目录下的 `bin/router-id-server.sh`
5. 启动 `keepalived -nl -f ${KEEPALIVED_CONF}`

日志统一输出到安装目录下的 `logs`：

- `/opt/lvs-router/logs/start.log`
- `/opt/lvs-router/logs/router-id-server.log`
- `/opt/lvs-router/logs/keepalived.log`

## 验证步骤

### 1. 检查服务状态

```bash
systemctl status lvs-router.service
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

## 运行时修改虚拟服务配置

运行时使用的虚拟服务定义来自安装目录下的 `keepalived/virtual_server.conf`。当前实现不会持续轮询该文件，而是在 VRRP 角色变化时通过 `notify_*` 触发 `ipvs-state.sh`。

推荐重载方式：

1. 在所有 LB 节点同步更新 `virtual_server.conf`
2. 让当前 MASTER 发生一次主备切换
3. 新 MASTER 在成为主节点时自动按新配置重建 IPVS 规则

示例：

```bash
sudo systemctl restart lvs-router.service
```

重启后检查：

```bash
ip addr show <你的网卡名>
ipvsadm -Ln
```

如果需要通过主节点停机来触发主备漂移，可直接停止统一服务：

```bash
sudo systemctl stop lvs-router.service
```

## 故障切换验证

可以在当前主节点执行：

```bash
sudo systemctl stop lvs-router.service
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
sudo systemctl stop lvs-router.service
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
5. 启动 `lvs-router.service`

如果目标环境是 CentOS / RHEL 系，并且你希望直接生成一个可搬运的离线安装包，请优先使用：

```bash
./packaging/centos-offline/build-bundle.sh
```

默认会在 `packaging/centos-offline/` 下生成 `lvs-router-centos-offline/` 和 `lvs-router-centos-offline.tar.gz`。

详细步骤见 `docs/centos-offline-install.md`。

当前仓库已经完全移除容器化部署入口，推荐方式就是直接部署到 x86 Linux 宿主机。
