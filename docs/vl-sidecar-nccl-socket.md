# VL sidecar NCCL 改 TCP Socket 的改动

文件：`docker-compose.vl-sidecar.yml`（MiaAI-Lab 配方仓库）

```diff
-      NCCL_NET: "${NCCL_NET:-IB}"
-      NCCL_IB_DISABLE: "${NCCL_IB_DISABLE:-0}"
+      NCCL_NET: "Socket"
+      NCCL_IB_DISABLE: "1"
```

原因：主模型锁死 ~93GB 后系统 RDMA 可注册内存耗尽，sidecar 走 RoCE 必崩
（`ibv_reg_mr_iova2: Cannot allocate memory`）。4B 小模型 TP 通信量极小，
TCP over 200GbE 实测 0.44ms/次 allreduce，无性能影响。主模型保持 RoCE 不变。
