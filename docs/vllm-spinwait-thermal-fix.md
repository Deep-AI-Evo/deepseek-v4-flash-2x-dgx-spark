# vLLM Spin-Wait 发热修复：CPU 大核空转降温 15℃+ 实录

> 📌 **2026-08-19 运行态更新**。适用于本仓库的双机 TP=2 部署（也是收益最大的场景）。
>
> **English summary**: vLLM's `SpinCondition.wait()` spins on performance cores for the
> entire request lifetime because `busy_loop_s` defaults to 1s while decode messages arrive
> every few ms — the sleep branch is never taken. On GB10 (CPU+GPU in one package) this
> pushes the SoC past 90℃ while aggregate CPU looks ~20% — we measured a **95℃ peak**
> under sustained load (OS force-shutdown is at 104.8℃). One-line fix
> (`busy_loop_s: float = 1` → `0.002`), zero throughput cost. Measured here on 2× DGX Spark
> TP=2 DeepSeek-V4-Flash: **−14.8℃ / −6.8℃** SoC temperature at 25s/50s under identical load
> (8 concurrent × 1200 tokens), decode throughput unchanged (~40→44 tok/s, within noise).
> Steps below are Chinese; the patch Dockerfile in §3 is self-explanatory.

## 致谢与原始出处

- 原始诊断与测量：**nacyot**（韩文）：[LLM 추론에서 가장 뜨거운 것은 GPU가 아니었다](https://nacyot.github.io/artifacts/vllm-spin-wait-gb10/)
- 英文整理与补丁工具：**drowzeys**：[vllm-gb10-spin-wait-fix](https://github.com/drowzeys/vllm-gb10-spin-wait-fix)

本文是上述方案在本仓库部署环境（2× DGX Spark GB10，TP=2 `mp`，vLLM 0.25.2，
`ghcr.io/anemll/dspark-vllm-gx10:0.1.1`）上的落地实录。所有诊断思路与数据结论归原作者。

## 1. 现象与根因

**现象**：双机跑 DeepSeek-V4-Flash 推理时，聚合 CPU 利用率不到 20%，但 SoC/CPU 温度
持续 90℃ 上下，**长时间高负载实测峰值达 95℃**——已逼近危险区（GB10 的 OS 强制关机
阈值为 104.8℃，社区有机型在 87℃ 附近就触发关机），GPU 反而不算热。

**根因**：vLLM 进程间通过共享内存环形队列通信，读端 `SpinCondition.wait()` 采用
"先空转 `busy_loop_s` 秒、再睡眠等 zmq 唤醒"的混合策略。但 `busy_loop_s` 默认 **1 秒**，
而解码时消息每隔几毫秒就到达，睡眠分支**永远不会被执行**——3-4 个 CPU 大核在每个请求的
整个生命周期里 100% 空转，每核白烧 10-20W。GB10 把 20 核 CPU 和 GPU 封在同一颗 SoC 里
共享散热预算，空转的性能核紧挨 GPU，热量直接叠在 GPU 上。

**为什么聚合利用率看不出问题**：20 核里 4 核跑满，聚合后只有 ~20%，一切看起来"正常"。
必须看单核：`mpstat -P ALL` 下 3-4 个性能核（本机是 core 15/16/17/19）持续 ~100%。

**为什么 TP=2 收益最大**：每个空闲的 rank 都坐在 `shm_broadcast` 里等消息，TP=2 双机
有多个等待者。TP=1 单卡部署没有第二个 rank，补丁前后无差异（上游社区已实测），
但补丁本身无害。

## 2. 实测数据（本仓库环境）

负载：8 并发 × 1200 max_tokens，模型 deepseek-v4-flash-0731。补丁前后各采样 25s / 50s
（受控短测只跑到 89.2℃；日常持续高负载下实测峰值曾达 **95℃**，已贴近降频/关机风险线）：

| 指标 | 补丁前 | 补丁后 | 变化 |
|---|---|---|---|
| CPU（SoC）温度 @25s | 84.3℃ | 69.5℃ | **−14.8℃** |
| CPU（SoC）温度 @50s | 89.2℃ | 82.4℃ | **−6.8℃** |
| 空转核（>70% 单核） | 4 个（71-100%） | 2 个波动（引擎真实工作） | 明显减少 |
| GPU 温度 | 63→67℃ | 61→65℃ | −2℃ |
| 单流 decode | 40.4-41.5 tok/s | 40.4-44.3 tok/s | **无损失** |

注：补丁后测试时机器带有基线测试的残余热量，稳态差距预计更大；原作者在同配置
（2× GB10、TP=2、vLLM 0.25.2、DeepSeek V4 Flash FP8）测得 SoC 平均 **−24.2℃**、
vLLM CPU 占用 333.6%→88.7%、吞吐不变。

## 3. 操作步骤

### 3.1 诊断确认（只读）

```bash
# 负载下看单核：3-4 个性能核 ~100% 而聚合低 → 中招
mpstat -P ALL 1 1 | awk '$2 ~ /^[0-9]+$/ {b=100-$NF; if(b>70) print $2, b"%"}'

# 确认容器内是 buggy 代码
docker exec deepseek-v4-flash-vllm-dspark-1 python3 -c "
import inspect, vllm.distributed.device_communicators.shm_broadcast as m
print([l.strip() for l in inspect.getsource(m).splitlines() if 'busy_loop_s' in l and 'float' in l])"
# 输出 busy_loop_s: float = 1, → 未修复
```

### 3.2 备份

```bash
mkdir -p ~/backups/spinfix-$(date +%Y%m%d)
cp ~/projects/dspark-recipe/.env.dspark ~/projects/dspark-recipe/docker-compose.dspark.yml \
   ~/backups/spinfix-$(date +%Y%m%d)/
docker inspect deepseek-v4-flash-vllm-dspark-1 > ~/backups/spinfix-$(date +%Y%m%d)/head-container-inspect.json
# worker 节点同样备份 .env.dspark 和容器 inspect
```

### 3.3 构建补丁镜像（双机各构建一次）

```dockerfile
FROM ghcr.io/anemll/dspark-vllm-gx10:0.1.1
RUN f=$(find /usr/local/lib -name shm_broadcast.py -path "*device_communicators*" 2>/dev/null | head -1); \
    if [ -z "$f" ]; then echo "shm_broadcast.py NOT FOUND"; exit 1; fi; \
    sed -i 's/busy_loop_s: float = 1,/busy_loop_s: float = 0.002,/' "$f"; \
    grep -q "busy_loop_s: float = 0.002" "$f" && echo "patched: $f"
```

```bash
docker build -t ghcr.io/anemll/dspark-vllm-gx10:0.1.1-spinfix .
```

薄层构建只改一行、几 KB，**原镜像标签不动**，随时可回滚。

### 3.4 切换镜像并重启

双机的 `~/projects/dspark-recipe/.env.dspark`：

```bash
DSPARK_VLLM_IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1-spinfix
```

然后在 head 节点：

```bash
systemctl --user restart dspark-vllm.service
```

双机 TP=2 冷启动加载模型需几分钟到十几分钟（启动脚本最多等 20 分钟），
期间 API 不可用，请选择流量低谷操作。

### 3.5 验证

```bash
# 1. 补丁生效（两个节点都查）
docker exec deepseek-v4-flash-vllm-dspark-1 python3 -c "..."   # 应输出 0.002

# 2. 相同负载对比温度与单核占用（见 §2）

# 3. 吞吐回归：单流 decode tok/s 应与补丁前持平
```

### 3.6 回滚

双机 `.env.dspark` 的 `DSPARK_VLLM_IMAGE` 改回 `ghcr.io/anemll/dspark-vllm-gx10:0.1.1`，
`systemctl --user restart dspark-vllm.service` 即可。

## 4. 补充说明

- 上游 vLLM main 至今仍硬编码 1 秒默认值（0.25.x–0.27.x 均存在），升级镜像后
  **需要重新打补丁**；若未来上游接受环境变量化（`VLLM_BUSY_LOOP_S`），设置
  `VLLM_BUSY_LOOP_S=0.002` 即可，无需改镜像。
- 该修复不改变任何模型输出：只影响线程等待策略，采样、kernel、权重均不受影响。
- 若打补丁后温度仍不理想，可考虑 GPU 限频（`nvidia-smi -lgc`）——牺牲性能换温度，
  非首选，详见原仓库 MITIGATIONS.md。
- 监控侧配合：本仓库监控面板已将 CPU/GPU 温度分开展示（2026-08-18 更新），
  可直接观察补丁前后的 CPU 温度曲线变化。
