#!/usr/bin/env bash
# Запускает сценарий openQA "openssh" (ssh_server + ssh_client), ждёт завершения обоих job'ов
# и скачивает их JUnit-отчёты (junit-ssh_server.xml / junit-ssh_client.xml из ulogs/), чтобы
# GitLab мог показать их во вкладке Tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${OPENQA_URL:=http://localhost}"
: "${OPENQA_DISTRI:=os-autoinst-distri-container}"
: "${OPENQA_VERSION:=10.2}"
: "${OPENQA_FLAVOR:=Minimal}"
: "${OPENQA_ARCH:=x86_64}"
: "${OPENQA_ISO:=AlmaLinux-10.2-x86_64-minimal.iso}"
: "${OPENQA_CASEDIR:=/var/lib/openqa/tests/os-autoinst-distri-container}"
: "${OPENQA_TEST:=openssh-client}"
: "${OPENQA_DNS_IP:=10.255.255.254}"
: "${OPENQA_BUILD:=ci-${CI_PIPELINE_ID:-$(date +%Y%m%d%H%M%S)}}"
: "${OPENQA_TIMEOUT:=1800}"        # сколько всего ждать завершения job'ов, секунд
: "${OPENQA_POLL_INTERVAL:=15}"    # пауза между опросами статуса, секунд

for bin in openqa-cli curl jq; do
    command -v "$bin" >/dev/null || { echo "'$bin' not found in PATH on the runner host" >&2; exit 1; }
done

echo "==> Scheduling openQA scenario '$OPENQA_TEST', BUILD=$OPENQA_BUILD"
response=$(openqa-cli api -X POST isos \
    ISO="$OPENQA_ISO" \
    DISTRI="$OPENQA_DISTRI" \
    VERSION="$OPENQA_VERSION" \
    FLAVOR="$OPENQA_FLAVOR" \
    ARCH="$OPENQA_ARCH" \
    BUILD="$OPENQA_BUILD" \
    CASEDIR="$OPENQA_CASEDIR" \
    TEST="$OPENQA_TEST" \
    DNS_IP="$OPENQA_DNS_IP")

echo "$response"
job_ids=$(jq -r '.ids[]?' <<<"$response")
if [ -z "$job_ids" ]; then
    echo "openQA did not return any job id - see the response above" >&2
    exit 1
fi
echo "==> Scheduled jobs: $job_ids"

deadline=$(( $(date +%s) + OPENQA_TIMEOUT ))
declare -A job_result
pending="$job_ids"

while [ -n "$pending" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Timed out after ${OPENQA_TIMEOUT}s waiting for job(s):$pending" >&2
        exit 1
    fi
    still_pending=""
    for id in $pending; do
        info=$(openqa-cli api -X GET "jobs/$id")
        # Поле ожидается как .job.state / .job.result - сверьте разово командой
        # `openqa-cli api jobs/<id> | jq .`, если скрипт здесь упадёт на пустом значении.
        state=$(jq -r '.job.state // empty' <<<"$info")
        if [ "$state" = "done" ]; then
            result=$(jq -r '.job.result // "unknown"' <<<"$info")
            job_result[$id]="$result"
            echo "==> Job $id finished: $result ($OPENQA_URL/tests/$id)"
        else
            still_pending="$still_pending $id"
        fi
    done
    pending="$still_pending"
    [ -n "$pending" ] && sleep "$OPENQA_POLL_INTERVAL"
done

echo "==> Downloading JUnit reports"
for id in $job_ids; do
    # Имя файла (junit-openssh-server.xml и т.п.) зависит от того, что передано в
    # write_step_report() внутри самого теста - не угадываем его, а спрашиваем у openQA,
    # что реально лежит в ulogs/ этого job'а.
    details=$(openqa-cli api -X GET "jobs/$id/details") || { echo "    job $id: could not fetch details" >&2; continue; }
    ulogs=$(jq -r '.job.ulogs[]? // empty' <<<"$details")
    if [ -z "$ulogs" ]; then
        echo "    job $id: no ulogs listed in job details" >&2
        continue
    fi
    while IFS= read -r fname; do
        case "$fname" in
            junit-*.xml)
                url="$OPENQA_URL/tests/$id/file/$fname"
                out="${fname%.xml}-$id.xml"
                if curl -fsS "$url" -o "$out"; then
                    # Добавляем в отчёт ссылку на этот openQA job (видео/скриншоты/логи) и,
                    # если запущено из GitLab CI, на сам job GitLab.
                    perl "$SCRIPT_DIR/annotate-junit.pl" "$out" "$OPENQA_URL/tests/$id" "${CI_JOB_URL:-}"
                    echo "    saved $out"
                fi
                ;;
        esac
    done <<<"$ulogs"
done

shopt -s nullglob
reports=(junit-*.xml)
if [ ${#reports[@]} -eq 0 ]; then
    echo "No JUnit reports were downloaded - did the test modules actually call write_step_report()?" >&2
    exit 1
fi

overall_rc=0
for id in $job_ids; do
    case "${job_result[$id]:-unknown}" in
        passed|softfailed) ;;
        *) echo "Job $id result: ${job_result[$id]:-unknown} ($OPENQA_URL/tests/$id)" >&2; overall_rc=1 ;;
    esac
done
exit "$overall_rc"