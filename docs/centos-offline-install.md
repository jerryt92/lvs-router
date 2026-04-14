# CentOS 离线依赖包使用说明

本文档说明如何在一台可联网的 CentOS / RHEL 系机器上生成离线依赖包，并在完全离线的目标主机上安装 `keepalived`、`iproute`、`ipvsadm`、`socat`、`kmod` 及其依赖。

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
chmod +x packaging/centos-offline/*.sh
./packaging/centos-offline/build-bundle.sh
```

默认会生成：

- `packaging/centos-offline/lvs-router-centos-offline/`
- `packaging/centos-offline/lvs-router-centos-offline.tar.gz`

也就是说，离线安装目录和压缩包会默认创建在 `build-bundle.sh` 所在同级目录下。

包内主要内容：

- `*.rpm`：离线依赖 RPM
- `requested-packages.txt`：请求下载的包列表
- `downloaded-rpms.txt`：实际下载到的 RPM 文件列表

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
dnf install -y --disablerepo='*' --nogpgcheck --skip-broken ./*.rpm
```

如果目标机没有 `dnf`、但有 `yum`，可执行：

```bash
yum localinstall -y --disablerepo='*' --nogpgcheck --skip-broken ./*.rpm
```

安装完成后，可验证关键命令是否已就绪：

```bash
keepalived --version
ipvsadm -Ln
ip -V
socat -V
```

## 4. 后续项目部署

本脚本只负责准备和安装系统依赖，不再打包项目文件。

如果你还需要部署 `lvs-router` 项目本身，请另外传输仓库内容，并执行项目内的安装流程，例如：

```bash
scripts/install-host-assets.sh
```

详细项目部署说明请参考仓库 `README.md`。
