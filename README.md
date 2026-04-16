# LVS-DR + Keepalived 裸机 x86 部署指南

本项目提供一套可直接部署到 x86 Linux 宿主机的 `LVS-DR + Keepalived` 高可用负载均衡方案，默认按两台 LB 节点组织：`lb1` 和 `lb2`。它的目标是让客户端始终访问同一个 `VIP`，由当前活动 LB 节点接管该地址，并使用 Linux 内核中的 `IPVS` 将流量按策略分发到后端 `Real Server`。

## 核心概念

- `LVS`：Linux Virtual Server，Linux 上的四层负载均衡体系。本项目使用的是 `LVS-DR` 模式。
- `IPVS`：LVS 在 Linux 内核中的实际转发引擎，负责把到达 `VIP:PORT` 的连接转发到某个 `real_server`。
- `Keepalived`：用户态守护进程。本项目里既用它跑 `VRRP` 实现主备切换和 `VIP` 漂移，也用它维护 `virtual_server` / `real_server` 和 `TCP_CHECK`。
- `VIP`：Virtual IP，对客户端暴露的统一服务入口。谁当前是 `MASTER`，谁就持有这个地址。
- `VRRP`：Virtual Router Redundancy Protocol，负责在多台 LB 之间选主，并在故障时切换 `VIP` 的归属。

放到本项目里，可以理解为：

- `Keepalived + VRRP` 负责决定哪台 LB 当前持有 `VIP`
- 持有 `VIP` 的节点负责对外接流量
- `IPVS` 负责把到达 `VIP` 的连接分发到后端 `real_server`
- `TCP_CHECK` 用于把不健康的后端从转发池中摘除

## 架构与运行方式

默认角色如下：

- `lb1`：默认主节点，优先级更高
- `lb2`：默认备节点
- `Real Server`：你自己的物理机或虚拟机，需自行完成 `LVS-DR` 所需配置，例如在 `lo` 上绑定 `VIP/32`，并设置 `arp_ignore` / `arp_announce`

当前仓库没有现成的 `lb3` 配置。如果你需要三节点，可以在 `keepalived/lb2/keepalived.conf` 基础上复制出 `lb3` 并调整 `router_id`、`state`、`priority`。

本项目的 Keepalived 采用“两层职责”：

1. VRRP Keepalived 常驻运行，负责主备选举和 `VIP` 漂移。
2. 当前节点切到 `MASTER` 后，通过 `notify_master` 启动独立的 IPVS/TCP_CHECK Keepalived 实例。
3. 当前节点切到 `BACKUP` 或 `FAULT` 后，通过 `notify_*` 停掉该实例并清理本机规则。

这样设计的目的，是保证只有当前持有 `VIP` 的节点才保留 director 所需的 IPVS 规则，同时继续复用 Keepalived 原生的 `TCP_CHECK`。

## 目录说明

- `keepalived/`：VRRP 和虚拟服务配置
- `lb/`：节点身份识别 HTTP 应答脚本
- `scripts/`：部署、启动、停止、状态检查脚本
- `packaging/centos-offline/`：CentOS / RHEL 系离线打包脚本
- `docs/centos-offline-install.md`：离线安装说明
- `docs/script-reference-and-reload.md`：脚本用途与配置热更新说明
- `lvs-router.env.example`：宿主机环境变量示例文件

项目安装根目录在安装时输入，默认是 `/opt/lvs-router`。下文中的路径示例都以默认值为例：

- `/opt/lvs-router/bin`：项目脚本
- `/opt/lvs-router/keepalived`：Keepalived 与虚拟服务配置
- `/opt/lvs-router/lvs-router.env`：环境变量文件
- `/opt/lvs-router/logs`：统一日志目录
- `/opt/lvs-router/run`：运行时状态目录

## 依赖要求

目标机器需要具备以下软件：

- `keepalived`：实现 `VRRP`、`VIP` 漂移和健康检查
- `iproute2`：提供 `ip` 命令，用于管理接口和地址
- `ipvsadm`：管理 IPVS 规则
- `socat`：启动健康检查 HTTP 服务
- `modprobe`（`kmod` 包）：加载 IPVS 相关内核模块

同时需要内核支持 IPVS，常见模块包括：

- `ip_vs`：IPVS 核心模块
- `ip_vs_rr`：轮询调度算法
- `ip_vs_wrr`：加权轮询调度算法
- `ip_vs_sh`：源地址哈希调度算法

## 部署前配置

先修改以下配置文件，并同步到所有 LB 节点。

### 1. VRRP 配置

检查：

