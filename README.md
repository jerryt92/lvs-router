# LVS-DR + Keepalived Docker 部署指南

本项目提供一套基于 Docker 的 `LVS-DR + Keepalived` 高可用负载均衡方案。
当前仓库已经收敛为单个容器服务 `lvs-router`，容器实际加载哪一份 `keepalived` 配置，由项目目录下映射进去的 `lvs-router.env` 决定。

也就是说：

- 容器名固定为 `lvs-router`
- 运行时环境文件固定为项目目录下的 `lvs-router.env`
- `keepalived/` 目录固定从当前项目目录挂载到容器内 `/opt/lvs-router/keepalived`
- 切换 `lb1` / `lb2` 角色时，不需要改 Compose，只需要改 `lvs-router.env` 里的 `KEEPALIVED_CONF`

## 架构说明

- `lb1`：默认主节点，优先级更高
- `lb2`：默认备节点
- `Real Server`：你自己的物理机或虚拟机，需自行完成 LVS-DR 所需配置，例如在 `lo` 上绑定 `VIP/32`，并设置 `arp_ignore` / `arp_announce`

## 目录说明

- `docker-compose.yml`：单容器启动入口，服务名固定为 `lvs-router`
- `lvs-router.env`：当前节点运行时环境文件
- `lvs-router.env.example`：环境文件模板
- `keepalived/`：VRRP 与虚拟服务配置
- `scripts/`：容器内实际执行的控制脚本
- `lb/`：镜像构建文件与 HTTP 应答脚本
- `build_and_export.sh`：离线镜像构建与导出脚本

## 部署前配置

### 1. 修改 VRRP 配置

检查：

- `keepalived/lb1/keepalived.conf`
- `keepalived/lb2/keepalived.conf`

重点确认：

- `interface` 是否为实际网卡名，例如 `ens18`
- `virtual_ipaddress` 是否为你的业务 VIP
- `router_id` 是否唯一
- `priority` 是否符合主备顺序
- `notify_*` 是否仍指向 `/opt/lvs-router/bin/start-ipvs-keepalived.sh` 和 `/opt/lvs-router/bin/stop-ipvs-keepalived.sh`

### 2. 修改虚拟服务配置

编辑 `keepalived/virtual_server.conf`：

- `virtual_server <VIP> <PORT>` 改成实际业务 VIP 和端口
- `lb_algo` 选择调度算法
- `lb_kind` 选择转发模式，当前默认是 `DR`
- `real_server` 列表改成真实 RS 地址和端口

如果你的拓扑是“LB 节点自己同时也是 `real_server`”，建议不要继续使用 `lb_algo rr`，更适合改成 `lb_algo sh`，避免递归转发风险。

### 3. 配置当前节点角色

编辑项目目录下的 `lvs-router.env`。

`lb1` 示例：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb1/keepalived.conf
HEALTHY_HTTP_PORT=45555
ROUTER_HTTP_DOCROOT=/opt/lvs-router/run/router-http
IPVS_MODULES="ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh"
LB_RS_TOPOLOGY=merged
```

如果当前机器要作为 `lb2` 运行，只需要把 `KEEPALIVED_CONF` 改成：

```bash
KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb2/keepalived.conf
```

### 4. 选择拓扑模式

`lvs-router.env` 中支持：

- `LB_RS_TOPOLOGY=merged`
- `LB_RS_TOPOLOGY=separated`

`merged` 模式下，只有当前持有 VIP 的节点保留独立 IPVS Keepalived 实例。
`separated` 模式下，两台 LB 都可常驻独立实例，以缩短切换恢复时间。

## 在线启动

在当前节点项目目录执行：

```bash
docker compose up -d --build
```

说明：

- `docker-compose.yml` 已包含 `build` 配置，上述命令会先基于 `docker/Dockerfile` 构建本地镜像 `lvs-router:latest`
- 在线构建阶段仍需访问镜像仓库以拉取基础镜像，例如 `alpine:latest`
- 如果当前机器无法访问 Docker Hub，请改走下方“离线环境部署”

容器名固定为：

```bash
lvs-router
```

容器启动时会执行与宿主机版一致的流程：

1. 加载 IPVS 内核模块
2. 清理残留 IPVS 规则
3. 执行 `host-prep.sh`
4. 启动 `router-id-server.sh`
5. 启动 VRRP Keepalived
6. 根据拓扑模式启动或停止独立的 IPVS Keepalived 实例

## 离线环境部署

在可联网机器上执行：

```bash
chmod +x build_and_export.sh
./build_and_export.sh
```

会生成 `lvs-offline-images.tar`。

将整个项目目录连同这个 tar 包复制到目标机器后，执行：

```bash
docker load -i lvs-offline-images.tar
docker compose up -d
```

离线模式下不需要再执行 `--build`，前提是目标机器已经成功导入 `lvs-router:latest` 等所需镜像。

## 验证步骤

### 1. 检查容器状态

```bash
docker compose ps
docker compose logs lvs-router
```

### 2. 检查 VIP

```bash
docker compose exec lvs-router ip addr show <你的网卡名>
```

### 3. 检查 IPVS 规则

```bash
docker compose exec lvs-router ipvsadm -Ln
```

### 4. 检查健康端口

```bash
curl -s http://<LB_IP>:45555
```

应返回对应节点的 `router_id`。

### 5. 检查 VIP 对外服务

```bash
curl -v http://<VIP>:<PORT>
```

## 运行时修改配置

### 修改 `lvs-router.env`

修改角色或拓扑模式后，重启容器：

```bash
docker compose restart
```

### 修改 `keepalived/lb1/keepalived.conf` 或 `keepalived/lb2/keepalived.conf`

最稳妥的生效方式也是重启容器：

```bash
docker compose restart
```

### 修改 `keepalived/virtual_server.conf`

推荐向当前节点的独立 IPVS 实例发送 `HUP`：

```bash
docker compose exec lvs-router sh -lc 'kill -HUP "$(cat /opt/lvs-router/run/pids/keepalived-ipvs.pid)"'
```

如果你同时改了 VIP、接口或其他关键 VRRP 配置，建议直接重启容器。

## 故障切换验证

在当前主节点执行：

```bash
docker compose stop
```

然后在备节点验证：

```bash
docker compose exec lvs-router ip addr show <你的网卡名>
docker compose exec lvs-router ipvsadm -Ln
curl -s http://<LB_IP>:45555
```

## 停止与清理

停止当前节点服务：

```bash
docker compose stop
```

清理当前机器上的该项目容器：

```bash
docker compose down
```
