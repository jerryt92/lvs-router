# LVS-DR + Keepalived 路由集群部署与测试指南

本项目提供了一个基于 Docker Compose 的三节点路由器部署方案。底层采用 **LVS-DR（直接路由）** 模式，结合 **Keepalived** 实现高可用与流量调度。

为了支持从局域网内其他物理设备直接访问 LVS 的 VIP，LB 使用 **host 网络**；**Keepalived / LVS 配置**在仓库 `keepalived/` 目录下（默认挂载进容器），按需直接编辑配置文件即可。容器会轮询 `keepalived/virtual_server.conf` 并自动同步 IPVS 规则，无需重启容器。
同时，支持**完全断网（内网隔离环境）下的快速迁移部署**机制。

## 架构说明

* **网关与调度（LB）**：包括 `lb1`、`lb2`、`lb3` 三个 Keepalived 节点。
* **业务节点（Real Server）**：由你自有的物理机/虚拟机承担；在 `keepalived/virtual_server.conf` 中填写 `real_server` 地址与端口，并在各 RS 上自行完成 LVS-DR 所需配置（如 `lo` 上绑定 `VIP/32`、`arp_ignore`/`arp_announce`）。

## 双端离线部署流程 (适用于 Ubuntu 虚拟机无外网的情景)

由于 Linux 虚拟机在内网或者特殊安全策略下经常无法在线下载并拉取基础依赖（即 `apk add` 阶段遇到 `Permission denied` 或 SSL 错误），当前的部署架构已经全面替换为了静态**离线镜像**加载模式，剔除了在线动态 `build`：

### 阶段 1：在你能联网的机器 (比如 Mac 宿主机) 上提前打包
1. 保证你现在在有网络环境的主机上。
2. 运行一键构建与打包脚本，它会将 `linux/amd64` 的 LB 镜像与测试用 curl 客户端镜像打成一整个 `.tar` 文件：
   ```bash
   chmod +x build_and_export.sh
   ./build_and_export.sh
   ```
3. 等待完成后，你会在目录里发现一个 `lvs-offline-images.tar` 文件。

### 阶段 2：环境与 Keepalived 配置
编辑 `.env` 中的 `PARENT_INTERFACE`、`VIP`、`RS1_IP`、`RS2_IP`，并**同步**修改 `keepalived/keepalived.conf`、`lb2.conf`、`lb3.conf` 里的网卡与 VIP，以及 `keepalived/virtual_server.conf` 中的 VIP、RS 与端口（当前 compose 不把这些注入容器，以 `keepalived/` 文件为运行时生效配置）。

### 阶段 3：传输至目标隔离机器并启动服务
将包含修改好的 `docker-compose.yml`、`.env`、`keepalived/` 目录以及你打好的 `lvs-offline-images.tar` 项目文件夹丢进你的离线目标 Linux (如 Ubuntu 虚拟机) 服务器内。

在那台断网机器上登录，并切入该目录执行：

```bash
# 1. 直接读取我们的离线环境塔包（脱离外网）
docker load -i lvs-offline-images.tar 

# 2. 读取当前目录环境编排文件并在后台静默直接起飞（无需再跑 --build）
docker compose up -d
```

## 测试与验证步骤

### 1. 验证 VIP 的初始挂载
观察 VIP（与 `keepalived/*.conf` 中 `virtual_ipaddress` 一致）：
```bash
# 将 ens18 换成本地 .env / keepalived 中的 PARENT_INTERFACE
docker compose exec lb1 ip addr show ens18
```

### 2. 验证 LVS 规则配置
查看针对业务映射所设的 DR 规则是否拉起：
```bash
docker compose exec lb1 ipvsadm -Ln
# 应能看到针对 VIP 与业务端口的负载记录（与 keepalived/virtual_server.conf 一致）。
```

### 3. 测试局域网络外部设备直接访问 LVS-DR
现在只要你的处于同物理交换机/Wi-Fi 网络下的手机或是另一台电脑，直接在地址栏打开或发起：
```bash
# 使用局域网其他机器
for i in {1..5}; do curl -s http://<你的VIPIP>; sleep 1; done
```
如果内网设备无法访问，可在 `LB/RS` 节点所在同网段的任意机器上直接执行 `curl http://<你的VIPIP>` 排查连通性。

### 4. 模拟倒换漂移容灾倒换 (Failover)
```bash
# 挂掉当前的 master 宿主挂节点 lb1 验证流量和权重切换
docker compose stop lb1

# 查看候补顺位的 lb2 重接替并验证它已经绑定上了 VIP 并写入了 IPVS（网卡名同 keepalived）
docker compose exec lb2 ip addr show ens18
docker compose exec lb2 ipvsadm -Ln
```
此时可以再次测下业务的连续性，你之前分配给哪个 RS，由于哈希连续，应当保持不变的分发通道。

## 清理环境

测试完毕后，在虚拟机节点上直接运行即重置：
```bash
docker compose down
```

## 多物理机部署（host 网络模式）

当前 `docker-compose.yml` 仅包含 `lb1`、`lb2`、`lb3`，且均为 `network_mode: host`，应在各自 **LB 宿主机**上启动；真实 RS 不在 Compose 中，地址写在 `keepalived/virtual_server.conf`，RS 上需单独按 LVS-DR 要求配置。

### 1) 在每台 LB 机器上启动对应服务

把同一个项目文件夹复制到各 LB 节点，在每台机器分别执行（示例为仅拉起本机角色）：

* 在 `lb1`（MASTER）机器上：
  ```bash
  docker compose -f docker-compose.yml up -d --build lb1
  ```
* 在 `lb2`（BACKUP，优先级 90）机器上：
  ```bash
  docker compose -f docker-compose.yml up -d --build lb2
  ```
* 在 `lb3`（BACKUP，优先级 80）机器上：
  ```bash
  docker compose -f docker-compose.yml up -d --build lb3
  ```

### 2) 需要提前在 `keepalived/` 核对的值
* `interface` / `virtual_ipaddress`：与每台 LB 的物理网卡、共用 VIP 一致（三份 VRRP 配置需同步改 VIP 与网卡名时，可同时改 `keepalived.conf`、`lb2.conf`、`lb3.conf`）
* `virtual_server` / `real_server`：与业务端口、真实 RS IP 一致（通常只改 `virtual_server.conf` 即可）

### 3) 验证
从任意能访问 `VIP` 的客户端机器访问：
```bash
curl -v http://<VIP>
```

可选地，停掉 `lb1` 再验证 VIP 漂移到 `lb2/lb3`，以及 LVS 转发是否继续正常。
