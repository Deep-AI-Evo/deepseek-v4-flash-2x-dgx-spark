# vLLM Spin-Wait 发热修复：SoC 降温 12℃ 严格 A/B 实录

> 📌 **2026-08-19 运行态更新**。适用于本仓库的双机 TP=2 部署（也是收益最大的场景）。
>
> **English summary**: vLLM's `SpinCondition.wait()` spins on performance cores for the
> entire request lifetime because `busy_loop_s` defaults to 1s while decode messages arrive
> every few ms — the sleep branch is never taken. On GB10 (CPU+GPU in one package) this
> pushes the SoC past 90℃ while aggregate CPU looks ~20% — we measured a **95℃ peak**
> under sustained real-world load (OS force-shutdown is at 104.8℃). One-line fix
> (`busy_loop_s: float = 1` → `0.002`). In a controlled A/B test on 2× DGX Spark TP=2
> DeepSeek-V4-Flash (same prompt, 120s per run, 1/2/3 concurrency, cooled to <56℃ between
> runs, full image swap between arms): **head-node SoC peak dropped 11.6-12.7℃**
> (91-93℃ → 78-81℃) at every concurrency level, worker node roughly unchanged (its heat is
> real engine work + NCCL polling, plus a warmer chassis position), throughput unchanged
> (<3% noise). Steps below are Chinese; the patch Dockerfile in §3 is self-explanatory.

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

## 2. 实测数据（本仓库环境，严格 A/B 对比）

测试方法（2026-08-19）：同一 prompt（max_tokens=4000），每个版本分别测 1/2/3 并发，
每档持续负载 120 秒，双机每 30 秒采样，**档间冷却至双机 <56℃ 再开始下一档**，
两臂之间完整切换镜像重启服务。下表为每档 120 秒窗口内的**峰值温度**：

| 并发 | 版本 | head CPU 峰值 | worker CPU 峰值 | head GPU | worker GPU | 总 decode |
|---|---|---|---|---|---|---|
| 1 | 原版（1s） | 91.2℃ | 84.1℃ | 68℃ | 70℃ | 40.5 tok/s |
| 1 | spinfix | **78.5℃** | **81.5℃** | 68℃ | 71℃ | 39.8 tok/s |
| 2 | 原版（1s） | 93.1℃ | 86.9℃ | 69℃ | 73℃ | 59.3 tok/s |
| 2 | spinfix | **80.8℃** | **87.1℃** | 70℃ | 73℃ | 58.7 tok/s |
| 3 | 原版（1s） | 91.6℃ | 86.2℃ | 69℃ | 73℃ | 72.8 tok/s |
| 3 | spinfix | **80.0℃** | **86.0℃** | 70℃ | 73℃ | 70.9 tok/s |

结论：

- **head 节点三档稳定降温 11.6~12.7℃**（峰值从 91-93℃ 压到 78-81℃），空转核消失；
- **worker 节点基本持平**（±3℃ 以内）：补丁消除的是等待空转，worker 的热量主要来自
  引擎真实计算与 NCCL 通信线程轮询，且该机箱散热条件略差（任何状态下都比 head 热 2-4℃）；
- **吞吐无损失**：三档 decode 差异均 <3%，属测量噪声；
- GPU 温度两臂基本不变——发热源本来就不是 GPU；
- 日常持续高负载下，补丁前实测峰值曾达 **95℃**（逼近降频/关机风险线），补丁后
  3 分钟满负载峰值 89.3℃ 并开始回落，未再进入 90℃+ 区间。

原作者在同配置（2× GB10、TP=2、vLLM 0.25.2、DeepSeek V4 Flash FP8）测得 SoC 平均
**−24.2℃**、vLLM CPU 占用 333.6%→88.7%、吞吐不变。

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
