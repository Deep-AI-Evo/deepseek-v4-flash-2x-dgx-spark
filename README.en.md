<div align="center">

# DeepSeek-V4-Flash on 2× DGX Spark — Field Notes

**167GB FP8 MoE · 2-node TP=2 · 200G RoCE direct cable · 1M context · vision coexistence**
**Every pitfall documented, official benchmarks cross-checked**

[![Model](https://img.shields.io/badge/🤗%20Model-DeepSeek--V4--Flash--0731-blue)](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)
[![Recipe](https://img.shields.io/badge/Recipe-MiaAI--Lab%20DSpark-green)](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)
[![Platform](https://img.shields.io/badge/Platform-2%C3%97%20DGX%20Spark%20GB10-76b900)](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
[![License](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

### 🌐 **[切换到中文](README.md)**

</div>

---

> Date: 2026-08-15　Setup: 2× NVIDIA DGX Spark (GB10, 128GB unified memory), QSFP direct attach
> Built on the [MiaAI-Lab DSpark recipe](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark) — credit to the authors.

> 📌 **2026-08-16 ops update**: switched to a **text-only profile (600K context × 3 concurrent,
> util 0.80)** and moved vision to a remote RTX Pro 5000 (Qwen3.8-27B-NVFP4, called via MCP over
> LAN HTTP), plus dual-node systemd autostart, kernel hardening, and a one-click start button on
> the monitor dashboard. Rationale and full details (Chinese):
> [docs/ops-autostart-and-remote-vision.md](docs/ops-autostart-and-remote-vision.md).
> Below is the original day-one write-up (1M context + co-located vision), kept for reference.

> 🌡️ **2026-08-19 ops update**: applied the vLLM spin-wait thermal fix — the default
> `busy_loop_s = 1` keeps 3-4 performance cores spinning at 100% for the whole request
> (aggregate CPU looks ~20% while the SoC bakes at 90℃). A one-line patch (`1` → `0.002`)
> dropped CPU temperature by 6.8-14.8℃ under identical load with zero throughput cost.
> Measurements, dual-node patch steps and rollback:
> [docs/vllm-spinwait-thermal-fix.md](docs/vllm-spinwait-thermal-fix.md) (Chinese, with an
> English summary at the top; credits to nacyot's original analysis and drowzeys' write-up).

## 📌 Why two machines

DeepSeek-V4-Flash-0731 is an FP8-quantized MoE (256 experts / top-6, 43 layers) weighing
**166.9GB**. A single DGX Spark has ~119GB of usable unified memory — **it physically does not
fit on one node**. The answer is 2-node tensor parallelism (TP=2): each node carries ~84GB of
weights and NCCL runs over the direct QSFP cable.

## 🏗 Final architecture

```
┌─────────────────────┐   QSFP direct, RoCE 200G  ┌─────────────────────┐
│  DGX Spark (head)   │  18.18.11.1 ↔ 18.18.11.2  │  DGX Spark (worker) │
│                     │  18.18.13.1 ↔ 18.18.13.2  │                     │
│  vLLM rank0 (docker)│ ◄── NCCL (RoCEv2) ──────► │  vLLM rank1 (docker)│
│  API :8888 (text)   │                           │                     │
│  API :8889 (vision) │ ◄── NCCL (TCP Socket) ──► │  VL sidecar rank1   │
└─────────────────────┘                           └─────────────────────┘
```

- **Text**: `deepseek-v4-flash-0731`, 1M context (1,048,576 tokens), KV cache ~1.3–2.7M tokens, DSpark MTP×5 speculative decoding
- **Vision**: Qwen3-VL-4B sidecar (the model itself is text-only; vision comes from the sidecar, pluggable into agents via the `ds4f-vision` MCP)

## 📊 Measured performance

**Decode (official benchmark-0731.py methodology, natural text)**

| Case | This cluster | Published | Achieved |
|---|---|---|---|
| 256 tok, c=1 | 48–64 tok/s | 75.4 tok/s | 64–85% |
| 256 tok, c=4 | 25–31 tok/s | 46.8 tok/s | 54–67% |
| SETUP.md reference | — | ~52 tok/s | **met** |

**Prefill (single stream, cold prefixes) — matches or beats published numbers at long context**

| Input | TTFT | Prefill speed | Published |
|---|---|---|---|
| 8K | 8.8 s | 930 tok/s | 1713 tok/s |
| 32K | 17.4 s | **1880 tok/s** | 1428 tok/s |
| 128K | 76.0 s | **1725 tok/s** | 1665 tok/s |
| 900K–1M | est. 10–17 min | — | 875 tok/s @900K |

**Capacity**: `max_num_seqs=6`; KV pool 2.7M tokens (text profile, util 0.835) → ~2.6 concurrent
full-1M requests. An official high-throughput profile (200K context + 16 seqs) is available.

## 🕳 Pitfalls (ordered by value)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Stock vLLM 0.27 won't start | GB10 (SM121) lacks FlashInfer's sparse MLA decode API | Use the DSpark image `ghcr.io/anemll/dspark-vllm-gx10` |
| 2 | NCCL cross-node init hangs | NetworkManager auto-assigned a 169.254 link-local address; NCCL bootstrap picked it | Configure static IPs via nmcli (`ip addr add` gets reverted by NM!) |
| 3 | Dual-rail NCCL `ibv_modify_qp` fails | GID tables differ per node: head's IPv4 GID is index 3, worker's is 5 | Resolve GID per node from sysfs (recipe auto-does this); if pinning: `WORKER_NCCL_IB_GID_INDEX=5` |
| 4 | Vision sidecar always crashes | **RDMA registerable memory exhausted**: with ~93GB locked by the main model, `ibv_reg_mr` always fails (proven by a minimal probe; unrelated to desktop apps) | Switch the sidecar's NCCL to TCP sockets (a 4B model's TP traffic is tiny; 0.44ms/allreduce, no perceptible cost) |
| 5 | HF download 401 | Newer huggingface_hub defaults to the xet backend, whose CDN is unreachable | `HF_HUB_DISABLE_XET=1` + hf-mirror |
| 6 | ghcr pull stalls | Direct ghcr.io large blobs run at 0 B/s | NJU mirror `ghcr.nju.edu.cn` (78MB/s with parallel layers) |
| 7 | Ray `ActorHandleNotFound` | A previously failed vLLM left a dirty Ray session | `ray stop --force` on both nodes before relaunch |
| 8 | "Speed is half of published" | Measurement contamination: requests carried `thinking=max` and timing included TTFT | Compare with the official `scripts/benchmark-0731.py` |
| 9 | Dual rail is *slower* | Small-message allreduce is latency-bound; rail striping adds overhead | Keep the documented single rail |
| 10 | vLLM demands FP8 KV | DeepSeek V4 fp8_ds_mla layout is strict | `--kv-cache-dtype fp8` (the DSpark image uses nvfp4_ds_mla) |

## 🔧 Useful tools & tricks

- **NCCL isolation test** (verify 2-node NCCL without vLLM/Ray in the way):
  ```bash
  # both ends (node-rank 0/1), see tests/nccl_test.py
  torchrun --nnodes=2 --nproc-per-node=1 --node-rank=0 \
    --master-addr=18.18.11.1 --master-port=29511 nccl_test.py
  ```
- **Hang localization**: `sudo py-spy dump --pid <worker_pid>` prints the Python stack
  (this is how we pinned the hang to `ncclCommInitRank`)
- **RDMA probe**: minimal container + tiny tensor to reproduce `ibv_reg_mr` failure —
  distinguishes "out of GPU memory" from "RDMA registration exhausted"
- **Bulk transfer**: rsync over the QSFP cable sustains **480MB/s** (167GB in ~5.5 min);
  move docker images with `docker save | ssh docker load`
- **HF hub cache layout**: `cp -al` hardlinks a local-dir download into
  `models--<org>--<name>/snapshots/<rev>/` for zero-copy offline loading

## 🚀 Quick reproduction

```bash
git clone https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark.git
cd DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
cp .env.dspark.example .env.dspark   # fill in both nodes' IPs/HCA/GID per this repo's docs
./start-deepseek-v4-flash-dspark.sh  # worker-first, then head; hotfixes auto-applied
```

Management: `./status-…` / `./logs-…` / `./stop-…`. Vision: set `ENABLE_VL_SIDECAR=1` in
`.env.dspark` **and** switch the sidecar compose's NCCL to Socket (see pitfall #4).

**Note**: re-running `start-…` while the main service is healthy is refused
("container already exists") — that's a guard, run `stop` first.

## 🗂 Repository contents

- `README.md` / `README.en.md` — 中文 / this page
- `tests/nccl_test.py` — minimal 2-node NCCL verification
- `docs/` — battle-tested config references (`.env.dspark`, sidecar compose diff)

## 👤 Author

**Evo AI (壹我AI)** · [@Deep-AI-Evo](https://github.com/Deep-AI-Evo)

Related: [Qwen3.8-27B-NVFP4 single-node deployment](https://github.com/Deep-AI-Evo/qwen3.8-27b-nvfp4-dgx-spark-tutorial)
