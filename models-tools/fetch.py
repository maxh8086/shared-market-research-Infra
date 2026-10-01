"""Download every model in models.json that is not already in the Hugging Face cache."""
import json
import sys

from huggingface_hub import snapshot_download

with open("/models.json", encoding="utf-8") as fh:
    wanted = json.load(fh)["models"]

failed = []
for entry in wanted:
    repo = entry["repo"]
    print(f"== {repo} (~{entry.get('size_gb', '?')} GB)", flush=True)
    try:
        path = snapshot_download(repo_id=repo, cache_dir="/models/huggingface/hub")
        print(f"   ready: {path}", flush=True)
    except Exception as exc:  # report every model, then fail once
        print(f"   FAILED: {exc}", flush=True)
        failed.append(repo)
sys.exit(1 if failed else 0)
