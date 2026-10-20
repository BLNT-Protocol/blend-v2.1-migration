#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${BLEND_V21_RECEIVER_E2E_WORK_DIR:-${ROOT_DIR}/.localnet-receiver-e2e}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="${WORK_DIR}/runs/${RUN_ID}"
CONFIG_DIR="${RUN_DIR}/stellar-config"
CONTAINER_NAME="${BLEND_V21_RECEIVER_E2E_CONTAINER:-blend-v21-receiver-e2e}"
RPC_PORT="${BLEND_V21_RECEIVER_E2E_RPC_PORT:-8011}"
CORE_PORT="${BLEND_V21_RECEIVER_E2E_CORE_PORT:-11627}"
RPC_URL="http://127.0.0.1:${RPC_PORT}/soroban/rpc"
HORIZON_URL="http://127.0.0.1:${RPC_PORT}"
CORE_URL="http://127.0.0.1:${CORE_PORT}"
NETWORK_PASSPHRASE="Standalone Network ; February 2017"
QUICKSTART_IMAGE="${BLEND_V21_RECEIVER_E2E_QUICKSTART_IMAGE:-stellar/quickstart:testing}"
KEEP_CONTAINER="${BLEND_V21_RECEIVER_E2E_KEEP_CONTAINER:-false}"
STELLAR="${BLEND_V21_RECEIVER_E2E_STELLAR:-stellar}"
OPERATOR_IDENTITY="receiver-e2e-operator"
YSC_IDENTITY="receiver-e2e-ysc"
SCALAR_7=10000000
WAIT_SECONDS=$((31 * 24 * 60 * 60))
INCUMBENT_LEGACY_LP=$((100 * SCALAR_7))
RECEIVER_LEGACY_LP=$((101 * SCALAR_7))
V21_BACKSTOP_LP=$((200 * SCALAR_7))
RECEIVER_V21_LP=$((3 * SCALAR_7))
EMITTER_SALT="000000000000000000000000000000000000000000000000000000000000e100"
INCUMBENT_BACKSTOP_SALT="000000000000000000000000000000000000000000000000000000000000e201"
V21_BACKSTOP_SALT="000000000000000000000000000000000000000000000000000000000000e202"
V1_EMITTER_WASM="${ROOT_DIR}/blend-contracts/blend-contract-sdk/wasm/emitter.wasm"
V1_EMITTER_SHA256="438a5528cff17ede6fe515f095c43c5f15727af17d006971485e52462e7e7b89"
V2_ARTIFACT_DIR="${ROOT_DIR}/.artifacts/blend-contracts-v2/v2.0.0-cli22.0.1"
V2_FACTORY_WASM="${V2_ARTIFACT_DIR}/pool_factory.wasm"
V2_FACTORY_SHA256="31328050548831f63d2b72e37bcfd0bb7371b7907135755dbe09ed434d755ca9"
V2_BACKSTOP_WASM="${V2_ARTIFACT_DIR}/backstop.wasm"
V2_BACKSTOP_SHA256="c1f4502a757e25c611f5a159bc1ab0eef64085adac6c68123dca66e87faffbc2"
V2_POOL_WASM="${V2_ARTIFACT_DIR}/pool.wasm"
V2_POOL_SHA256="a41fc53d6753b6c04eb15b021c55052366a4c8e0e21bc72700f461264ec1350e"
RECEIVER_WASM="${ROOT_DIR}/blend-v2.1-receiver/target/wasm32v1-none/optimized/blend_v2_1_receiver.wasm"
CONTAINER_STARTED=false
TEST_SUCCEEDED=false

note() {
    printf '%s\n' "$*" >&2
}

die() {
    note "error: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

stellar_cli() {
    "${STELLAR}" --config-dir "${CONFIG_DIR}" "$@"
}

sha256_file() {
    local result
    result="$(shasum -a 256 "$1")"
    printf '%s\n' "${result%% *}"
}

assert_equal() {
    [[ "$1" == "$2" ]] || die "$3: expected $1, found $2"
}

assert_positive() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "$2 is not positive: $1"
}