- `keepalived/lb1/keepalived.conf`
- `keepalived/lb2/keepalived.conf`

重点确认：

- `interface` 是否为实际网卡名，例如 `ens18`
- `virtual_ipaddress` 是否为你的业务 `VIP`
- `router_id` 是否唯一
- `priority` 是否符合主备顺序
- `notify_master` / `notify_backup` / `notify_fault` 是否仍指向安装目录下的 IPVS 控制脚本

### 2. 虚拟服务配置

编辑 `keepalived/virtual_server.conf`：

- `virtual_server <VIP> <PORT>` 改成实际业务 VIP 和端口
- `lb_algo` 选择调度算法
- `lb_kind` 选择转发模式，当前默认是 `DR`
- `real_server` 列表改成真实 RS 地址和端口

### 3. 本机角色环境文件

每台 LB 节点都需要一份安装目录下的 `lvs-router.env`。`start.sh`、`stop.sh`、`status.sh`、`restart.sh` 会自动读取它。

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

## LB/RS 拓扑模式

本项目支持通过环境变量 `LB_RS_TOPOLOGY` 显式声明当前拓扑：

- `LB_RS_TOPOLOGY=merged`：LB 与 RS 可能重合，默认值
- `LB_RS_TOPOLOGY=separated`：LB 与 RS 明确分离

