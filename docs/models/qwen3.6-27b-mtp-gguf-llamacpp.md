# Qwen3.6-27B-MTP GGUF on llama.cpp

This file captures the model-specific llama.cpp settings that were actually validated in this repo for `unsloth/Qwen3.6-27B-MTP-GGUF`.

It is intentionally model-specific. The idea is to clone this file for other GGUFs later instead of mixing all tuning notes into one generic llama.cpp document too early.

## Model Snapshot

- Hugging Face model: `unsloth/Qwen3.6-27B-MTP-GGUF`
- Current local quant in this repo: `Qwen3.6-27B-Q4_K_M-mtp.gguf`
- API alias exposed by llama.cpp: `Qwen3.6-27B-MTP GGUF`
- Architecture family: Qwen3.6 27B with MTP-trained GGUF
- Native context length from the model card: `262,144`
- Long-context extension mentioned by the model card: up to about `1,010,000` tokens with YaRN-style scaling in frameworks that support it

Source references used for this profile:

- Hugging Face model card: `https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF`
- Repo runtime config: `hermes_config.yaml`
- Repo launcher: `start_llamacpp.ps1`

## Current Repo Baseline

These are the settings the repo currently starts with when using `./start_llamacpp.ps1`.

### Runtime

- Backend: `hip`
- Binary selection: latest installed `b*-win-hip-radeon-x64` unless overridden
- Host/API: `http://127.0.0.1:8080/v1`
- Alias: `Qwen3.6-27B-MTP GGUF`
- Parallel slots: `1`
- Flash attention: `on`
- Reasoning mode: `off`
- Chat template: `tools/llama.cpp/templates/Qwen3.5-4B.jinja`

### Sampling

- `temperature: 0.7`
- `top_p: 0.80`
- `top_k: 20`
- `min_p: 0.0`
- `presence_penalty: 1.5`
- `repeat_penalty: 1.0`

### Context and speculative decoding

- Configured context window: `98,304`
- Speculative mode: `draft-mtp`
- Speculative draft tokens: `4`

Equivalent llama.cpp flags in this repo are effectively:

```text
--ctx-size 98304
--parallel 1
--flash-attn on
--spec-type draft-mtp
--spec-draft-n-max 4
```

## Why These Settings

### Context window

The Qwen3.6 model card recommends keeping long context available and explicitly warns that dropping too low can hurt thinking-heavy behavior. The official guidance says:

- default native context is `262,144`
- if you must reduce context for memory reasons, try to stay at `128K` or above where possible

Our local finding was more pragmatic:

- `98,304` is a good fit on this machine for Hermes coding sessions
- it reduces forced session splitting compared with `64K`
- it is materially easier to run locally than pushing straight to `128K` or the full native `262K`
- for this host, the real bottleneck is prompt/prefill pressure, so chasing the maximum theoretical context window is usually the wrong tradeoff

Practical conclusion:

- Use `98,304` as the current stable local default for this machine
- only increase toward `128K+` if the specific workflow is clearly context-bound and you accept slower prompt processing / larger KV pressure

### Flash attention

The Unsloth llama.cpp example for this model explicitly uses flash attention:

```text
-fa on
```

That matches this repo's launcher, which sets:

```text
--flash-attn on
```

Recommendation for this model:

- keep flash attention enabled by default
- only disable it if a backend-specific regression forces it

### MTP / speculative decoding

The model card and Unsloth examples show MTP as the intended fast path for the MTP GGUFs. Their llama.cpp example uses:

```text
--spec-type draft-mtp --spec-draft-n-max 2
```

This repo currently uses a slightly more aggressive local setting:

```text
--spec-type draft-mtp --spec-draft-n-max 4
```

That was chosen because the model is an MTP-trained GGUF and the local target workflow is interactive coding, where decode speed matters.

## Local Findings: When MTP Helps and When It Does Not

These are the important non-obvious findings from local validation on this machine.

### When MTP should stay on

Keep MTP on when:

- the workload is decode-heavy rather than prompt-heavy
- you expect longer answer generation phases
- you want the best interactive feel while the model is already generating tokens
- you are using the actual MTP GGUF, not a non-MTP variant

Why:

- local measurements showed that turning MTP off roughly halved decode speed in the tested setup
- MTP was the main reason the Q8 run stayed close to the faster local decode profile