require_contract_id() {
    [[ "$1" =~ ^C[A-Z2-7]{55}$ ]] || die "invalid contract ID for $2: $1"
}

normalize_scalar() {
    local raw="$1" decoded
    if decoded="$(printf '%s' "${raw}" | jq -er '
        if type == "string" or type == "number" or type == "boolean"
        then tostring else empty end
    ' 2>/dev/null)"
    then
        printf '%s\n' "${decoded}"
    else
        printf '%s\n' "${raw}"
    fi
}

capture() {
    local label="$1" stdout_file="${RUN_DIR}/$1.out" stderr_file="${RUN_DIR}/$1.cost.log"
    local status
    shift
    note "Executing ${label}..."
    if "$@" >"${stdout_file}" 2> >(tee "${stderr_file}" >&2); then
        status=0
    else
        status=$?
    fi
    cat "${stdout_file}"
    return "${status}"
}

core_info() {
    curl --fail --silent --show-error --max-time 2 "${CORE_URL}/info"
}

rpc_latest_sequence() {
    curl --fail --silent --show-error --max-time 5 \
        --header 'Content-Type: application/json' \
        --request POST \
        --data '{"jsonrpc":"2.0","id":1,"method":"getLatestLedger"}' \
        "${RPC_URL}" | jq -er '.result.sequence | tonumber'
}

wait_for_rpc_sequence() {
    local target="$1" current
    for _ in {1..600}; do
        current="$(rpc_latest_sequence 2>/dev/null || true)"
        if [[ "${current}" =~ ^[0-9]+$ ]] && (( current >= target )); then
            return
        fi
        sleep 0.1
    done
    die "RPC did not ingest core ledger ${target}"
}

advance_to_timestamp() {
    local target="$1" info current_time old_sequence new_sequence="" poll
    info="$(core_info)"
    current_time="$(printf '%s' "${info}" | jq -er '.info.ledger.closeTime | tonumber')"
    old_sequence="$(printf '%s' "${info}" | jq -er '.info.ledger.num | tonumber')"
    if (( current_time < target )); then
        note "Advancing local ledger time beyond unlock target ${target} (currently ${current_time})."
        set_core_clock_for_target "${target}"
        for ((poll = 0; poll < 240; poll++)); do
            info="$(core_info)"
            new_sequence="$(printf '%s' "${info}" | jq -er '.info.ledger.num | tonumber')"
            current_time="$(printf '%s' "${info}" | jq -er '.info.ledger.closeTime | tonumber')"
            if (( new_sequence > old_sequence && current_time >= target )); then
                break
            fi
            sleep 0.1
        done
        if [[ ! "${new_sequence}" =~ ^[0-9]+$ ]] ||
            (( new_sequence <= old_sequence || current_time < target )); then
            die "local ledger did not cross unlock time ${target}"
        fi
        wait_for_rpc_sequence "${new_sequence}"
    fi
}

network_healthy() {
    curl --fail --silent --show-error --max-time 5 \
        --header 'Content-Type: application/json' \
        --request POST \
        --data '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
        "${RPC_URL}" 2>/dev/null | jq -e '.result.status == "healthy"' >/dev/null 2>&1
}

wait_for_network() {
    for _ in {1..180}; do
        network_healthy && return
        sleep 1
    done
    die "local RPC did not become healthy"
}

wait_for_core() {
    for _ in {1..480}; do
        core_info >/dev/null 2>&1 && return
        sleep 0.25
    done
    die "stellar-core admin endpoint did not become available"
}

wait_for_core_synced() {
    local state
    for _ in {1..120}; do
        state="$(core_info 2>/dev/null | jq -er '.info.state' 2>/dev/null || true)"
        [[ "${state}" == "Synced!" ]] && return
        sleep 0.25
    done
    die "stellar-core did not return to the synced state"
}

