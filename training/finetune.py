#!/usr/bin/env python3
"""LoRA fine-tune of the served model, single- or multi-node.

Trains a LoRA adapter for Qwen2.5-1.5B-Instruct (the model charts/vllm serves) and
reports training cost the same way the inference benchmark reports serving cost:
GPU-hours and $ per 1M trained tokens.

Launch with torchrun; on Slurm, training/slurm/finetune.sbatch does that per node.

  # local CPU smoke test (2 processes, gloo, tiny model)
  torchrun --nproc_per_node 2 training/finetune.py --model yujiepan/qwen2.5-tiny-random \\
      --dataset synthetic --max-steps 4 --cpu

The output directory holds the adapter (adapter_config.json, adapter_model.safetensors),
the tokenizer, and training-report.json. vLLM serves the adapter with --enable-lora.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import torch
import torch.distributed as dist
from datasets import Dataset, load_dataset
from peft import LoraConfig, get_peft_model
from transformers import AutoModelForCausalLM, AutoTokenizer, Trainer, TrainingArguments

IGNORE = -100


def synthetic_rows(n: int) -> list[dict]:
    """Deterministic arithmetic Q&A, enough to check that loss falls without a download."""
    rows = []
    for i in range(n):
        a, b = 3 + i % 17, 5 + (i * 7) % 23
        rows.append({"instruction": f"What is {a} plus {b}?", "input": "", "output": f"{a} plus {b} is {a + b}."})
    return rows


def load_rows(args) -> Dataset:
    if args.dataset == "synthetic":
        return Dataset.from_list(synthetic_rows(args.max_samples or 256))
    ds = load_dataset(args.dataset, split=args.dataset_split)
    if args.max_samples:
        ds = ds.select(range(min(args.max_samples, len(ds))))
    return ds


def to_messages(row: dict) -> tuple[list[dict], str]:
    """Alpaca-style row -> (chat prompt messages, answer)."""
    prompt = row["instruction"] if not row.get("input") else f"{row['instruction']}\n\n{row['input']}"
    return [{"role": "user", "content": prompt}], row["output"]


def make_tokenize(tokenizer, max_len: int):
    has_template = bool(getattr(tokenizer, "chat_template", None))

    def tokenize(row: dict) -> dict:
        messages, answer = to_messages(row)
        if has_template:
            prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        else:
            prompt = f"User: {messages[0]['content']}\nAssistant: "
        prompt_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
        answer_ids = tokenizer(answer, add_special_tokens=False)["input_ids"] + [tokenizer.eos_token_id]
        input_ids = (prompt_ids + answer_ids)[:max_len]
        # Train on the answer only: the prompt tokens carry no loss.
        labels = ([IGNORE] * len(prompt_ids) + answer_ids)[:max_len]
        return {"input_ids": input_ids, "labels": labels}

    return tokenize


class CountingCollator:
    """Pads a batch and counts the tokens that carry loss, so tokens/s is exact."""

    def __init__(self, pad_id: int):
        self.pad_id = pad_id
        self.trained_tokens = 0

    def __call__(self, features: list[dict]) -> dict:
        width = max(len(f["input_ids"]) for f in features)
        ids, labels, mask = [], [], []
        for f in features:
            pad = width - len(f["input_ids"])
            ids.append(f["input_ids"] + [self.pad_id] * pad)
            labels.append(f["labels"] + [IGNORE] * pad)
            mask.append([1] * len(f["input_ids"]) + [0] * pad)
        batch = {
            "input_ids": torch.tensor(ids),
            "labels": torch.tensor(labels),
            "attention_mask": torch.tensor(mask),
        }
        self.trained_tokens += int((batch["labels"] != IGNORE).sum())
        return batch


def all_ranks_sum(value: int, device: torch.device) -> int:
    if not (dist.is_available() and dist.is_initialized()):
        return value
    t = torch.tensor([value], dtype=torch.long, device=device)
    dist.all_reduce(t)
    return int(t.item())


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default="Qwen/Qwen2.5-1.5B-Instruct")
    p.add_argument("--dataset", default="yahma/alpaca-cleaned", help="Hugging Face dataset, or 'synthetic'")
    p.add_argument("--dataset-split", default="train")
    p.add_argument("--max-samples", type=int, default=20000)
    p.add_argument("--max-seq-len", type=int, default=1024)
    p.add_argument("--epochs", type=float, default=1.0)
    p.add_argument("--max-steps", type=int, default=-1, help="overrides --epochs when > 0")
    p.add_argument("--per-device-batch", type=int, default=8)
    p.add_argument("--grad-accum", type=int, default=2)
    p.add_argument("--lr", type=float, default=2e-4)
    p.add_argument("--lora-r", type=int, default=16)
    p.add_argument("--lora-alpha", type=int, default=32)
    p.add_argument("--output-dir", default="outputs/qwen2.5-1.5b-lora")
    p.add_argument("--gpu-hourly-usd", type=float, default=0.0, help="on-demand price per GPU node, for the report")
    p.add_argument("--gpus-per-node", type=int, default=1, help="to turn node price into GPU-hour price")
    p.add_argument("--label", default="")
    p.add_argument("--cpu", action="store_true", help="CPU/gloo run for smoke tests")
    args = p.parse_args()

    rank = int(os.environ.get("RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))
    use_bf16 = not args.cpu and torch.cuda.is_available() and torch.cuda.is_bf16_supported()

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16 if use_bf16 else torch.float32)
    model = get_peft_model(
        model,
        LoraConfig(r=args.lora_r, lora_alpha=args.lora_alpha, lora_dropout=0.05,
                   target_modules="all-linear", task_type="CAUSAL_LM"),
    )
    if rank == 0:
        model.print_trainable_parameters()

    rows = load_rows(args)
    train = rows.map(make_tokenize(tokenizer, args.max_seq_len), remove_columns=rows.column_names)
    collator = CountingCollator(tokenizer.pad_token_id)

    targs = TrainingArguments(
        output_dir=args.output_dir,
        per_device_train_batch_size=args.per_device_batch,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        lr_scheduler_type="cosine",
        warmup_steps=0.03,  # transformers 5: a float below 1 is a fraction of total steps
        logging_steps=10,
        save_strategy="no",
        report_to="none",
        bf16=use_bf16,
        use_cpu=args.cpu,
        remove_unused_columns=False,
        ddp_find_unused_parameters=False,
        dataloader_num_workers=0,  # the collator counts tokens in-process
    )
    trainer = Trainer(model=model, args=targs, train_dataset=train, data_collator=collator)

    start = time.perf_counter()
    result = trainer.train()
    wall = time.perf_counter() - start

    device = torch.device("cuda", torch.cuda.current_device()) if use_bf16 else torch.device("cpu")
    tokens = all_ranks_sum(collator.trained_tokens, device)

    if trainer.is_world_process_zero():
        out = Path(args.output_dir)
        trainer.model.save_pretrained(out)
        tokenizer.save_pretrained(out)
        gpu_hours = wall * world / 3600
        gpu_hourly = args.gpu_hourly_usd / max(args.gpus_per_node, 1)
        cost = gpu_hours * gpu_hourly
        report = {
            "label": args.label,
            "model": args.model,
            "dataset": args.dataset,
            "world_size": world,
            "nodes": int(os.environ.get("SLURM_NNODES", "1")),
            "steps": result.global_step,
            "train_loss": round(result.training_loss, 4),
            "wall_s": round(wall, 1),
            "trained_tokens": tokens,
            "trained_tokens_per_s": round(tokens / wall, 1) if wall > 0 else 0.0,
            "gpu_hours": round(gpu_hours, 4),
            "gpu_hourly_usd": gpu_hourly,
            "cost_usd": round(cost, 4),
            "usd_per_1m_trained_tokens": round(cost / tokens * 1e6, 4) if tokens and cost else None,
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        (out / "training-report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
