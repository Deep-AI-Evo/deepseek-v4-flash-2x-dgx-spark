<div align="center">

# DeepSeek-V4-Flash × 2 台 DGX Spark 双机部署实录

**167GB FP8 MoE · 双机 TP=2 · RoCE 200G 直连 · 1M 上下文 · 视觉共存**
**含全部踩坑与官方成绩对齐过程**

[![Model](https://img.shields.io/badge/🤗%20Model-DeepSeek--V4--Flash--0731-blue)](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)
[![Recipe](https://img.shields.io/badge/Recipe-MiaAI--Lab%20DSpark-green)](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)
[![Platform](https://img.shields.io/badge/Platform-2%C3%97%20DGX%20Spark%20GB10-76b900)](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
[![License](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

### 🌐 **[Switch to English](README.en.md)**

</div>

---

> 部署日期：2026-08-15　环境：2× NVIDIA DGX Spark（GB10，128GB 统一内存），QSFP 直连
> 基于 [MiaAI-Lab 的 DSpark 配方](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)，感谢原作者

> 📌 **2026-08-16 运行态更新**：已切换为**纯文本档（60 万上下文 × 3 并发，util 0.80）**，
> 视觉能力外迁到 RTX Pro 5000（Qwen3.8-27B-NVFP4，MCP 远程调用），并补齐双机开机自启、
> 内核加固、监控面板一键启动。原因与全部细节见
> [docs/ops-autostart-and-remote-vision.md](docs/ops-autostart-and-remote-vision.md)。
> 下方为 8-15 首日实录（含 1M 上下文 + 本地视觉共存方案），保留备查。

> 🌡️ **2026-08-19 运行态更新**：修复 vLLM 的 Spin-Wait 空转发热问题——`busy_loop_s`
> 默认 1 秒导致 3-4 个 CPU 大核全程 100% 空转（聚合利用率仅 ~20%，持续高负载峰值达 95℃），
> 一行补丁（1 → 0.002）后严格 A/B 实测：1/2/3 并发下 head 节点 SoC 峰值稳定降
> 11.6~12.7℃（91-93℃ → 78-81℃），吞吐无损。
> 实测数据、双机补丁步骤与回滚方法见
> [docs/vllm-spinwait-thermal-fix.md](docs/vllm-spinwait-thermal-fix.md)
> （致谢 nacyot 原始诊断与 drowzeys 的英文整理）。

## 📌 为什么需要两台

DeepSeek-V4-Flash-0731 是 FP8 量化的 MoE 模型（256 专家 / top-6，43 层），权重 **166.9GB**。
单台 DGX Spark 可用统一内存约 119GB——**单机物理上放不下**，必须双机张量并行（TP=2），
两台各扛约 84GB 权重，中间的 QSFP 直连线跑 NCCL 通信。这也是官方 `DeepSeek-V4-Flash-DSpark`
变体的目标玩法。

## 🏗 最终架构

```
┌─────────────────────┐   QSFP 直连 RoCE 200G    ┌─────────────────────┐
│  DGX Spark (head)   │  18.18.11.1 ↔ 18.18.11.2 │  DGX Spark (worker) │
│  192.168.0.114      │  18.18.13.1 ↔ 18.18.13.2 │  192.168.0.115      │
│                     │                          │                     │
│  vLLM rank0 (docker)│ ◄── NCCL (RoCEv2) ─────► │  vLLM rank1 (docker)│
│  API :8888 (文本)   │                          │                     │
│  API :8889 (视觉)   │ ◄── NCCL (TCP Socket) ──►│  VL sidecar rank1   │
└─────────────────────┘                          └─────────────────────┘
```

- **文本**：`deepseek-v4-flash-0731`，1M 上下文（1,048,576 tokens），KV cache 约 130–270 万 tokens，DSpark MTP×5 推测解码
- **视觉**：Qwen3-VL-4B sidecar（模型本身纯文本，视觉由 sidecar 提供，可经 `ds4f-vision` MCP 接入智能体）

## 📊 实测性能

**解码（官方 benchmark-0731.py 同方法，自然文本）**

| 场景 | 本集群实测 | 官方公布 | 达成 |
|---|---|---|---|
| 256 tokens, 单并发 | 48–64 tok/s | 75.4 tok/s | 64–85% |
| 256 tokens, 4 并发 | 25–31 tok/s | 46.8 tok/s | 54–67% |
| 官方 SETUP.md 参考值 | — | ~52 tok/s | **已达标** |

**Prefill（单并发，冷前缀）——长上下文已对齐甚至反超官方**

| 输入 | TTFT | prefill 速度 | 官方 |
|---|---|---|---|
| 8K | 8.8 s | 930 tok/s | 1713 tok/s |
| 32K | 17.4 s | **1880 tok/s** | 1428 tok/s |
| 128K | 76.0 s | **1725 tok/s** | 1665 tok/s |
| 900K–1M | 推算 10–17 分钟 | — | 875 tok/s @900K |

**容量**：`max_num_seqs=6`；KV 池 270 万 tokens（文本档 util 0.835）→ 满 1M 上下文约 2.6 路并发。
另有官方高吞吐档（200K 上下文 + 16 并发）可切换。

## 🕳 踩坑全记录（按价值排序）

| # | 症状 | 根因 | 解法 |
|---|---|---|---|
| 1 | 原生 vLLM 0.27 起不来 | GB10(SM121) 缺 FlashInfer sparse MLA decode API | 用 DSpark 定制镜像 `ghcr.io/anemll/dspark-vllm-gx10` |
| 2 | NCCL 跨机初始化死等 | 网卡被 NetworkManager 自动塞了 169.254 link-local，NCCL bootstrap 选错地址 | 用 nmcli 正规配置静态 IP（`ip addr add` 会被 NM 回收！） |
| 3 | 双 rail NCCL `ibv_modify_qp` 失败 | 两台机器 GID 表不同：本机 IPv4 在索引 3，115 在索引 5 | 逐台从 sysfs 解析 GID（配方自带 auto 解析）；固定时 `WORKER_NCCL_IB_GID_INDEX=5` |
| 4 | 视觉 sidecar 必崩 | **RDMA 可注册内存耗尽**：主模型锁死 ~93GB 后 `ibv_reg_mr` 必失败（探针实锤，与桌面应用无关） | sidecar 的 NCCL 改 TCP Socket（4B 小模型通信量极小，0.44ms/次，无感） |
| 5 | HF 下载 401 | huggingface_hub 新版默认走 xet 后端，直连 HF 域名不通 | `HF_HUB_DISABLE_XET=1` + hf-mirror 镜像 |
| 6 | ghcr 拉取停滞 | 直连 ghcr.io 大 blob 0 B/s | NJU 镜像站 `ghcr.nju.edu.cn`（并行拉取 78MB/s） |
| 7 | Ray `ActorHandleNotFound` | 上次失败的 vLLM 留了脏 Ray session | `ray stop --force` 双机清干净再启 |
| 8 | "速度只有官方一半" | 测量方法污染：请求带 `thinking=max` 长思考 + 计时含 TTFT | 用官方 `scripts/benchmark-0731.py` 同方法对比 |
| 9 | 双 rail 反而更慢 | 小消息 allreduce 是延迟敏感，双 rail 条带化反而添乱 | 保持官方默认单 rail |
| 10 | vllm 要 FP8 KV | DeepSeek V4 fp8_ds_mla 布局强制 | `--kv-cache-dtype fp8`（DSpark 镜像用 nvfp4_ds_mla） |
| 11 | 负载下 SoC 90℃+（实测峰值 95℃），但聚合 CPU 利用率 <20% | vLLM IPC 空转：`busy_loop_s` 默认 1s，解码消息几毫秒一次导致睡眠分支永不触发，3-4 个大核全程 100% 空转（`mpstat -P ALL` 可见） | 一行补丁 `1 → 0.002` + 薄层派生镜像，严格 A/B 实测 head 节点三档并发降 11.6~12.7℃、吞吐无损，见 [docs/vllm-spinwait-thermal-fix.md](docs/vllm-spinwait-thermal-fix.md) |

## 🔧 关键工具与技巧

- **NCCL 隔离测试**（排除 vLLM/Ray 干扰，直接验证双机 NCCL）：
  ```bash
  # 两端各跑（node-rank 0/1），见 tests/nccl_test.py
  torchrun --nnodes=2 --nproc-per-node=1 --node-rank=0 \
    --master-addr=18.18.11.1 --master-port=29511 nccl_test.py
  ```
- **卡死定位**：`sudo py-spy dump --pid <worker_pid>` 直接看 Python 栈（本次定位到 `ncclCommInitRank`）
- **RDMA 探针**：最小容器 + 小 tensor 复现 `ibv_reg_mr` 失败，区分"显存不够"与"注册内存耗尽"
- **大文件分发**：QSFP 直连 rsync 实测 **480MB/s**（167GB 约 5.5 分钟）；docker 镜像用 `docker save | ssh docker load`
- **HF hub 缓存布局**：`cp -al` 硬链接 local-dir → `models--<org>--<name>/snapshots/<rev>/`，离线加载零拷贝

## 🚀 快速复现

```bash
git clone https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark.git
cd DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
cp .env.dspark.example .env.dspark   # 按本仓库 docs 填双机地址/HCA/GID
./start-deepseek-v4-flash-dspark.sh  # worker 先、head 后，自动打热修复补丁
```

管理：`./status-…` / `./logs-…` / `./stop-…`。视觉：`.env.dspark` 里 `ENABLE_VL_SIDECAR=1` +
把 `docker-compose.vl-sidecar.yml` 的 NCCL 改为 Socket（见踩坑 #4）。

**注意**：主服务健康时再跑 `start-…` 会被拒绝（"container already exists"），这是防呆设计，先 `stop`。

**强烈建议**：首次跑通后立即应用 **spin-wait 热修复**（一行补丁 + 薄层镜像，10 分钟搞定），
否则持续高负载下 SoC 会冲到 90℃ 以上（我们实测峰值 95℃，逼近热关机）。
步骤与实测数据：[docs/vllm-spinwait-thermal-fix.md](docs/vllm-spinwait-thermal-fix.md)。

## 🗂 仓库内容

- `README.md` / `README.en.md` —— 本文 / English version
- `tests/nccl_test.py` —— 双机 NCCL 最小验证脚本
- `docs/` —— 配置文件参考（`.env.dspark` 实战版、sidecar compose 改动）、
  [运维加固与视觉外迁](docs/ops-autostart-and-remote-vision.md)（2026-08-16 更新）、
  [vLLM spin-wait 发热修复实录](docs/vllm-spinwait-thermal-fix.md)（2026-08-19 更新）
- `scripts/autostart/` —— 双机 user 级 systemd 自启 + 三级自愈脚本 + 内核加固（免 root 安装）

## 👤 作者

**壹我AI（Evo AI）** · [@Deep-AI-Evo](https://github.com/Deep-AI-Evo)

相关系列：[Qwen3.8-27B-NVFP4 单机部署教程](https://github.com/Deep-AI-Evo/qwen3.8-27b-nvfp4-dgx-spark-tutorial)