verify_time_control_config() {
    local config library
    config="$(docker exec "${CONTAINER_NAME}" sh -c \
        "grep -E '^(MANUAL_CLOSE|ARTIFICIALLY_ACCELERATE_TIME_FOR_TESTING)=' /opt/stellar/core/etc/stellar-core.cfg || true")"
    library="$(docker exec "${CONTAINER_NAME}" cat /tmp/libfaketime.path)"
    printf '%s\n' "${config}" >"${RUN_DIR}/core-time-config.txt"
    printf '%s\n' "${library}" >"${RUN_DIR}/core-time-library.txt"
    if printf '%s\n' "${config}" | grep -qx 'MANUAL_CLOSE=true'; then
        die "local core unexpectedly has manual close enabled"
    fi
    docker exec "${CONTAINER_NAME}" test -f "${library}" ||
        die "local core process-local time library is missing"
}

set_core_clock_for_target() {
    local target="$1" host_now offset_seconds library launcher contents
    host_now="$(date +%s)"
    offset_seconds=$((target - host_now + 5))
    (( offset_seconds > 0 )) || offset_seconds=0
    library="$(docker exec "${CONTAINER_NAME}" cat /tmp/libfaketime.path)"
    docker exec "${CONTAINER_NAME}" sh -c \
        "printf '+%ss\\n' '${offset_seconds}' > /opt/stellar/core/etc/faketime.rc"
    for launcher in \
        /opt/stellar/core/bin/start \
        /opt/stellar/horizon/bin/start \
        /opt/stellar/stellar-rpc/bin/start
    do
        contents="$(docker exec "${CONTAINER_NAME}" cat "${launcher}")"
        if [[ "${contents}" != *FAKETIME_TIMESTAMP_FILE* ]]; then
            docker exec "${CONTAINER_NAME}" sed -i \
                "2i export LD_PRELOAD=${library}\\nexport FAKETIME_TIMESTAMP_FILE=/opt/stellar/core/etc/faketime.rc\\nexport FAKETIME_NO_CACHE=1\\nexport DONT_FAKE_MONOTONIC=1\\nexport NO_FAKE_STAT=1" \
                "${launcher}"
        fi
    done
    docker exec "${CONTAINER_NAME}" supervisorctl stop horizon stellar-rpc \
        >>"${RUN_DIR}/restart-time-controlled-services.log"
    docker exec "${CONTAINER_NAME}" supervisorctl restart stellar-core \
        >>"${RUN_DIR}/restart-time-controlled-services.log"
    wait_for_core
    wait_for_core_synced
    docker exec "${CONTAINER_NAME}" supervisorctl start horizon stellar-rpc \
        >>"${RUN_DIR}/restart-time-controlled-services.log"
    wait_for_network
    docker exec "${CONTAINER_NAME}" sh -c \
        "grep -H -E '^(export )?(LD_PRELOAD|FAKETIME_TIMESTAMP_FILE|FAKETIME_NO_CACHE|DONT_FAKE_MONOTONIC|NO_FAKE_STAT)=' /opt/stellar/core/bin/start /opt/stellar/horizon/bin/start /opt/stellar/stellar-rpc/bin/start" \
        >"${RUN_DIR}/time-control-environment.txt"
    printf '%s\n' "target=${target} host_now=${host_now} offset_seconds=${offset_seconds}" \
        >>"${RUN_DIR}/core-clock-advances.log"
}

ensure_identity() {
    local identity="$1"
    stellar_cli keys generate "${identity}" >/dev/null
    stellar_cli keys public-key "${identity}"
}

