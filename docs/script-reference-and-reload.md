# 脚本说明与配置热更新

本文说明以下脚本的用途，以及修改 `Keepalived` / `IPVS` 配置后的推荐生效方式。

- `scripts/host-prep.sh`
- `scripts/load-ipvs-modules.sh`
- `lb/serve-router-id.sh`
- `scripts/stop.sh`
- `scripts/router-id-server.sh`
- `scripts/restart.sh`
- `scripts/start-ipvs-keepalived.sh`
- `scripts/start.sh`
- `scripts/status.sh`
- `scripts/stop-ipvs-keepalived.sh`

安装到目标机器后，这些脚本通常会被复制到 `/opt/lvs-router/bin/` 下运行。
`start.sh`、`stop.sh`、`status.sh`、`restart.sh` 默认会自动加载安装目录下的 `lvs-router.env`。
重新执行 `scripts/install-host-assets.sh` 时，如果安装目录下已有旧版 `lvs-router`，安装脚本会先尝试调用旧的 `bin/stop.sh` 停掉旧进程，清空本机旧的 IPVS 规则，再删除整个安装目录后重新安装新文件。

## 脚本说明

### `host-prep.sh`

用途：

- 从 `KEEPALIVED_CONF` 指向的 `keepalived.conf` 中读取 `VIP`、网卡名和 `router_id`
- 将 `router_id` 写入 `ROUTER_HTTP_DOCROOT/router_id`
- 在本机 `lo` 上添加 `VIP/32`
- 设置 `arp_ignore` / `arp_announce`，避免 LVS-DR 模式下错误响应 ARP
- 设置 `net.ipv4.vs.expire_nodest_conn=1` 和 `net.ipv4.vs.expire_quiescent_template=1`，让失效 RS 的旧连接和模板更快过期

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

## `virtual_server.conf` 的生效方式

当前仓库通过两个 Keepalived 实例配合完成 VRRP 和 IPVS：

- `keepalived/lb1/keepalived.conf` / `keepalived/lb2/keepalived.conf`：只负责 VRRP 和 VIP 漂移
- `keepalived/ipvs.conf`：只负责加载 `virtual_server.conf`

具体行为是：

- 当前节点进入 `MASTER` 时，`notify_master` 调用 `start-ipvs-keepalived.sh`
- 当前节点进入 `BACKUP` 或 `FAULT` 时，`notify_*` 调用 `stop-ipvs-keepalived.sh`

因此：

- `TCP_CHECK` 仍然由 Keepalived 原生执行
- 只有当前持有 VIP 的节点会运行 IPVS/TCP_CHECK Keepalived 实例
- 非 VIP 节点会停止该实例并清理本机 IPVS 规则

这样设计的原因是：当前项目允许 `LB` 与 `real_server` 节点重合。
如果两台机器都长期保留同一组 `virtual_server` / IPVS 规则，那么一台 LB 完成第一次调度后，转发到另一台同样也带有这组规则的节点时，可能再次触发本机 LVS 处理，最终引发递归转发、规则双活或主备回切后的异常路径。
通过把 VRRP 与 IPVS/TCP_CHECK 拆成两个 Keepalived 实例，可以保证只有真正持有 VIP 的节点才承担 director 身份。

这套方案的弊端是：主备倒换时除了 VIP 漂移，还需要额外启动或停止一次独立的 IPVS/TCP_CHECK Keepalived 实例。
因此恢复时间会比“双机都常驻 `virtual_server`”略慢，尤其是在还需要等待首轮健康检查把可用 RS 加回池中时更明显。

### `start-ipvs-keepalived.sh`

用途：

- 启动独立的 IPVS Keepalived 实例
- 使用单独的 PID 文件，避免与 VRRP Keepalived 实例冲突
- 在该实例中加载 `keepalived/ipvs.conf`，从而启用 `virtual_server.conf` 和 `TCP_CHECK`

### `stop-ipvs-keepalived.sh`

