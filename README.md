# OpenAI Repo Analyzer (GitHub Actions)

Runs a manual workflow that:
1. Downloads a **public GitHub repo** as a zip
2. Uploads the zip to **OpenAI Files API**
3. Calls **OpenAI Responses API** with a **static prompt**
4. Saves the model’s reply to `response.txt` (as a build artifact)

## Setup

1. **Create secret**: add `OPENAI_API_KEY` in **Settings → Secrets and variables → Actions → New repository secret**.
2. Optionally change the model in `.github/workflows/run.yml` (`OPENAI_MODEL`).

## Usage

- Go to **Actions → Analyze Repo via OpenAI → Run workflow**.
- Enter a public repo URL like `https://github.com/owner/repo`.
- After it finishes, download the **openai-response** artifact (contains `response.txt`).

## Notes

- Works for **public** repos only (uses `api.github.com/repos/:owner/:repo/zipball`).
- Static prompt lives in `prompts/static.txt`.
- Modify `scripts/run.sh` if you want to:
  - pass a dynamic prompt,
  - change polling or output extraction,
  - send additional context.

## Local test
```bash
export OPENAI_API_KEY=sk-...
export OPENAI_MODEL=gpt-4.1-mini   # optional
bash scripts/run.sh https://github.com/owner/repo
cat response.txt
```