fund_account() {
    local label="$1" account="$2" now visible_since=""
    note "Executing ${label}..."
    : >"${RUN_DIR}/${label}.out"
    : >"${RUN_DIR}/${label}.cost.log"
    for _ in {1..120}; do
        if curl --fail --silent --show-error --max-time 5 \
            "${HORIZON_URL}/accounts/${account}" >/dev/null 2>&1 &&
            stellar_cli ledger entry fetch account \
                --account "${account}" \
                --rpc-url "${RPC_URL}" \
                --network-passphrase "${NETWORK_PASSPHRASE}" \
                --output json 2>/dev/null |
                jq -e '.entries | length == 1' >/dev/null 2>&1
        then
            now="$(date +%s)"
            if [[ -z "${visible_since}" ]]; then
                visible_since="${now}"
            elif (( now - visible_since >= 3 )); then
                note "Funded ${account}."
                return
            fi
        else
            visible_since=""
            curl --fail --silent --show-error --max-time 10 \
                --get --data-urlencode "addr=${account}" \
                "${HORIZON_URL}/friendbot" \
                >>"${RUN_DIR}/${label}.out" 2>>"${RUN_DIR}/${label}.cost.log" || true
        fi
        sleep 1
    done
    die "funded account did not become visible through Horizon and RPC: ${account}"
}

deploy_asset() {
    local label="$1" asset="$2" raw contract_id
    raw="$(capture "${label}" stellar_cli contract asset deploy \
        --asset "${asset}" \
        --source-account "${OPERATOR_IDENTITY}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}" \
        --cost)"
    contract_id="$(normalize_scalar "${raw}")"
    require_contract_id "${contract_id}" "${label}"
    printf '%s\n' "${contract_id}"
}

predict_wasm_id() {
    local label="$1" salt="$2" raw contract_id
    raw="$(capture "${label}" stellar_cli contract id wasm \
        --salt "${salt}" \
        --source-account "${OPERATOR_IDENTITY}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}")"
    contract_id="$(normalize_scalar "${raw}")"
    require_contract_id "${contract_id}" "${label}"
    printf '%s\n' "${contract_id}"
}

