#!/usr/bin/env bash
# Evidence for the customer: the naive Dockerfile against the production one, same scanner, same database.
# Writes a Markdown table (to $GITHUB_STEP_SUMMARY in CI). Needs docker, grype, jq.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${GITHUB_STEP_SUMMARY:-/dev/stdout}
{ echo "| Image | Size | User | Shell | Findings | Critical | High | Fixable |"; echo "|---|---:|---|---|---:|---:|---:|---:|"; } >> "$OUT"
for app in payments-api patient-api; do
  for kind in naive production; do
    f=Dockerfile; [ $kind = naive ] && f=Dockerfile.naive
    tag="compare/$app:$kind"; docker build -q -f "apps/$app/$f" -t "$tag" "apps/$app" >/dev/null
    size=$(docker image inspect "$tag" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1048576}')
    user=$(docker image inspect "$tag" --format '{{.Config.User}}'); user=${user:-root}
    shell=$(docker run --rm --entrypoint sh "$tag" -c 'echo yes' 2>/dev/null || echo no)
    grype "$tag" -q -o json > /tmp/g.json
    c() { jq "[.matches[] | select(.vulnerability.severity == \"$1\")] | length" /tmp/g.json; }
    echo "| $app ($kind) | $size | $user | $shell | $(jq '.matches|length' /tmp/g.json) | $(c Critical) | $(c High) | $(jq '[.matches[]|select(.vulnerability.fix.state=="fixed")]|length' /tmp/g.json) |" >> "$OUT"
  done
done