### When MTP actively hurts performance

MTP significantly worsens prefill latency. Measured on this machine at ~13k prompt tokens:

- **MTP on: 16.4s prefill**
- **MTP off: 2.9s prefill** (5.7× faster)

MTP is therefore a net negative when:

- the workload is prompt-heavy (large retained context, long coding transcripts, big tool output history)
- sessions accumulate context over time (agentic coding loops)
- prefill latency, not decode latency, is the user-visible bottleneck

At context sizes above ~64k, the prefill penalty from MTP dominates completely. MTP does not fix prefill — it makes it meaningfully worse.

### Current recommendation

- **Coding / agentic sessions (growing context):** MTP off, Flash Attention on, context ~64k
- **Generative tasks (long outputs, small prompt):** MTP on — the ~2× decode advantage is real
- Do not default MTP on for mixed or prompt-heavy workloads

## Quantization Notes

The current repo path uses `Q4_K_M` for the MTP quant. Local observations from earlier testing:

- `Q8_0 + MTP` was viable as a memory-vs-quality option, but not a large latency win for prompt-heavy Hermes usage
- `Q8_0 + MTP off` sharply reduced decode speed and was not attractive for the current coding workflow
- the main lever for perceived responsiveness remained context pressure, not just quant choice

Practical conclusion:

- `Q4_K_M-mtp` remains a solid default here
- consider `Q8_0` only when you want a different memory / quality tradeoff, not because you expect a dramatic prompt-latency improvement

## Official Sampling Recommendations vs Repo Defaults

The Qwen3.6 guidance from the model card recommends:

- Thinking mode, general tasks: `temperature 1.0`, `top_p 0.95`, `top_k 20`, `min_p 0.0`, `presence_penalty 0.0`, `repetition_penalty 1.0`
- Thinking mode, precise coding: `temperature 0.6`, `top_p 0.95`, `top_k 20`, `min_p 0.0`, `presence_penalty 0.0`, `repetition_penalty 1.0`
- Instruct / non-thinking mode: `temperature 0.7`, `top_p 0.80`, `top_k 20`, `min_p 0.0`, `presence_penalty 1.5`, `repetition_penalty 1.0`

This repo currently matches the official instruct / non-thinking profile almost exactly:

- `temperature 0.7`
- `top_p 0.80`
- `top_k 20`
- `min_p 0.0`
- `presence_penalty 1.5`
- `repeat_penalty 1.0`

That is intentional because Hermes here is being run more like a direct coding assistant than a full exposed thinking-mode benchmark setup.

## Output Length Guidance

The model card also recommends:

- around `32,768` max output tokens for most real tasks
- up to `81,920` for very hard reasoning / coding benchmark style tasks

For local Hermes use, treat those as upper ceilings, not defaults. Large output budgets can worsen responsiveness and increase context carry-over costs in later turns.

## Suggested Launch Template For This Machine

For this exact model family on this host, the local default should remain conceptually equivalent to:

```text
llama-server.exe \
  --host 127.0.0.1 \
  --port 8080 \
  --model <Qwen3.6-27B-Q4_K_M-mtp.gguf> \
  --alias "Qwen3.6-27B-MTP GGUF" \
  --ctx-size 98304 \
  --parallel 1 \
  --flash-attn on \
  --spec-type draft-mtp \
  --spec-draft-n-max 4 \
  --gpu-layers all
```

And the paired sampling profile should stay:

```text
temperature=0.7
top_p=0.80
top_k=20
min_p=0.0
presence_penalty=1.5
repeat_penalty=1.0
```

## Change Checklist For Other Models Later

When cloning this file for another model, update at least:

- exact GGUF filename and quant
- alias exposed through `/v1/models`
- native context window from the model card
- whether MTP/speculative decoding is supported at all
- official sampling recommendations from the model author
- backend-specific observations from local testing
- whether flash attention was validated or only assumed

## Summary

For `Qwen3.6-27B-MTP GGUF` in this repo:

- keep `flash-attn` on
- keep MTP on by default
- use `98,304` context as the practical local default
- treat context pressure as the main tuning lever for Hermes responsiveness
- use the instruct / non-thinking sampling profile already present in `hermes_config.yaml`