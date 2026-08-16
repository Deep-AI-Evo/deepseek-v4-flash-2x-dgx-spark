# 运维加固与视觉外迁（2026-08-16 更新）

> 主 README 是 2026-08-15 的首日实录。本文记录第二天的运行态调整：
> **纯文本档 + 视觉外迁 + 全链路开机自启**。参考了
> [maliubiao/dgx-spark-2-deepseek-flash-0731](https://github.com/maliubiao/dgx-spark-2-deepseek-flash-0731)
> 的运维加固方案（systemd 自启 / 内核参数），并结合本集群实际做了改造。

## 1. 为什么砍掉本地视觉 sidecar

首日架构把 Qwen3-VL-4B sidecar 和主模型挤在同一对 Spark 上（踩坑 #4 的 RDMA 注册内存
耗尽就是第一次警告）。运行一天后的实测数据：

- head：**116/119 GB 已用，available 仅剩 3 GB**，swap 用了 7.3 GB
- swap 最大消费者是 **vLLM 自己的宿主侧进程**（Worker_TP / EngineCore 合计 ~5 GB）
- 视觉 sidecar 的代价是双份的：自身占 ~7 GB，还逼主模型 util 从 0.835 降到 0.78
  （KV 池从 ~250 万 token 缩到 ~137 万）

结论：**上下文容量、视觉、系统余量，三选二**。GB10 统一内存 119GB 是硬约束，
主模型权重 + 激活固定 ~82GB，剩余空间经不起视觉再分一杯羹。

## 2. 最终运行架构

```
┌─ 2× DGX Spark ───────────────────┐   ┌─ RTX Pro 5000 (Windows) ──────┐
│ DeepSeek-V4-Flash TP=2  :8888     │   │ Qwen3.8-27B-NVFP4  :12345      │
│ MAX_MODEL_LEN=614400（60万）      │   │ Windows 原生 vLLM 0.26.0       │
│ MAX_NUM_SEQS=3 · util 0.80        │   │ 视觉/文本一体                  │
│ 系统余量 ~12GB · swap ~3GB        │   └──────────▲─────────────────────┘
└──────────┬───────────────────────┘            │ LAN HTTP (OpenAI 兼容)
           │     ds4f-vision MCP ───────────────┘
           │     DSPARK_VL_BASE_URL=http://192.168.0.102:12345
           ▼
   监控面板 :9090（双机 + 双服务 + 一键启动按钮）
```

视觉外迁零侵入：MCP 服务读 `DSPARK_VL_BASE_URL` / `DSPARK_VL_MODEL` 环境变量，
官方安装脚本支持 `--base-url`；vLLM 严格校验模型名，27B 端要同步设
`DSPARK_VL_MODEL=Qwen3.8-27B-NVFP4-MTP`（视服务端实际 served name 而定）。

## 3. 关键配置（纯文本档）

`.env.dspark` 相对首日的改动（全文见 `env.dspark.working`）：

```bash
ENABLE_VL_SIDECAR=0              # 1→0：关掉本地 sidecar
MAX_MODEL_LEN=614400             # 1M→600K
MAX_NUM_SEQS=3                   # 6→3
GPU_MEMORY_UTILIZATION_TEXT=0.80 # 0.835→0.80：真正的余量旋钮
```

**认知要点**：vLLM 按 util 一次性占满配额（权重+KV 池），`MAX_MODEL_LEN` 改小
**不释放内存**——只限制单请求长度。想给系统留余量，只能降 util。
util 0.80 是官方 recipe 实测过的档位（KV 池 ~130-180 万 token）。
满 600K 上下文实测并发 2.14 路；日常会话远短于 600K，3 路无感。

## 4. 开机自启与崩溃自愈（本仓库 scripts/autostart/）

maliubiao 教程用的是系统级 systemd + root 安装。本集群改造为 **user 级 systemd**
（`~/.config/systemd/user/` + `loginctl enable-linger`），全程免 root：

| 组件 | 位置 | 说明 |
|---|---|---|
| `dspark-vllm-start.sh` | head | 三级自愈：①API 健康→跳过 ②worker 在 head 缺→compose 直拉 ③双缺→跑上游 start |
| `dspark-vllm-stop.sh` | head | 幂等停止（双机容器） |
| `dspark-vllm-ensure.sh` | worker | 开机确保 worker 容器在；util 档位按 ENABLE_VL_SIDECAR 自动解析 |
| `dspark-vllm.service` / `dspark-vllm-worker.service` | user 单元 | oneshot + Restart=on-failure |
| `install.sh` | head | 一键安装双机（经 ssh 同步 worker） |
| `99-dsv4.conf` + `install-sysctl.sh` | 双机 | `vm.compaction_proactiveness=0`，防 kcompactd soft-lockup 整机重启（需 sudo 执行一次） |

本地适配要点：

- 脚本内置 `sg docker` 重入——dgx 是部署当天才加入 docker 组的，
  老会话/老 user-manager 没有该组，sg 在运行时重读组数据库兜底
- worker ensure 脚本自己解析 util 档位（VL 0.78 / 文本 0.80），
  不依赖 head 传参，避免 compose 变量缺省值（0.80 默认）和实际档位不一致
- 已实测完整周期：`systemctl --user stop` 28s 双机清净 → `start` 冷启 ~6 分钟恢复

管理命令：`systemctl --user {start,stop,restart,status} dspark-vllm.service`（head 管双机）。

## 5. 监控面板（dgx-spark-monitor 仓库）

`http://<head>:9090`，系统级 systemd 单元托管（`/etc/systemd/system/dgx-monitor.service`）。

次日新增：

- **健康指标**：Swap 使用率（双机）、RoCE 端口错误计数（CX-7 sysfs hw_counters）、
  容器状态/重启次数（docker inspect）、引擎探针延迟
- **告警**：RoCE 错误增长、容器重启/异常、探针 >10s、Swap ≥50%、磁盘 ≥90%
  （全部边沿触发，不刷屏）
- **健康总览条**：6 张迷你卡（节点/服务/RoCE/Swap/磁盘/温度，绿橙红一眼扫）
- **一键启动按钮**：POST `/api/dsv4/start` 触发上面的三级自愈脚本，
  服务挂了在手机上点一下就能拉起双机

**探针坑（值得记录）**：活性探针 URL 由 metrics 地址推导
（`url.rsplit('/',1)[0] + '/v1/chat/completions'`）。vLLM 的 `/metrics` 挂在根路径，
推导结果正好对；之前误写成 `…/chat/completions`（缺 `/v1`）导致探针全部 404，
面板误报"引擎假死"——而引擎其实 0.6s 正常响应。**假死告警是探针自己造成的**。
迁移到 llama.cpp 等非 vLLM 端点时同样要注意这个推导规则。

## 6. Windows 视觉端的坑（RTX Pro 5000）

1. **SSH banner 超时**：TCP 能连 22 但永远没有 banner——元凶是 portproxy 残骸
   `netsh interface portproxy show all` 发现 `0.0.0.0:22 → 172.17.0.1:22`
   （docker0 网关死地址，疑似给容器配转发留下的）。删除即通：
   `netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=22`
2. **Windows OpenSSH 授权密钥**：管理员组账户只读
   `C:\ProgramData\ssh\administrators_authorized_keys`，普通用户读
   `C:\Users\<name>\.ssh\authorized_keys`；写错位置=永远 Permission denied。
   用 `[System.IO.File]::WriteAllText()` 写入避免 BOM/编码坑
3. **开机自启**：任务计划程序（AtStartup + SYSTEM + RestartCount=5/2min），
   日志重定向到文件。注册脚本可用 SSH 远程执行：
   `scp` 不通（默认无 sftp 子系统）时用 `powershell -EncodedCommand <base64(UTF-16LE)>` 投递
4. **别同时起两个 27B 实例**：72GB 卡，NVFP4+MTP 实例占 ~68GB，
   任务计划拉起前先关手工窗口（重启机器则无此问题）

## 7. 切换后的实测

| 项 | 切换前（文本+本地视觉） | 切换后（纯文本+远程视觉） |
|---|---|---|
| head available 内存 | 3 GB | **12 GB** |
| head swap 使用 | 7.3 GB | **3 GB** |
| 单流解码（含 TTFT） | 54.6 tok/s | **69.1 tok/s** |
| 冒烟测试 | 6/6 | 6/6 |
| 满上下文并发 | 1.3 路 @1M | 2.14 路 @600K（日常 3 路无感） |
| 视觉质量 | Qwen3-VL-4B AWQ | **Qwen3.8-27B NVFP4**（强得多） |