示例：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb1/keepalived.conf
HEALTHY_HTTP_PORT=45555
ROUTER_HTTP_DOCROOT=/opt/lvs-router/run/router-http
IPVS_MODULES="ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh"
LB_RS_TOPOLOGY=separated
```

### `merged` 与 `separated` 的区别

`merged` 模式下：

- 当前持有 `VIP` 的节点进入 `MASTER` 时启动独立的 IPVS/TCP_CHECK Keepalived 实例
- 节点进入 `BACKUP` 或 `FAULT` 时停止该实例并清理本机 `virtual_server` 对应规则
- 适用于 LB 与 RS 重合，需要确保非 VIP 节点不再保留 director 规则的场景

`separated` 模式下：

- `start.sh` 启动时会直接拉起独立的 IPVS/TCP_CHECK Keepalived 实例
- VRRP 状态切到 `BACKUP` 或 `FAULT` 时，不再因为状态变化而停掉该实例
- 只有完整执行 `stop.sh` 时，才会强制停止该实例并清理规则
- 适用于 LB 与 RS 明确分离，希望两台 LB 都常驻 IPVS/TCP_CHECK 以缩短切换恢复时间的场景

### 为什么 `merged` 模式不能让备用节点继续保留 IPVS 规则

当 `LB` 节点自己同时也是某个 `real_server` 时，备用节点如果继续常驻 `virtual_server`、IPVS 规则和 `TCP_CHECK`，问题不只是“多做了一份健康检查”，而是它仍然保留了 director 身份。

典型风险路径如下：

1. 主节点持有 `VIP`，并根据 `virtual_server` 规则把一个请求调度到另一台机器。
2. 这台被选中的机器本身既是 RS，又仍然保留着相同的 IPVS `virtual_server` 规则。
3. 请求进入该机器后，内核可能再次把这笔流量当成需要由 LVS 处理的 `VIP` 流量。
4. 结果就会出现二次调度，继续把流量转发给别的 RS，甚至再转回另一台 LB。

这会带来几类典型故障：

- 递归转发
- 规则双活
- 主备回切路径异常
- 健康状态与实际接管角色错位

如果再叠加 VRRP 双主，风险会进一步放大，包括 `VIP` 双持有、ARP 表抖动、流量路径不稳定、健康检查视图分裂以及回切后残留异常。

如果你的网络拓扑允许，建议优先采用 `LB_RS_TOPOLOGY=separated`，并从架构上把 LB 与 RS 拆开；`merged` 更适合作为兼容或过渡方案，而不是长期首选方案。

### 调度算法提醒

如果你的拓扑是“LB 节点自己同时也是 `real_server`”，不要继续使用 `lb_algo rr`。

在这种情况下，`rr` 可能把请求轮到另一台同样也在运行 Keepalived/IPVS 的 LB 上，形成递归转发，表现为间歇性失败或按固定节奏失败。更稳妥的拓扑仍然是让 LB 和真实 RS 分离；如果暂时无法分离，建议优先考虑 `lb_algo sh`，并保持当前双实例模式，让非 VIP 节点不保留这组 IPVS 规则。

## 安装步骤

以下步骤需要在每台 LB 宿主机上执行。

### 1. 安装系统依赖

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

安装脚本会：

- 提示输入安装目录，直接回车时默认使用 `/opt/lvs-router`
- 自动扫描 `keepalived/` 下现有的 `lb*` 配置目录，并提示选择当前机器的 LB 角色
- 在复制文件前检查 `keepalived`、`ip`、`ipvsadm`、`socat` 和 `modprobe` 是否可用
- 如果安装目录下已有旧版本，先尝试调用旧的 `bin/stop.sh` 停掉进程、清空本机旧 IPVS 规则，再删除旧目录并重建

安装完成后，项目脚本会被放到 `/opt/lvs-router/bin`，Keepalived 配置会被放到 `/opt/lvs-router/keepalived`，环境文件样例会被放到 `/opt/lvs-router/lvs-router.env`。

### 4. 编辑环境文件

```bash
sudo vi /opt/lvs-router/lvs-router.env
```

至少确认以下变量：

- `KEEPALIVED_CONF`
- `HEALTHY_HTTP_PORT`
- `IPVS_MODULES`
- `LB_RS_TOPOLOGY`

### 5. 启动

```bash
sudo /opt/lvs-router/bin/start.sh
```

脚本会在后台拉起 `router-id-server.sh` 和 Keepalived，然后立即退出。正式启动前会先执行一次 `keepalived -t -f "$KEEPALIVED_CONF"` 配置校验；校验失败时不会留下半启动状态。

启动成功后，`/opt/lvs-router/run/pids/` 下常见会出现：

- `keepalived.pid`
- `keepalived-ipvs.pid`：仅当前 MASTER 持有 `VIP` 后出现
- `router-id-server.pid`

## 启动、重启与停止

启动：

```bash
sudo /opt/lvs-router/bin/start.sh
```

重启：

```bash
sudo /opt/lvs-router/bin/restart.sh
```

停止：

```bash
sudo /opt/lvs-router/bin/stop.sh
```

查看状态：

```bash
sudo /opt/lvs-router/bin/status.sh
```

`start.sh` 的主要流程如下：

1. 调用 `bin/load-ipvs-modules.sh`
2. 调用 `ipvsadm -C` 清空本机残留的 IPVS 规则
3. 调用 `bin/host-prep.sh`
4. 启动 `bin/router-id-server.sh`
5. 启动 VRRP Keepalived：`keepalived -nl -f ${KEEPALIVED_CONF}`
6. 节点切到 `MASTER` 后，由 `notify_master` 调用 `start-ipvs-keepalived.sh`
7. 节点切到 `BACKUP` / `FAULT` 后，由 `notify_*` 调用 `stop-ipvs-keepalived.sh`

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

在当前 `MASTER` 节点查看：

```bash
ip addr show <你的网卡名>
```

应能看到与 `keepalived.conf` 中一致的 `VIP`。

### 3. 检查 IPVS 规则

```bash
ipvsadm -Ln
```

应能看到 `virtual_server.conf` 中配置的 VIP、端口和 RS 列表。这些规则只会出现在当前持有 `VIP` 的节点上，并由独立的 Keepalived IPVS 实例创建和维护。

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

### 6. 故障切换验证

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

## 运行时修改配置

### 修改 `keepalived/lb1/keepalived.conf` 或 `keepalived/lb2/keepalived.conf`

最稳妥的方式是重启整套服务：

```bash
sudo /opt/lvs-router/bin/stop.sh
sudo /opt/lvs-router/bin/start.sh
```

如果只是希望 Keepalived 进程重读配置，也可以发送 `HUP`，但这种方式不会重新执行 `host-prep.sh`：

```bash
sudo pkill -HUP keepalived
```

### 修改 `keepalived/virtual_server.conf`

这份文件由独立的 IPVS Keepalived 实例通过 `keepalived/ipvs.conf` 加载。更新其中的 `virtual_server`、`real_server`、`weight` 或 `TCP_CHECK` 后，需要让 IPVS Keepalived 实例重新加载配置。

推荐做法：

```bash
sudo kill -HUP "$(cat /opt/lvs-router/run/pids/keepalived-ipvs.pid)"
```

如果同时修改了 VIP、接口或其他更关键的宿主机相关配置，仍建议直接重启整套服务：

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

## 离线环境部署

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

## 兼容性提醒

如果你的目标机是在早期版本安装的，建议重新执行一次安装脚本；否则至少手工检查：

- `/opt/lvs-router/keepalived/lb1/keepalived.conf`
- `/opt/lvs-router/keepalived/lb2/keepalived.conf`

确认其中没有 `/opt/opt/lvs-router`，并且 `global_defs` 内包含：

```bash
enable_script_security
script_user root
```
