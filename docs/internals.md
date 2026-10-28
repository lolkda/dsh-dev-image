# Web 访问与插件机制

面向排障和二次开发。日常使用看 [README](../README.md)。

## 为什么默认能直接访问

[compose.yml](../compose.yml) 使用 `network_mode: host`，容器共享宿主网络栈。DSH 自动从宿主机网卡派生可信 Host，所以 LAN、Tailscale、ZeroTier、VPN 地址都不需要手工填。

host 模式下 DSH 监听 `0.0.0.0`，会在所有宿主网卡上暴露 `3080`。有公网 IP 的机器必须配置防火墙。

### 为什么必须用 patch 层

DSH 的命令行明确拒绝 `--host 0.0.0.0`，而 schema 只接受 `127.0.0.1` 和 `0.0.0.0` 两个值。容器里如果绑 `127.0.0.1`，Docker 端口映射转发不到；所以必须绑 `0.0.0.0`。镜像默认安装的 `@lolkda/dsh-web-lan` 负责这一层 patch。

### `/api` Host 围栏

`/api` 有防 DNS rebinding 的 Host 校验，只放行 loopback 或精确命中 `trustedHosts` 的 Host，不支持通配符。Web GUI 本身是静态页面，但页面上的会话列表、发消息、看文件都走 `/api`。

Host 不匹配的典型症状是：**页面能打开，然后一片空白**。通过域名访问时，把域名加入 `DSH_WEB_TRUSTED_HOSTS`。

### bridge 网络

```bash
DSH_HOST=192.168.1.5 docker compose -f compose.bridge.yml up -d
```

bridge 下容器看到的网卡是 `172.x`，浏览器发来的 Host 是宿主地址，两者对不上会 403。所以必须填 `DSH_HOST`：它同时决定端口发布到哪张网卡和围栏信任哪个 Host。

`DSH_PORT` 只影响宿主端口，默认 `3080`；信任项是 port-less 的，匹配任意端口。端口映射右边固定为容器内的 `3080`。

## DSH 插件

一个 DSH 插件就是普通 npm 包，在 `package.json` 里声明 patch 层：

```json
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
```

`dsh plugin --profile <p> add <spec>` 会：

1. 在 profile 目录里运行 pnpm；
2. 把包名追加到 profile `package.json` 的 `dsh.profile.bundles`。

profile 位于 `$DSH_HOME/profiles/<name>/`，而 `$DSH_HOME` 是挂载卷。构建期写进镜像的 profile 会被卷遮蔽，所以插件登记必须放在启动入口里。

默认 profile 结构：

```text
package.json          # dependencies + dsh.profile.bundles
pnpm-lock.yaml
pnpm-workspace.yaml   # nodeLinker: hoisted
cordis.yml            # profile 根，通常是空数组
cordis.patch.yml      # 自己的 patch 层
node_modules/
```

### 默认插件与版本

镜像和两份 Compose 默认只安装：

```text
@lolkda/dsh-web-lan@latest
```

必须显式写 `@latest`。pnpm 对 profile 中已登记的依赖会沿用原 spec，只写包名不会重新解析最新版本。

代价是：同一个镜像在不同时间启动可能装到不同版本，上游大版本也会被直接吃进来。要可复现就在 `DSH_PLUGINS` 里写死版本。

`DSH_PLUGIN_REGISTRY` 只作用于插件安装，默认官方 npm；用户项目的 npm / pnpm 依赖仍走 `NPM_REGISTRY` 或 `npm_config_registry`。

入口在插件安装命令上设置 `PNPM_CONFIG_MINIMUM_RELEASE_AGE=0`，绕过 pnpm 12 默认的 24 小时成熟期，否则 `@latest` 实际等价于“一天前的最新版”。这个覆盖不影响容器里用户项目的 pnpm 安装。

### 关闭或替换

```yaml
environment:
  DSH_PLUGINS: "@lolkda/dsh-web-lan@latest"
```

- `DSH_PLUGINS=` 会跳过安装，但不会卸载已有 profile 内的插件。
- `DSH_PLUGINS_REQUIRED=0` 允许插件安装失败后继续启动；默认 `1` 会直接退出。
- 离线环境必须同时确保镜像已就绪，或者显式关闭插件安装。

`link:` 安装的本地插件要求路径在容器内存在。宿主机的 `F:/project/...` 在 Linux 容器里没有意义；要么用 registry 版本，要么先把 checkout 拷进镜像。

### 可选：免 token 入口

`@lolkda/dsh-web-lan` 支持 `autoLogin: true` 和 `/go` 免 token 入口。官方拒绝 `0.0.0.0` 的理由是面板等价于任意命令执行；在容器里，这个执行范围被限制在容器内，但没有 Docker socket 和宿主文件系统。

开启方式是在 `$DSH_HOME/profiles/web/cordis.patch.yml` 中按 id 定向：

```yaml
- id: dsh-web-lan
  name: '@lolkda/dsh-web-lan'
  config:
    autoLogin: true
```
