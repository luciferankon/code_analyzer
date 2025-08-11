#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: run.sh <public GitHub repo URL>"
  exit 1
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is required (set as a repo secret)."
  exit 1
fi

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4.1-mini}"
WORKDIR="$(pwd)"
TMPDIR="$(mktemp -d)"
ZIP_PATH="${TMPDIR}/code.zip"

cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

# --- Parse owner/repo from URL ---
NORM_URL="${REPO_URL%.git}"
if [[ "${NORM_URL}" =~ github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  echo "Could not parse owner/repo from: ${REPO_URL}"
  exit 1
fi

echo "Owner: ${OWNER}"
echo "Repo : ${REPO}"

# --- Download zip of default branch ---
echo "Downloading zip..."
curl -fsSL -o "${ZIP_PATH}" "https://api.github.com/repos/${OWNER}/${REPO}/zipball"

# --- Upload the zip to OpenAI Files API ---
echo "Uploading zip to OpenAI Files API..."
FILE_UPLOAD_JSON="$(
  curl -sS -X POST "https://api.openai.com/v1/files" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F "purpose=assistants" \
    -F "file=@${ZIP_PATH}"
)"

FILE_ID="$(echo "${FILE_UPLOAD_JSON}" | jq -r '.id')"
if [[ -z "${FILE_ID}" || "${FILE_ID}" == "null" ]]; then
  echo "Failed to upload file to OpenAI. Response:"
  echo "${FILE_UPLOAD_JSON}"
  exit 1
fi
echo "Uploaded file_id: ${FILE_ID}"

# --- Read static prompt from file (unchanged) ---
PROMPT_PATH="${WORKDIR}/prompts/static.txt"
if [[ ! -f "${PROMPT_PATH}" ]]; then
  echo "Static prompt not found at ${PROMPT_PATH}"
  exit 1
fi
STATIC_PROMPT="$(cat "${PROMPT_PATH}")"

# --- Create a Responses API request that uses Code Interpreter and attaches the zip ---
echo "Creating response (with code_interpreter + attachment)..."
CREATE_JSON="$(
  jq -n \
    --arg model "${OPENAI_MODEL}" \
    --arg prompt "${STATIC_PROMPT}" \
    --arg file_id "${FILE_ID}" '
  {
    "model": $model,
    "tools": [ { "type": "code_interpreter" } ],
    "attachments": [ { "file_id": $file_id } ],
    "input": [
      {
        "role": "user",
        "content": [
          { "type": "input_text", "text": $prompt }
        ]
      }
    ]
  }'
)"

HTTP_RESP="$(mktemp)"
HTTP_CODE="$(
  curl -sS -o "${HTTP_RESP}" -w "%{http_code}" \
    -X POST "https://api.openai.com/v1/responses" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${CREATE_JSON}"
)"

echo "HTTP ${HTTP_CODE}"
if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" ]]; then
  echo "Responses API error body:"
  cat "${HTTP_RESP}"
  exit 1
fi

CREATE_RESP="$(cat "${HTTP_RESP}")"
RESP_ID="$(echo "${CREATE_RESP}" | jq -r '.id // empty')"
if [[ -z "${RESP_ID}" ]]; then
  echo "No response id. Full payload:"
  echo "${CREATE_RESP}"
  exit 1
fi
echo "Response ID: ${RESP_ID}"

# --- Poll until completed ---
echo "Polling for completion..."
STATUS="in_progress"
TRIES=0
MAX_TRIES=60

while [[ "${STATUS}" != "completed" && "${STATUS}" != "failed" && "${TRIES}" -lt "${MAX_TRIES}" ]]; do
  sleep 3
  POLL="$(
    curl -sS -X GET "https://api.openai.com/v1/responses/${RESP_ID}" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}"
  )"
  STATUS="$(echo "${POLL}" | jq -r '.status')"
  echo "Status: ${STATUS}"
  TRIES=$((TRIES+1))
done

if [[ "${STATUS}" != "completed" ]]; then
  echo "Response did not complete. Final payload:"
  echo "${POLL}"
  exit 1
fi

# Save raw JSON for troubleshooting (optional but handy)
echo "${POLL}" > response_raw.json

# --- Extract text output ---
OUTPUT_TEXT="$(echo "${POLL}" | jq -r '.output_text // ( .output[0].content[0].text // .choices[0].message.content // "NO_TEXT_RETURNED")')"
echo "${OUTPUT_TEXT}" > "${WORKDIR}/response.txt"
echo "Saved response.txt"
