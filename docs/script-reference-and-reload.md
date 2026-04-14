# 脚本说明与配置热更新

本文说明以下脚本的用途，以及修改 `Keepalived` / `IPVS` 配置后的推荐生效方式。

- `scripts/host-prep.sh`
- `scripts/load-ipvs-modules.sh`
- `lb/serve-router-id.sh`
- `scripts/stop.sh`
- `lb/ipvs-state.sh`
- `scripts/router-id-server.sh`
- `scripts/restart.sh`
- `scripts/start.sh`
- `scripts/status.sh`

安装到目标机器后，这些脚本通常会被复制到 `/opt/lvs-router/bin/` 下运行。

## 脚本说明

### `host-prep.sh`

用途：

- 从 `KEEPALIVED_CONF` 指向的 `keepalived.conf` 中读取 `VIP`、网卡名和 `router_id`
- 将 `router_id` 写入 `ROUTER_HTTP_DOCROOT/router_id`
- 在本机 `lo` 上添加 `VIP/32`
- 设置 `arp_ignore` / `arp_announce`，避免 LVS-DR 模式下错误响应 ARP

典型场景：

- `start.sh` 启动时执行一次，为当前节点准备 LVS-DR 网络环境

### `load-ipvs-modules.sh`

用途：

- 通过 `modprobe` 加载 IPVS 相关内核模块

默认模块：

- `ip_vs`
- `ip_vs_rr`
- `ip_vs_wrr`
- `ip_vs_sh`

典型场景：

- `start.sh` 启动前执行，保证内核具备 IPVS 能力

### `serve-router-id.sh`

用途：

- 作为一个极简 HTTP 请求处理器
- 读取完请求头后直接返回 `200 OK`
- 响应体内容为 `ROUTER_HTTP_DOCROOT/router_id`

典型场景：

- 被 `router-id-server.sh` 通过 `socat` 按连接调用
- 用于快速确认当前请求打到了哪台 LB 节点

### `router-id-server.sh`

用途：

- 使用 `socat` 监听 `HEALTHY_HTTP_PORT`，默认端口为 `45555`
- 每收到一个连接，就执行一次 `serve-router-id.sh`

典型场景：

- 作为节点身份识别和简单探活接口
- 便于通过 `curl http://<LB_IP>:45555` 查看当前节点 `router_id`

### `ipvs-state.sh`

用途：

- 从 `VIRTUAL_SERVER_CONF` 读取虚拟服务配置
- 使用 `ipvsadm` 创建、更新或删除 IPVS 虚拟服务与 Real Server
- 通过 `IPVS_STATE_FILE` 记录当前已下发的服务，便于后续清理旧规则

支持状态：

- `master`：写入或更新当前虚拟服务
- `backup`：删除当前虚拟服务
- `fault`：删除当前虚拟服务
- `stop`：删除当前虚拟服务
- `sync`：检查本机是否真实持有 VIP；若持有则按配置同步 IPVS，若未持有则清理

典型场景：

- 由 `keepalived.conf` 中的 `notify_master` / `notify_backup` / `notify_fault` 调用
- 也可以手工执行 `ipvs-state.sh sync` 做运行时同步

### `start.sh`

用途：

- 作为统一启动入口，负责拉起整套 `lvs-router`
- 启动成功后立即退出，不前台守护进程
- 将后台进程 PID 写入 `run/pids/`

启动顺序：

1. 创建日志目录和运行目录
2. 执行 `keepalived -t -f "$KEEPALIVED_CONF"` 预检查
3. 调用 `load-ipvs-modules.sh`
4. 调用 `host-prep.sh`
5. 调用 `ipvs-state.sh backup`
6. 后台启动 `router-id-server.sh`
7. 后台启动 `keepalived -nl -f "$KEEPALIVED_CONF"`

说明：

- 先执行一次 `backup` 是为了避免启动瞬间误保留旧的 IPVS 规则
- 会检查 PID 文件，避免重复启动
- 启动前会先做 `keepalived -t` 校验，失败时直接退出
- `keepalived.conf` 模板默认已启用 `enable_script_security` 并使用 `script_user root`
- `keepalived` 路径优先从 `PATH` 查找，也可通过 `KEEPALIVED_BIN` 指定

### `stop.sh`

用途：

- 作为统一停止入口，负责清理当前节点的运行状态

本地停止流程会：