upload_wasm() {
    local label="$1" wasm="$2" raw hash
    raw="$(capture "${label}" stellar_cli contract upload \
        --wasm "${wasm}" \
        --optimize=false \
        --source-account "${OPERATOR_IDENTITY}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}" \
        --cost)"
    hash="$(normalize_scalar "${raw}")"
    [[ "${hash}" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid WASM hash for ${label}: ${hash}"
    printf '%s\n' "${hash}"
}

deploy_wasm() {
    local label="$1" wasm="$2" salt="$3" raw contract_id
    local -a command
    shift 3
    command=(
        stellar_cli contract deploy
        --wasm "${wasm}"
        --optimize=false
        --source-account "${OPERATOR_IDENTITY}"
        --rpc-url "${RPC_URL}"
        --network-passphrase "${NETWORK_PASSPHRASE}"
        --cost
    )
    [[ -z "${salt}" ]] || command+=(--salt "${salt}")
    (( $# == 0 )) || command+=(-- "$@")
    raw="$(capture "${label}" "${command[@]}")"
    contract_id="$(normalize_scalar "${raw}")"
    require_contract_id "${contract_id}" "${label}"
    printf '%s\n' "${contract_id}"
}

invoke_transaction() {
    local label="$1" contract="$2" function="$3"
    shift 3
    capture "${label}" stellar_cli contract invoke \
        --id "${contract}" \
        --source-account "${OPERATOR_IDENTITY}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}" \
        --cost -- "${function}" "$@"
}

invoke_view() {
    local label="$1" contract="$2" function="$3"
    shift 3
    capture "${label}" stellar_cli contract invoke \
        --id "${contract}" \
        --source-account "${OPERATOR_IDENTITY}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}" \
        --send no --cost -- "${function}" "$@"
}

token_balance() {
    local label="$1" token="$2" holder="$3"
    normalize_scalar "$(invoke_view "${label}" "${token}" balance --id "${holder}")"
}

create_trustline() {
    local label="$1" asset="$2"
    capture "${label}" stellar_cli tx new change-trust \
        --source-account "${YSC_IDENTITY}" \
        --line "${asset}" \
        --rpc-url "${RPC_URL}" \
        --network-passphrase "${NETWORK_PASSPHRASE}" >/dev/null
}

cleanup() {
    local status=$?
    if [[ "${CONTAINER_STARTED}" == "true" ]]; then
        docker logs "${CONTAINER_NAME}" >"${RUN_DIR}/quickstart.log" 2>&1 || true
        if [[ "${KEEP_CONTAINER}" != "true" ]]; then
            docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
            docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        else
            note "Keeping ${CONTAINER_NAME} running for inspection."
        fi
    fi
    if [[ "${TEST_SUCCEEDED}" != "true" ]]; then
        note "Receiver migration localnet E2E failed. Evidence: ${RUN_DIR}"
    fi
    return "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main() {
    local version major operator ysc image_id
    local blnd usdc legacy_lp v21_lp pool_hash
    local incumbent_backstop v21_backstop emitter receiver
    local incumbent_factory v21_factory deployed
    local first_queue first_unlock returned second_queue second_unlock burned final_queue
    local incumbent_blnd receiver_blnd v21_blnd ysc_blnd
    local ysc_legacy receiver_legacy incumbent_legacy ysc_v21 receiver_v21 candidate_v21

    require_command bash
    require_command curl
    require_command date
    require_command docker
    require_command jq
    require_command make
    require_command shasum
    require_command "${STELLAR}"
    version="$("${STELLAR}" --version)"
    version="${version%%$'\n'*}"
    major="${version#stellar }"
    major="${major%%.*}"
    [[ "${major}" == "27" ]] || die "Stellar CLI major version 27 is required; found ${version}"
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        die "container already exists: ${CONTAINER_NAME}"
    fi
    if network_healthy; then
        die "a network already responds at ${RPC_URL}"
    fi

    mkdir -p "${CONFIG_DIR}"
    note "Building and validating exact migration artifacts..."
    bash "${ROOT_DIR}/scripts/build-v2.sh"
    make -C "${ROOT_DIR}/blend-v2.1-receiver" build
    assert_equal "${V1_EMITTER_SHA256}" "$(sha256_file "${V1_EMITTER_WASM}")" \
        "V1 emitter WASM hash"
    assert_equal "${V2_FACTORY_SHA256}" "$(sha256_file "${V2_FACTORY_WASM}")" \
        "V2 factory WASM hash"
    assert_equal "${V2_BACKSTOP_SHA256}" "$(sha256_file "${V2_BACKSTOP_WASM}")" \
        "V2 backstop WASM hash"
    assert_equal "${V2_POOL_SHA256}" "$(sha256_file "${V2_POOL_WASM}")" \
        "V2 pool WASM hash"
    [[ -s "${RECEIVER_WASM}" ]] || die "optimized receiver WASM is missing"

    note "Starting isolated Protocol-27 Quickstart..."
    docker run --detach \
        --name "${CONTAINER_NAME}" \
        --publish "127.0.0.1:${RPC_PORT}:8000" \
        --publish "127.0.0.1:${CORE_PORT}:11626" \
        --entrypoint /bin/sh \
        "${QUICKSTART_IMAGE}" \
        -c 'set -eu
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libfaketime
libfaketime=$(find /usr/lib -path "*/faketime/libfaketime.so.1" -print -quit)
test -n "$libfaketime"
printf "%s\n" "$libfaketime" > /tmp/libfaketime.path
exec /start --local --limits testnet --protocol-version 27' \
        >"${RUN_DIR}/container-id.txt"
    CONTAINER_STARTED=true
    image_id="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")"
    wait_for_core
    wait_for_core_synced
    verify_time_control_config
    wait_for_network
    assert_equal "27" "$(core_info | jq -er '.info.ledger.version | tostring')" \
        "local protocol version"

    operator="$(ensure_identity "${OPERATOR_IDENTITY}")"
    ysc="$(ensure_identity "${YSC_IDENTITY}")"
    fund_account fund-operator "${operator}"
    fund_account fund-ysc "${ysc}"

    blnd="$(deploy_asset deploy-blnd "BLND:${operator}")"
    usdc="$(deploy_asset deploy-usdc "USDC:${operator}")"
    legacy_lp="$(deploy_asset deploy-v1-lp "V1LP:${operator}")"
    v21_lp="$(deploy_asset deploy-v21-lp "V21LP:${operator}")"
    create_trustline trust-ysc-blnd "BLND:${operator}"
    create_trustline trust-ysc-v1-lp "V1LP:${operator}"
    create_trustline trust-ysc-v21-lp "V21LP:${operator}"

    incumbent_backstop="$(predict_wasm_id predict-incumbent-backstop "${INCUMBENT_BACKSTOP_SALT}")"
    v21_backstop="$(predict_wasm_id predict-v21-backstop "${V21_BACKSTOP_SALT}")"
    emitter="$(deploy_wasm deploy-v1-emitter "${V1_EMITTER_WASM}" "${EMITTER_SALT}")"
    invoke_transaction initialize-v1-emitter "${emitter}" initialize \
        --blnd_token "${blnd}" \
        --backstop "${incumbent_backstop}" \
        --backstop_token "${legacy_lp}" >/dev/null
    invoke_transaction set-emitter-as-blnd-admin "${blnd}" set_admin \
        --new_admin "${emitter}" >/dev/null

    pool_hash="$(upload_wasm upload-v2-pool "${V2_POOL_WASM}")"
    incumbent_factory="$(deploy_wasm deploy-incumbent-factory "${V2_FACTORY_WASM}" "" \
        --pool_init_meta \
        "{\"backstop\":\"${incumbent_backstop}\",\"blnd_id\":\"${blnd}\",\"pool_hash\":\"${pool_hash}\"}")"
    v21_factory="$(deploy_wasm deploy-v21-factory "${V2_FACTORY_WASM}" "" \
        --pool_init_meta \
        "{\"backstop\":\"${v21_backstop}\",\"blnd_id\":\"${blnd}\",\"pool_hash\":\"${pool_hash}\"}")"
    deployed="$(deploy_wasm deploy-incumbent-backstop "${V2_BACKSTOP_WASM}" \
        "${INCUMBENT_BACKSTOP_SALT}" \
        --backstop_token "${legacy_lp}" \
        --emitter "${emitter}" \
        --blnd_token "${blnd}" \
        --usdc_token "${usdc}" \
        --pool_factory "${incumbent_factory}" \
        --drop_list '[]')"
    assert_equal "${incumbent_backstop}" "${deployed}" "incumbent backstop address"
    deployed="$(deploy_wasm deploy-v21-backstop "${V2_BACKSTOP_WASM}" \
        "${V21_BACKSTOP_SALT}" \
        --backstop_token "${v21_lp}" \
        --emitter "${emitter}" \
        --blnd_token "${blnd}" \
        --usdc_token "${usdc}" \
        --pool_factory "${v21_factory}" \
        --drop_list '[]')"
    assert_equal "${v21_backstop}" "${deployed}" "V2.1 backstop address"

    receiver="$(deploy_wasm deploy-v21-receiver "${RECEIVER_WASM}" "" \
        --emitter "${emitter}" \
        --legacy_backstop_token "${legacy_lp}" \
        --v2_1_backstop "${v21_backstop}" \
        --v2_1_backstop_token "${v21_lp}" \
        --blnd_token "${blnd}" \
        --ysc_recipient "${ysc}")"

    invoke_transaction mint-incumbent-v1-lp "${legacy_lp}" mint \
        --to "${incumbent_backstop}" --amount "${INCUMBENT_LEGACY_LP}" >/dev/null
    invoke_transaction mint-receiver-v1-lp "${legacy_lp}" mint \
        --to "${receiver}" --amount "${RECEIVER_LEGACY_LP}" >/dev/null
    invoke_transaction mint-v21-backstop-lp "${v21_lp}" mint \
        --to "${v21_backstop}" --amount "${V21_BACKSTOP_LP}" >/dev/null
    invoke_transaction mint-receiver-v21-lp "${v21_lp}" mint \
        --to "${receiver}" --amount "${RECEIVER_V21_LP}" >/dev/null

    note "Queueing and executing the first migration hop..."
    invoke_transaction queue-receiver "${receiver}" queue_receiver >/dev/null
    first_queue="$(invoke_view query-first-queue "${emitter}" get_queued_swap)"
    printf '%s' "${first_queue}" | jq -e \
        --arg receiver "${receiver}" --arg token "${v21_lp}" \
        '.new_backstop == $receiver and .new_backstop_token == $token' >/dev/null ||
        die "first queue does not target the receiver and V2.1 LP"
    first_unlock="$(printf '%s' "${first_queue}" | jq -er '.unlock_time | tonumber')"
    advance_to_timestamp "${first_unlock}"
    returned="$(normalize_scalar "$(invoke_transaction advance-to-v21 \
        "${receiver}" advance_to_v2_1)")"
    assert_equal "${RECEIVER_LEGACY_LP}" "${returned}" "returned legacy LP"
    assert_equal "${receiver}" "$(normalize_scalar "$(invoke_view \
        query-receiver-current "${emitter}" get_backstop)")" "first-hop emitter backstop"
    second_queue="$(invoke_view query-second-queue "${emitter}" get_queued_swap)"
    printf '%s' "${second_queue}" | jq -e \
        --arg backstop "${v21_backstop}" --arg token "${v21_lp}" \
        '.new_backstop == $backstop and .new_backstop_token == $token' >/dev/null ||
        die "second queue does not target V2.1 and its LP"
    second_unlock="$(printf '%s' "${second_queue}" | jq -er '.unlock_time | tonumber')"
    (( second_unlock >= first_unlock + WAIT_SECONDS )) ||
        die "second queue does not enforce a fresh 31-day delay"

    receiver_legacy="$(token_balance query-receiver-v1-lp-after-first "${legacy_lp}" "${receiver}")"
    ysc_legacy="$(token_balance query-ysc-v1-lp-after-first "${legacy_lp}" "${ysc}")"
    receiver_v21="$(token_balance query-receiver-v21-lp-after-first "${v21_lp}" "${receiver}")"
    ysc_v21="$(token_balance query-ysc-v21-lp-after-first "${v21_lp}" "${ysc}")"
    assert_equal "0" "${receiver_legacy}" "receiver legacy LP after first hop"
    assert_equal "${RECEIVER_LEGACY_LP}" "${ysc_legacy}" "YSC legacy LP after first hop"
    assert_equal "0" "${receiver_v21}" "receiver V2.1 LP after first hop"
    assert_equal "${RECEIVER_V21_LP}" "${ysc_v21}" "YSC V2.1 LP after first hop"

    note "Queueing is complete; executing the second migration hop..."
    advance_to_timestamp "${second_unlock}"
    burned="$(normalize_scalar "$(invoke_transaction finalize-v21 \
        "${receiver}" finalize_v2_1)")"
    assert_positive "${burned}" "burned receiver-period BLND"
    assert_equal "${v21_backstop}" "$(normalize_scalar "$(invoke_view \
        query-final-backstop "${emitter}" get_backstop)")" "final emitter backstop"
    final_queue="$(invoke_view query-final-queue "${emitter}" get_queued_swap)"
    printf '%s' "${final_queue}" | jq -e '. == null' >/dev/null ||
        die "emitter queue is not empty after finalization"

    incumbent_blnd="$(token_balance query-incumbent-blnd "${blnd}" "${incumbent_backstop}")"
    receiver_blnd="$(token_balance query-receiver-blnd "${blnd}" "${receiver}")"
    v21_blnd="$(token_balance query-v21-backstop-blnd "${blnd}" "${v21_backstop}")"
    ysc_blnd="$(token_balance query-ysc-blnd "${blnd}" "${ysc}")"
    incumbent_legacy="$(token_balance query-incumbent-v1-lp "${legacy_lp}" "${incumbent_backstop}")"
    candidate_v21="$(token_balance query-v21-backstop-lp "${v21_lp}" "${v21_backstop}")"
    assert_positive "${incumbent_blnd}" "incumbent normal BLND emissions"
    assert_equal "0" "${receiver_blnd}" "receiver BLND after burn"
    assert_equal "0" "${v21_blnd}" "V2.1 one-time BLND allocation"
    assert_equal "0" "${ysc_blnd}" "YSC BLND allocation"
    assert_equal "${INCUMBENT_LEGACY_LP}" "${incumbent_legacy}" "incumbent legacy LP"
    assert_equal "${V21_BACKSTOP_LP}" "${candidate_v21}" "V2.1 backstop LP"

    jq -n \
        --arg run_id "${RUN_ID}" \
        --arg quickstart_image "${QUICKSTART_IMAGE}" \
        --arg quickstart_image_id "${image_id}" \
        --arg operator "${operator}" \
        --arg ysc "${ysc}" \
        --arg blnd "${blnd}" \
        --arg usdc "${usdc}" \
        --arg legacy_lp "${legacy_lp}" \
        --arg v2_1_lp "${v21_lp}" \
        --arg emitter "${emitter}" \
        --arg incumbent_backstop "${incumbent_backstop}" \
        --arg receiver "${receiver}" \
        --arg v2_1_backstop "${v21_backstop}" \
        --arg incumbent_factory "${incumbent_factory}" \
        --arg v2_1_factory "${v21_factory}" \
        --arg pool_wasm_hash "${pool_hash}" \
        --arg receiver_wasm_sha256 "$(sha256_file "${RECEIVER_WASM}")" \
        --argjson first_unlock_time "${first_unlock}" \
        --argjson second_unlock_time "${second_unlock}" \
        --arg burned_blnd "${burned}" \
        --arg incumbent_blnd "${incumbent_blnd}" \
        '{
          run_id: $run_id,
          network: "local",
          protocol: 27,
          quickstart: {image: $quickstart_image, image_id: $quickstart_image_id},
          accounts: {operator: $operator, ysc_recipient: $ysc},
          contracts: {
            blnd: $blnd,
            usdc: $usdc,
            legacy_lp: $legacy_lp,
            v2_1_lp: $v2_1_lp,
            emitter: $emitter,
            incumbent_backstop: $incumbent_backstop,
            receiver: $receiver,
            v2_1_backstop: $v2_1_backstop,
            incumbent_factory: $incumbent_factory,
            v2_1_factory: $v2_1_factory
          },
          artifacts: {
            emitter_sha256: "438a5528cff17ede6fe515f095c43c5f15727af17d006971485e52462e7e7b89",
            receiver_sha256: $receiver_wasm_sha256,
            pool_wasm_hash: $pool_wasm_hash
          },
          migration: {
            first_unlock_time: $first_unlock_time,
            second_unlock_time: $second_unlock_time,
            returned_legacy_lp: "1010000000",
            burned_receiver_period_blnd: $burned_blnd,
            incumbent_normal_blnd: $incumbent_blnd,
            final_backstop: $v2_1_backstop,
            queue_empty: true
          }
        }' >"${RUN_DIR}/result.json"

    TEST_SUCCEEDED=true
    note "Receiver migration localnet E2E passed. Evidence: ${RUN_DIR}"
    jq . "${RUN_DIR}/result.json"
}

main "$@"
