import os
import torch
import torch.distributed as dist

dist.init_process_group("nccl")
rank = dist.get_rank()
x = torch.ones(1024, 1024, device="cuda") * (rank + 1)
dist.all_reduce(x)
torch.cuda.synchronize()
print(f"[rank {rank}] all_reduce OK, sum={x[0,0].item()} (expect 3.0)", flush=True)
dist.destroy_process_group()
