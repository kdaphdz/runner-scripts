#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
read_vars

OUTPUT_DIR="/tmp/wattsci"
SERVER_URL="http://172.24.106.15:5000"
PID_FILE="$OUTPUT_DIR/perf.pid"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"

function start_measurement {
    if [[ $# -lt 2 ]]; then
        echo "[ERROR] Missing arguments for start_measurement" >&2
        show_usage
    fi

    if [[ -d "$OUTPUT_DIR" ]]; then
        echo "[INFO] Cleaning previous output directory"
        rm -rf "$OUTPUT_DIR"
    fi
    mkdir -p "$OUTPUT_DIR"

    date "+%s%6N" >> "$TIMER_FILE_START"
    echo "[INFO] Timer start recorded at $(tail -n 1 "$TIMER_FILE_START")"

    add_var 'WATTSCI_RUN_ID' "$1"
    add_var 'WATTSCI_BRANCH' "$2"
    add_var 'WATTSCI_REPOSITORY' "$3"
    add_var 'WATTSCI_WORKFLOW_ID' "$4"
    add_var 'WATTSCI_WORKFLOW_NAME' "$5"
    add_var 'WATTSCI_COMMIT_HASH' "$6"
    add_var 'WATTSCI_SOURCE' "$7"

    local method="$8"
    shift 8
    local args=("$@")

    add_var 'WATTSCI_METHOD' "$method"

    case "$method" in
        perf)
            local interval_ms="${args[-1]}"
            local perf_events=("${args[@]:0:${#args[@]}-1}")

            bash "$(dirname "$0")/perf.sh" "${perf_events[@]}" "$interval_ms" < /dev/null 2>&1 &

            local parent_pid=$!
            sleep 1
            local child_pid
            child_pid=$(pgrep -P "$parent_pid" -n)

            if [[ -z "$child_pid" ]]; then
                echo "[ERROR] Failed to detect perf child process PID" >&2
                kill "$parent_pid" || true
                exit 1
            fi

            echo "$child_pid" > "$PID_FILE"
            echo "[INFO] Measurement running with PID $child_pid"
            ;;
        *)
            echo "[ERROR] Unsupported method: $method" >&2
            exit 1
            ;;
    esac
}

