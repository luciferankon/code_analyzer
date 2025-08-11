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

echo "Downloading zip..."
curl -fsSL -o "${ZIP_PATH}" "https://api.github.com/repos/${OWNER}/${REPO}/zipball"

echo "Uploading zip to OpenAI Files API..."
FILE_UPLOAD_JSON="$(
  curl -fsS -X POST "https://api.openai.com/v1/files"     -H "Authorization: Bearer ${OPENAI_API_KEY}"     -H "Content-Type: multipart/form-data"     -F "purpose=assistants"     -F "file=@${ZIP_PATH}"
)"

FILE_ID="$(echo "${FILE_UPLOAD_JSON}" | jq -r '.id')"
if [[ -z "${FILE_ID}" || "${FILE_ID}" == "null" ]]; then
  echo "Failed to upload file to OpenAI. Response:"
  echo "${FILE_UPLOAD_JSON}"
  exit 1
fi
echo "Uploaded file_id: ${FILE_ID}"

PROMPT_PATH="${WORKDIR}/prompts/static.txt"
if [[ ! -f "${PROMPT_PATH}" ]]; then
  echo "Static prompt not found at ${PROMPT_PATH}"
  exit 1
fi
STATIC_PROMPT="$(cat "${PROMPT_PATH}")"

echo "Creating response..."
CREATE_JSON="$(
  jq -n --arg model "${OPENAI_MODEL}" --arg prompt "${STATIC_PROMPT}" --arg file_id "${FILE_ID}" '
  {
    "model": $model,
    "input": [
      {
        "role": "user",
        "content": [
          {"type":"input_text","text": $prompt},
          {"type":"input_file","file_id": $file_id}
        ]
      }
    ]
  }'
)";

CREATE_RESP="$(
  curl -fsS -X POST "https://api.openai.com/v1/responses"     -H "Authorization: Bearer ${OPENAI_API_KEY}"     -H "Content-Type: application/json"     -d "${CREATE_JSON}"
)"

RESP_ID="$(echo "${CREATE_RESP}" | jq -r '.id')"
if [[ -z "${RESP_ID}" || "${RESP_ID}" == "null" ]]; then
  echo "Failed to create response. Payload:"
  echo "${CREATE_RESP}"
  exit 1
fi
echo "Response ID: ${RESP_ID}"

echo "Polling for completion..."
STATUS="in_progress"
TRIES=0
MAX_TRIES=60

while [[ "${STATUS}" != "completed" && "${STATUS}" != "failed" && "${TRIES}" -lt "${MAX_TRIES}" ]]; do
  sleep 3
  POLL="$(
    curl -fsS -X GET "https://api.openai.com/v1/responses/${RESP_ID}"       -H "Authorization: Bearer ${OPENAI_API_KEY}"
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

OUTPUT_TEXT="$(echo "${POLL}" | jq -r '.output_text // ( .output[0].content[0].text // .choices[0].message.content // "NO_TEXT_RETURNED")')"

echo "${OUTPUT_TEXT}" > "${WORKDIR}/response.txt"
echo "Saved response.txt"
