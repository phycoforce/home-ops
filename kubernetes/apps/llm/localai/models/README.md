# LocalAI Model Catalog

This directory manages LocalAI model definitions and artifact sync jobs with Flux.

## Structure

- `<model>.yaml`: One file per model containing both the model ConfigMap and sync Job.
- `externalsecret.yaml`: Pulls `HF_TOKEN` from 1Password (`localai` item, `HF_TOKEN` property).

## How to add a new model

1. Add a new `<model>.yaml` file containing:
   - a model ConfigMap with a single config file key (for example `my_model.yaml`)
   - a model sync Job that:
   - downloads model artifacts to `/models`
   - verifies SHA256 checksums
   - copies the model config file to `/models`
2. Add the new file to `kustomization.yaml`.

## Required follow-up before reconcile

Populate "model_sha256" with SHA256t values from source download.

## Notes for Intel iGPU (SYCL)

- Keep `mmap: false` in model configs for stability.
- Tune `gpu_layers` and `context_size` per model as needed.
