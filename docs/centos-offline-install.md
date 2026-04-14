# CentOS 完全离线安装包使用说明

本文档说明如何在一台可联网的 CentOS / RHEL 系机器上生成离线安装包，并在完全离线的目标主机上安装 `LVS-DR + Keepalived` 运行依赖和项目文件。

## 打包端要求

建议在与目标机同大版本的 CentOS / RHEL 系机器上执行打包，例如：

- 目标机是 CentOS Stream 9，就在 CentOS Stream 9 联网机器上打包
- 目标机是 Rocky 8 / AlmaLinux 8，就在同为 EL8 的机器上打包

打包端需要：

- 能访问系统软件仓库
- 已安装 `tar`
- 具备以下任一下载能力
  - `dnf download`
  - `yumdownloader`

如果缺少下载工具，可先安装：

```bash
sudo dnf install -y 'dnf-command(download)'
```

或：

```bash
sudo yum install -y yum-utils
```

## 1. 在联网机器生成离线安装包

进入项目根目录执行：

```bash
chmod +x packaging/centos-offline/*.sh scripts/*.sh
./packaging/centos-offline/build-bundle.sh
```

默认会生成：

- `packaging/centos-offline/lvs-router-centos-offline/`
- `packaging/centos-offline/lvs-router-centos-offline.tar.gz`

也就是说，离线安装目录和压缩包会默认创建在 `build-bundle.sh` 所在同级目录下。

包内主要内容：

- `rpms/`：离线依赖 RPM
- `project/`：项目文件副本
- `install-offline-bundle.sh`：目标机一键安装脚本

## 2. 传输到离线目标机

将以下任一内容复制到离线目标机：

- `packaging/centos-offline/lvs-router-centos-offline.tar.gz`
- 或整个 `packaging/centos-offline/lvs-router-centos-offline/` 目录

如果传的是压缩包，先解压：

```bash
tar -xzf lvs-router-centos-offline.tar.gz
cd lvs-router-centos-offline
```

## 3. 在离线目标机安装

以 `root` 执行：

```bash
chmod +x install-offline-bundle.sh
./install-offline-bundle.sh
```

该脚本会自动完成：

- 使用本地 `rpms/*.rpm` 安装 `keepalived`、`iproute`、`ipvsadm`、`socat`、`kmod` 及其依赖
- 安装项目脚本到你输入的安装目录，默认是 `/opt/lvs-router/bin`
- 安装 Keepalived 配置到默认 `/opt/lvs-router/keepalived`
- 安装环境文件到默认 `/opt/lvs-router/lvs-router.env`
- 安装 systemd unit 源文件到默认 `/opt/lvs-router/systemd`
- 在 `/etc/systemd/system` 下创建 `lvs-router.service` 到安装目录中 `systemd/lvs-router.service` 的符号链接
- 执行 `systemctl daemon-reload`
- 在复制项目文件前再次检查 `keepalived`、`ip`、`ipvsadm`、`socat`、`modprobe`、`systemctl` 是否可用
- 默认启用服务，但默认不立即启动

## 4. 修改配置并启动

在目标机上编辑：

```bash
vi /opt/lvs-router/lvs-router.env
```

然后根据本机角色调整：

- `KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb1/keepalived.conf`
- 或 `KEEPALIVED_CONF=/opt/lvs-router/keepalived/lb2/keepalived.conf`

同时检查：

- `/opt/lvs-router/keepalived/lb1/keepalived.conf`
- `/opt/lvs-router/keepalived/lb2/keepalived.conf`
- `/opt/lvs-router/keepalived/virtual_server.conf`

确认 VIP、网卡名、Real Server 地址都已改成你的实际环境。

启动服务：

```bash
systemctl enable lvs-router.service
systemctl start lvs-router.service
```

## 5. 验证

```bash
systemctl status lvs-router.service
ip addr show <你的网卡名>
ipvsadm -Ln
curl -s http://<LB_IP>:45555
```

日志默认输出到：

```bash
/opt/lvs-router/logs/start.log
/opt/lvs-router/logs/router-id-server.log
/opt/lvs-router/logs/keepalived.log
```

## 可选环境变量

安装脚本支持以下变量：

```bash
AUTO_ENABLE_SERVICES=1
AUTO_START_SERVICES=0
```

如果你确定配置已提前改好，也可以在安装时直接启动：

```bash
AUTO_START_SERVICES=1 ./install-offline-bundle.sh
```