function end_measurement {
    local baseline_flag="false"
    for arg in "$@"; do
        if [[ "$arg" == "--baseline" ]]; then
            baseline_flag="true"
            break
        fi
    done

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file not found. Cannot stop measurement." >&2
        exit 1
    fi

    date "+%s%6N" >> "$TIMER_FILE_END"
    echo "[INFO] Timer end recorded at $(tail -n 1 "$TIMER_FILE_END")"

    local pid
    pid=$(<"$PID_FILE")

    if kill "$pid" 2>/dev/null; then
        echo "[INFO] Stopped measurement process PID=$pid"
        rm -f "$PID_FILE"
    else
        echo "[ERROR] Failed to stop process PID=$pid"
        rm -f "$PID_FILE"
        exit 1
    fi

    if [[ ! -f "$WATTSCI_OUTPUT_FILE" ]]; then
        echo "[ERROR] Perf output file not found: $WATTSCI_OUTPUT_FILE" >&2
        exit 1
    fi

    ORIGINAL_NAME=$(basename "$WATTSCI_OUTPUT_FILE")

    COMPRESSED_FILE="$OUTPUT_DIR/${ORIGINAL_NAME}.gz"
    gzip -c "$WATTSCI_OUTPUT_FILE" > "$COMPRESSED_FILE"
    echo "[INFO] Compressed perf output saved to: $COMPRESSED_FILE"

    CHUNK_SIZE="10M"
    split -b "$CHUNK_SIZE" --numeric-suffixes=1 --suffix-length=3 \
          "$COMPRESSED_FILE" "${COMPRESSED_FILE}_chunk_"
    echo "[INFO] Chunks created:"
    ls -lh "${COMPRESSED_FILE}_chunk_"*

    upload_fields=(
        -F "WATTSCI_RUN_ID=$WATTSCI_RUN_ID"
        -F "WATTSCI_BRANCH=$WATTSCI_BRANCH"
        -F "WATTSCI_REPOSITORY=$WATTSCI_REPOSITORY"
        -F "WATTSCI_WORKFLOW_ID=$WATTSCI_WORKFLOW_ID"
        -F "WATTSCI_WORKFLOW_NAME=$WATTSCI_WORKFLOW_NAME"
        -F "WATTSCI_COMMIT_HASH=$WATTSCI_COMMIT_HASH"
        -F "WATTSCI_SOURCE=$WATTSCI_SOURCE"
        -F "WATTSCI_METHOD=$WATTSCI_METHOD"
    )

    if [[ "$baseline_flag" == "true" ]]; then
        upload_fields+=(-F "WATTSCI_BASELINE=true")
    else
        upload_fields+=(-F "WATTSCI_BASELINE=false")
    fi

    session_id=""
    for chunk in "${COMPRESSED_FILE}_chunk_"*; do
        echo "[INFO] Uploading chunk: $chunk"
        resp=$(curl -s -X POST "$SERVER_URL/upload" \
            -F "chunk=@${chunk}" \
            -F "chunk_name=$(basename "$chunk")" \
            "${upload_fields[@]}")

        echo " - Server response: $resp"

        if [[ -z "$session_id" ]]; then
            session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
            echo "[INFO] Session ID received: $session_id"
        fi
    done

    echo "[INFO] Requesting file reconstruction on server..."
    start_time=$(tail -n 1 "$TIMER_FILE_START")
    end_time=$(tail -n 1 "$TIMER_FILE_END")
    response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
        -F "session_id=$session_id" \
        -F "timer_start=$start_time" \
        -F "timer_end=$end_time" \
        "${upload_fields[@]}" \
        -F "original_name=$ORIGINAL_NAME")
    
    summary_md=$(echo "$response" | sed -n 's/.*"summary_md": *"\([^"]*\)".*/\1/p' | sed 's/\\n/\n/g' | sed 's/\\"/"/g')
    
    json_content=$(echo "$response" | sed -n 's/.*"json_content":\({.*}\)[,}].*/\1/p')
    
    # Guardar json_content en archivo
    echo "$json_content" > ecops-json-content.json
    echo "[INFO] json_content saved to ecops-json-content.json"
    
    # Resto igual...
    local repo="${WATTSCI_REPOSITORY}"
    local branch="${WATTSCI_BRANCH}"
    local workflow="${WATTSCI_WORKFLOW_ID}"
    
    local start_date="2025-07-02"
    local end_date="2025-07-10"
    
    local url="http://localhost:3000/wattsci?repo=${repo}&branch=${branch}&workflow=${workflow}&start_date=${start_date}&end_date=${end_date}"
    summary_md="${summary_md}\n\n[Ver resultados en Wattsci](${url})"
    
    REPORT_MD="ecops-summary.md"
    echo -e "$summary_md" > "$REPORT_MD"
    echo "[INFO] Markdown report generated at: $REPORT_MD"
    
    REPORT_JSON="ecops-summary.json"
    echo "$response" > "$REPORT_JSON"
    echo "[INFO] JSON report saved at: $REPORT_JSON"
}

function baseline {
    echo "[DEBUG] baseline args: $@"
    start_measurement "$@"
    echo "[INFO] Sleeping for 5 seconds between start and end measurement..."
    sleep 5
    end_measurement --baseline
}

function show_usage {
    echo "Usage:"
    echo "  $0 start_measurement perf <event1> [<event2> ...] <interval_ms>"
    echo "  $0 end_measurement"
    echo "  $0 baseline <all start_measurement args>"
    exit 1
}

option="${1:-}"

if [[ -z "$option" ]]; then
    echo "[ERROR] No option provided."
    show_usage
fi

shift || true

case "$option" in
    start_measurement)
        start_measurement "$@"
        ;;
    end_measurement)
        end_measurement "$@"
        ;;
    baseline)
        baseline "$@"
        ;;
    *)
        echo "[ERROR] Invalid option: $option"
        show_usage
        ;;
esac