用途：

- 停止独立的 IPVS Keepalived 实例
- 清理该实例对应的 PID 文件
- 删除当前 `virtual_server.conf` 对应的 IPVS 服务，保证非 VIP 节点不保留规则

### `start.sh`

用途：

- 作为统一启动入口，负责拉起整套 `lvs-router`
- 启动成功后立即退出，不前台守护进程
- 将后台进程 PID 写入 `run/pids/`

启动顺序：

1. 创建日志目录和运行目录
2. 执行 `keepalived -t -f "$KEEPALIVED_CONF"` 预检查
3. 调用 `load-ipvs-modules.sh`
4. 调用 `ipvsadm -C` 清空本机残留的 IPVS 规则
5. 调用 `host-prep.sh`
6. 调用 `stop-ipvs-keepalived.sh`，确保当前节点启动前没有残留的 IPVS Keepalived 实例
7. 后台启动 `router-id-server.sh`
8. 后台启动 VRRP Keepalived：`keepalived -nl -f "$KEEPALIVED_CONF"`
9. 当前节点变为 `MASTER` 后，由 `notify_master` 启动独立的 IPVS Keepalived 实例

说明：

- 会检查 PID 文件，避免重复启动
- 启动前会先做 `keepalived -t` 校验，失败时直接退出
- 启动时会先执行一次 `ipvsadm -C`，避免旧 IPVS 规则残留影响当前 VIP 的转发结果
- 独立的 IPVS Keepalived 实例只有在当前节点进入 `MASTER` 后才会被启动
- `keepalived` 路径优先从 `PATH` 查找，也可通过 `KEEPALIVED_BIN` 指定

### `stop.sh`

用途：

- 作为统一停止入口，负责清理当前节点的运行状态

本地停止流程会：

- 调用 `stop-ipvs-keepalived.sh` 停掉独立的 IPVS Keepalived 实例并清理规则
- 读取 `run/pids/keepalived.pid` 和 `run/pids/router-id-server.pid`
- 对 PID 文件中的进程执行 `kill -9`
- 兜底清理匹配当前配置的 `keepalived` 残留进程
- 删除 `/run/keepalived.pid`
- 删除 PID 文件

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

- 查看 VRRP Keepalived、IPVS Keepalived 和 `router-id-server` 的 PID 文件状态
- 如果进程仍存活，输出对应 PID 和命令行
- 显示日志文件位置
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
- 适合修改了 `interface`、`VIP`、`include` 路径等较关键配置时使用

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
- `TCP_CHECK`

这部分由独立的 IPVS Keepalived 实例加载，因为 `keepalived/ipvs.conf` 会通过 `include` 引入 `virtual_server.conf`。

当前实现里，最直接的热更新方法是让独立的 IPVS Keepalived 实例重读配置：

```bash
sudo kill -HUP "$(cat /opt/lvs-router/run/pids/keepalived-ipvs.pid)"
```

这样独立的 IPVS Keepalived 实例会重新解析 `virtual_server.conf`，并按新配置更新 IPVS 服务和 `TCP_CHECK`。

同步后建议检查：

```bash
ipvsadm -Ln
curl -s http://<LB_IP>:45555
tail -n 50 /opt/lvs-router/logs/keepalived.log
```

## 推荐操作建议

如果你修改的是 `keepalived.conf`：

- 优先使用 `sudo /opt/lvs-router/bin/stop.sh` 后再执行 `sudo /opt/lvs-router/bin/start.sh`
- 想尽量少扰动时，再考虑对 Keepalived 发送 `HUP`

如果你修改的是 `virtual_server.conf`：

- 先同步配置到所有 LB 节点
- 然后对独立的 IPVS Keepalived 实例执行 `HUP`，或直接执行 `stop.sh` 后再执行 `start.sh`

如果你不确定当前改动属于哪一类：

- 直接执行 `stop.sh` 后再执行 `start.sh` 最稳妥
