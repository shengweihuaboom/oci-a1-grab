#!/bin/bash
# One attempt to create the Oracle Cloud instance "gege-api" (VM.Standard.A1.Flex, 2 OCPU / 12 GB) in ap-osaka-1.
# Settings come from the Resource Manager stack "gege-api-anyfd". Nothing identifying is printed to the (public) log.
set -uo pipefail
REGION=ap-osaka-1
NAME=gege-api
STACK_NAME=gege-api-anyfd
WORKFLOW_FILE=grab.yml
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

mask() { [ -n "${1:-}" ] && echo "::add-mask::$1"; return 0; }
clean() { sed -E 's/ocid1\.[A-Za-z0-9._-]+/ocid1.***/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g'; }
errmsg() { tr '\n' ' ' < err.txt | grep -oE '"(code|message|status)": *("[^"]*"|[0-9]+)' | clean | tr '\n' ' '; }
stop_workflow() { gh workflow disable "$WORKFLOW_FILE" -R "$GITHUB_REPOSITORY" && echo "已停用定时任务 $WORKFLOW_FILE"; }
# Relay: wait, then trigger the next run of this workflow (runs started by GITHUB_TOKEN via workflow_dispatch are allowed).
relay() {
  sleep "${1:-240}"
  gh workflow run "$WORKFLOW_FILE" -R "$GITHUB_REPOSITORY" --ref "${GITHUB_REF_NAME:-main}" \
    && echo "已安排下一次尝试。" || echo "::warning::安排下一次失败，等每小时的定时检查接上。"
}

# Hourly scheduled run = watchdog: step in only if the relay has stopped.
if [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; then
  OTHERS=$(gh run list -R "$GITHUB_REPOSITORY" -w "$WORKFLOW_FILE" --limit 20 --json databaseId,status \
    --jq "[.[] | select(.databaseId != ${GITHUB_RUN_ID:-0}) | select(.status != \"completed\")] | length" 2>/dev/null)
  if [ "${OTHERS:-0}" -gt 0 ]; then echo "接力还在进行，这次定时检查不重复尝试。"; exit 0; fi
  echo "接力已断，由定时检查重新接上。"
fi

TENANCY=$(grep -m1 '^tenancy' ~/.oci/config | cut -d= -f2- | tr -d ' \r')
mask "$TENANCY"
[ -n "$TENANCY" ] || { echo "::error::OCI_CONFIG 里没找到 tenancy="; exit 1; }

# 1) Already have gege-api? Then stop for good.
oci compute instance list --region $REGION -c "$TENANCY" --display-name "$NAME" --all > list.json 2> err.txt
if [ $? -ne 0 ]; then echo "::error::查询现有实例失败：$(errmsg)"; exit 1; fi
N=0; [ -s list.json ] && N=$(jq '[.data[]? | select(."lifecycle-state" != "TERMINATED")] | length' list.json)
if [ "${N:-0}" -gt 0 ]; then echo "已经有 $NAME 了，不再创建。"; stop_workflow; exit 0; fi

# 2) Read the instance settings from the stack.
oci resource-manager stack list --region $REGION -c "$TENANCY" --display-name "$STACK_NAME" --all > stacks.json 2> err.txt
if [ $? -ne 0 ]; then echo "::error::读取堆栈失败：$(errmsg)"; exit 1; fi
STACK_ID=$(jq -r '.data[0].id // empty' stacks.json 2>/dev/null); mask "$STACK_ID"
[ -n "$STACK_ID" ] || { echo "::error::没找到堆栈 $STACK_NAME"; exit 1; }
oci resource-manager stack get-stack-tf-config --region $REGION --stack-id "$STACK_ID" --file tf.zip > /dev/null 2> err.txt
if [ $? -ne 0 ]; then echo "::error::下载堆栈配置失败：$(errmsg)"; exit 1; fi
unzip -o -q tf.zip
v() { grep -m1 "$1" main.tf | cut -d'"' -f2; }
COMP=$(v compartment_id); AD=$(v availability_domain); SUBNET=$(v subnet_id); IMAGE=$(v source_id)
mask "$COMP"; mask "$SUBNET"; mask "$IMAGE"
grep -m1 ssh_authorized_keys main.tf | cut -d'"' -f4 > key.pub
for x in COMP AD SUBNET IMAGE; do [ -n "${!x}" ] || { echo "::error::堆栈配置里缺少 $x"; exit 1; }; done
[ -s key.pub ] || { echo "::error::堆栈配置里缺少 SSH 公钥"; exit 1; }

# 3) One launch attempt.
oci --no-retry compute instance launch --region $REGION \
  -c "$COMP" --availability-domain "$AD" --display-name "$NAME" \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
  --image-id "$IMAGE" --boot-volume-size-in-gbs 50 \
  --subnet-id "$SUBNET" --assign-public-ip true \
  --instance-options '{"areLegacyImdsEndpointsDisabled":true}' \
  --ssh-authorized-keys-file key.pub > launch.json 2> err.txt
RC=$?
if [ $RC -eq 0 ]; then
  ID=$(jq -r '.data.id // empty' launch.json); mask "$ID"
  echo "创建成功！"
  oci compute instance get --region $REGION --instance-id "$ID" --wait-for-state RUNNING --max-wait-seconds 600 > /dev/null 2>&1 \
    && echo "实例已经是 RUNNING。" || echo "实例还在启动中。"
  stop_workflow
  gh issue create -R "$GITHUB_REPOSITORY" --title "gege-api 已建好" \
    --body "$(date -u '+%Y-%m-%d %H:%M UTC') 创建成功，定时任务已自动停用。公网 IP 请到 Oracle 控制台 Compute → Instances → gege-api 查看。" \
    || echo "::warning::发通知 issue 失败"
  exit 0
fi
MSG=$(errmsg)
if grep -qi 'out of host capacity' err.txt; then echo "大阪暂时没空位（Out of host capacity），下次再试。"; relay "${RELAY_DELAY:-240}"; exit 0; fi
if grep -qiE 'TooManyRequests|"status": *429' err.txt; then echo "被限流（Too many requests），多等一会儿再试。"; relay "${RELAY_DELAY_429:-540}"; exit 0; fi
echo "::error::创建失败，原因不是没空位：$MSG"
exit 1