- 读取 `run/pids/keepalived.pid` 和 `run/pids/router-id-server.pid`
- 对 PID 文件中的进程执行 `kill -9`
- 兜底清理匹配当前配置的 `keepalived` 残留进程
- 删除 `/run/keepalived.pid`
- 删除 PID 文件
- 调用 `ipvs-state.sh stop`
- 删除 `IPVS_STATE_FILE`

### `restart.sh`

用途：

- 顺序执行 `stop.sh` 和 `start.sh`
- 在停止和启动之间等待 1 秒，减少 `keepalived` 残留退出中的竞争
- 用于配置变更后的一键重启

典型场景：

- 修改 `keepalived.conf` 后重启整套进程
- 手工运维时替代逐条执行停止和启动命令

### `status.sh`

用途：

- 查看 `keepalived` 和 `router-id-server` 的 PID 文件状态
- 如果进程仍存活，输出对应 PID 和命令行
- 显示日志文件位置
- 显示当前 `IPVS_STATE_FILE`
- 输出 `ipvsadm -Ln`，便于排查当前内核 IPVS 规则

典型场景：

- 手工启动后确认进程是否起来
- 排查 PID 文件残留、进程退出和 IPVS 规则是否生效

## 配置修改后如何热更新

这一点要分成两类配置来看。

### 1. 修改 `keepalived/lb1/keepalived.conf` 或 `keepalived/lb2/keepalived.conf`

这类文件影响的是：

- VRRP 角色与优先级
- 网卡名
- `virtual_router_id`
- `advert_int`
- `authentication`
- `virtual_ipaddress`
- `notify_*` 钩子

推荐做法分两种：

#### 方案 A：重启整套服务

最稳妥，适合多数场景。

```bash
sudo /opt/lvs-router/bin/stop.sh
sudo /opt/lvs-router/bin/start.sh
```

特点：

- 会重新执行 `start.sh`
- 会重新跑一遍主机网络准备和 Keepalived 启动流程
- 适合修改了 `interface`、`VIP`、`notify_*` 等较关键配置时使用

#### 方案 B：仅重载 Keepalived 进程

如果你只是调整了 Keepalived 配置，希望尽量减少影响，可以向 Keepalived 主进程发送 `HUP` 让其重读配置。

示例：

```bash
sudo pkill -HUP keepalived
```

注意：

- 这种方式只会重载 Keepalived 配置，不会重新执行 `host-prep.sh`
- 如果你修改的是 `VIP`、接口相关设置，单独 reload 后最好补做一次状态校验
- 如果你的机器上有多个 Keepalived 实例，不建议直接用 `pkill`，应改为向目标 PID 发送 `HUP`

重载后建议检查：

```bash
ip addr show <你的网卡名>
ipvsadm -Ln
tail -n 50 /opt/lvs-router/logs/keepalived.log
```

### 2. 修改 `keepalived/virtual_server.conf`

这类文件影响的是：

- `virtual_server <VIP> <PORT>`
- `lb_algo`
- `lb_kind`
- `real_server` 列表
- `weight`

这部分并不是由 Keepalived 持续自动下发，而是由 `ipvs-state.sh` 读取后写入内核 IPVS 表。

当前实现里，最直接的热更新方法是在当前 MASTER 节点执行：

```bash
sudo /opt/lvs-router/bin/ipvs-state.sh sync
```

作用：

- 如果当前节点持有 VIP，就按新配置增删改 IPVS Real Server
- 如果当前节点已经不是 MASTER，就自动清理本机旧规则

因此，`virtual_server.conf` 修改后通常不需要主备切换，也不一定需要重启整套脚本拉起的进程。

同步后建议检查：

```bash
ipvsadm -Ln
curl -s http://<LB_IP>:45555
```

## 推荐操作建议

如果你修改的是 `keepalived.conf`：

- 优先使用 `sudo /opt/lvs-router/bin/stop.sh` 后再执行 `sudo /opt/lvs-router/bin/start.sh`
- 想尽量少扰动时，再考虑对 Keepalived 发送 `HUP`

如果你修改的是 `virtual_server.conf`：

- 先同步配置到所有 LB 节点
- 然后只在当前 MASTER 上执行 `sudo /opt/lvs-router/bin/ipvs-state.sh sync`

如果你不确定当前改动属于哪一类：

- 直接执行 `stop.sh` 后再执行 `start.sh` 最稳妥
