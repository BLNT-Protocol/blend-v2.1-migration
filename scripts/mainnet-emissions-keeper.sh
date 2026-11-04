#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/.mainnet"
PID_FILE="${RUNTIME_DIR}/keeper.pid"
LOG_FILE="${RUNTIME_DIR}/keeper.log"

RPC_URL="${BLEND_V21_MAINNET_RPC_URL:-https://soroban-rpc.mainnet.stellar.gateway.fm}"
NETWORK_PASSPHRASE="Public Global Stellar Network ; September 2015"
ACCOUNT_CONFIG="${BLEND_V21_KEEPER_ACCOUNT_CONFIG:-}"
INTERVAL_SECONDS="${BLEND_V21_KEEPER_INTERVAL_SECONDS:-3600}"
INCLUSION_FEE="${BLEND_V21_KEEPER_INCLUSION_FEE:-10000}"

KEEPER_ACCOUNT="GDEA2WMOWYQ3T56A2PZH5QYYEQBAORW2AUUJYX4FFD5GDPESAICTFTAL"
EMITTER="CCOQM6S7ICIUWA225O5PSJWUBEMXGFSSW2PQFO6FP4DQEKMS5DASRGRR"
LEGACY_V2_BACKSTOP="CAQQR5SWBXKIGZKPBZDH3KM5GQ5GUTPKB7JAFCINLZBC5WXPJKRG3IM7"
V21_BACKSTOP="CCS4AZ5ORM6VLLPJTJUFRNXWBMHOO3L5WHHRPL2ZMILE35ZDMQFHOQMJ"
V21_POOL="CBAKAZUEJBAFA2DCGBRS2WKJT3FNIMJBHTFL76AY7XMAVEINQNNIQWAO"
V21_BACKSTOP_TOKEN="CASYAKK3SHDN6S2E6IUOBVRXT3KKPVQCVQO4GNBDTVE6XZQQMW4UMIHE"
V21_ORACLE="CCVTVW2CVA7JLH4ROQGP3CU4T3EXVCK66AZGSM4MUQPXAI4QHCZPOATS"
XLM_TOKEN="CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA"
USDC_TOKEN="CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75"
EURC_TOKEN="CDTKPWPLOURQA2SGTKTUQOWRCBZEORB4BWBOMJ3D3ZTQQSGE5F6JBQLV"

STOP_REQUESTED=0
SLEEP_PID=""
KEY_CONFIG_DIR=""
OWNS_PID=false
EXPECTED_ERROR_CODE=""

usage() {
    cat <<'EOF'
Usage: scripts/mainnet-emissions-keeper.sh COMMAND

Commands:
  plan    Validate the designated mainnet deployment and simulate one pass.
  once    Validate the deployment and submit one keeper pass.
  run     Submit one pass immediately, then repeat every hour by default.
  status  Report whether the keeper process is running.
  stop    Ask the running keeper process to stop.

Set BLEND_V21_KEEPER_ACCOUNT_CONFIG to a shell file containing matching
STELLAR_PUBLIC_KEY and STELLAR_SECRET_KEY values. The designated account is
used only to pay fees for permissionless emissions-maintenance calls.

This keeper advances V2.1 legacy backfill accounting without calling the
incumbent V1 emitter. It stops if the emitter recipient changes.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

keeper_note() {
    local message
    message="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
    printf '%s\n' "${message}" >&2
    if [[ -d "${RUNTIME_DIR}" ]]; then
        printf '%s\n' "${message}" >>"${LOG_FILE}"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "$2 must be a positive integer"
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

stellar_cli() {
    stellar --config-dir "${KEY_CONFIG_DIR}" "$@"
}

load_keeper_identity() {
    local derived_key
    [[ -n "${ACCOUNT_CONFIG}" ]] ||
        die "BLEND_V21_KEEPER_ACCOUNT_CONFIG must name the keeper account file"
    [[ -f "${ACCOUNT_CONFIG}" ]] || die "keeper account file not found: ${ACCOUNT_CONFIG}"

    # shellcheck disable=SC1090
    source "${ACCOUNT_CONFIG}"
    [[ "${STELLAR_PUBLIC_KEY:-}" == "${KEEPER_ACCOUNT}" ]] ||
        die "keeper account must be ${KEEPER_ACCOUNT}"
    [[ "${STELLAR_SECRET_KEY:-}" =~ ^S[A-Z2-7]{55}$ ]] ||
        die "keeper account file does not contain a valid STELLAR_SECRET_KEY"

    KEY_CONFIG_DIR="$(mktemp -d)"
    chmod 700 "${KEY_CONFIG_DIR}"
    printf '%s\n' "${STELLAR_SECRET_KEY}" |
        stellar --config-dir "${KEY_CONFIG_DIR}" keys add mainnet-v21-keeper \
            --secret-key >/dev/null 2>&1
    unset STELLAR_SECRET_KEY
    derived_key="$(stellar_cli keys public-key mainnet-v21-keeper)"
    [[ "${derived_key}" == "${KEEPER_ACCOUNT}" ]] ||
        die "keeper secret key does not match ${KEEPER_ACCOUNT}"
}

network_healthy() {
    curl --fail --silent --show-error --max-time 10 \
        --header 'Content-Type: application/json' \
        --request POST \
        --data '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
        "${RPC_URL}" 2>/dev/null |
        jq -e '.result.status == "healthy"' >/dev/null 2>&1
}

capture_invoke() {
    local send="$1" contract="$2" function="$3" output status attempt
    shift 3
    for attempt in 1 2 3 4 5; do
        set +e
        output="$(stellar_cli contract invoke \
            --id "${contract}" \
            --source-account mainnet-v21-keeper \
            --rpc-url "${RPC_URL}" \
            --network-passphrase "${NETWORK_PASSPHRASE}" \
            --send "${send}" --cost -- "${function}" "$@" 2>&1)"
        status=$?
        set -e
        if (( status == 0 )); then
            printf '%s' "${output}"
            return 0
        fi
        if [[ "${output}" != *"client error (Connect)"* &&
            "${output}" != *"connection closed"* &&
            "${output}" != *"timed out"* &&
            "${output}" != *"dns error"* ]]
        then
            break
        fi
        (( attempt == 5 )) || sleep 2
    done
    printf '%s' "${output}"
    return "${status}"
}

invoke_view() {
    local contract="$1" function="$2"
    shift 2
    capture_invoke no "${contract}" "${function}" "$@"
}

is_expected_error() {
    local output="$1" code
    shift
    for code in "$@"; do
        if [[ "${output}" =~ \#${code}([^0-9]|$) ]]; then
            EXPECTED_ERROR_CODE="${code}"
            return 0
        fi
    done
    return 1
}

validate_deployment() {
    local recipient reward backstop_token pool_config reserve_list native_balance
    network_healthy || die "mainnet RPC is unavailable at ${RPC_URL}"

    recipient="$(normalize_scalar "$(invoke_view "${EMITTER}" get_backstop)")"
    [[ "${recipient}" == "${LEGACY_V2_BACKSTOP}" ]] ||
        die "emitter recipient changed to ${recipient}; review the completed migration before restarting"

    reward="$(invoke_view "${V21_BACKSTOP}" reward_zone)"
    printf '%s' "${reward}" | jq -e --arg pool "${V21_POOL}" \
        'length == 1 and .[0] == $pool' >/dev/null ||
        die "Fixed v2.1 is not the sole V2.1 reward-zone member"

    backstop_token="$(normalize_scalar "$(invoke_view "${V21_BACKSTOP}" backstop_token)")"
    [[ "${backstop_token}" == "${V21_BACKSTOP_TOKEN}" ]] ||
        die "unexpected V2.1 backstop token: ${backstop_token}"

    pool_config="$(invoke_view "${V21_POOL}" get_config)"
    printf '%s' "${pool_config}" | jq -e --arg oracle "${V21_ORACLE}" \
        '(.status == 0 or .status == 1) and .oracle == $oracle' >/dev/null ||
        die "Fixed v2.1 is not active or has an unexpected oracle"

    reserve_list="$(invoke_view "${V21_POOL}" get_reserve_list)"
    printf '%s' "${reserve_list}" | jq -e \
        --arg xlm "${XLM_TOKEN}" --arg usdc "${USDC_TOKEN}" --arg eurc "${EURC_TOKEN}" \
        'length == 3 and .[0] == $xlm and .[1] == $usdc and .[2] == $eurc' >/dev/null ||
        die "Fixed v2.1 reserve list does not match XLM, USDC, and EURC"

    native_balance="$(curl --fail --silent --show-error --max-time 10 \
        "https://horizon.stellar.org/accounts/${KEEPER_ACCOUNT}" |
        jq -er '.balances[] | select(.asset_type == "native") | .balance')"
    awk -v balance="${native_balance}" 'BEGIN { exit !(balance >= 1) }' ||
        die "keeper account has less than 1 XLM"

    keeper_note "Validated mainnet Fixed v2.1 deployment and keeper account (${native_balance} XLM)."
}

plan_call() {
    local label="$1" contract="$2" function="$3" output
    shift 3
    if output="$(capture_invoke no "${contract}" "${function}")"; then
        keeper_note "${label}: ready ($(printf '%s\n' "${output}" | tail -n 1))"
        return
    fi
    if is_expected_error "${output}" "$@"; then
        keeper_note "${label}: not ready (contract error #${EXPECTED_ERROR_CODE})"
        return
    fi
    die "${label} simulation failed: ${output}"
}

run_call() {
    local label="$1" contract="$2" function="$3" output
    shift 3
    if ! output="$(capture_invoke no "${contract}" "${function}")"; then
        if is_expected_error "${output}" "$@"; then
            keeper_note "${label}: skipped (contract error #${EXPECTED_ERROR_CODE})"
            return 0
        fi
        keeper_note "${label}: simulation failed: ${output}"
        return 1
    fi
    if ! output="$(capture_invoke yes "${contract}" "${function}")"; then
        if is_expected_error "${output}" "$@"; then
            keeper_note "${label}: another keeper changed state (contract error #${EXPECTED_ERROR_CODE})"
            return 0
        fi
        keeper_note "${label}: submission failed: ${output}"
        return 1
    fi
    keeper_note "${label}: submitted ($(printf '%s\n' "${output}" | tail -n 1))"
}

plan_pass() {
    validate_deployment
    keeper_note "The incumbent V1 emitter would not be called during legacy backfill."
    plan_call "checkpoint V2.1 backstop" "${V21_BACKSTOP}" distribute 1000 1010
    plan_call "gulp Fixed v2.1 emissions" "${V21_POOL}" gulp_emissions 1000 1200
}

run_pass() {
    local failed=0
    validate_deployment
    keeper_note "Skipping the incumbent V1 emitter during legacy backfill."
    run_call "checkpoint V2.1 backstop" "${V21_BACKSTOP}" distribute 1000 1010 || failed=1
    run_call "gulp Fixed v2.1 emissions" "${V21_POOL}" gulp_emissions 1000 1200 || failed=1
    (( failed == 0 )) || return 1
    keeper_note "Legacy backfill keeper pass completed successfully."
}

request_stop() {
    STOP_REQUESTED=1
    [[ -z "${SLEEP_PID}" ]] || kill "${SLEEP_PID}" 2>/dev/null || true
}

cleanup() {
    if [[ "${OWNS_PID}" == "true" && -f "${PID_FILE}" && "$(<"${PID_FILE}")" == "$$" ]]; then
        rm -f "${PID_FILE}"
    fi
    if [[ -n "${KEY_CONFIG_DIR}" && -d "${KEY_CONFIG_DIR}" ]]; then
        rm -rf "${KEY_CONFIG_DIR}"
    fi
}

keeper_process_is_running() {
    local pid="$1" process_command
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    process_command="$(ps -p "${pid}" -o command= 2>/dev/null)" || return 1
    case "${process_command}" in
        "bash scripts/mainnet-emissions-keeper.sh run" | \
            "/bin/bash scripts/mainnet-emissions-keeper.sh run" | \
            "bash ./scripts/mainnet-emissions-keeper.sh run" | \
            "/bin/bash ./scripts/mainnet-emissions-keeper.sh run" | \
            "bash ${ROOT_DIR}/scripts/mainnet-emissions-keeper.sh run" | \
            "/bin/bash ${ROOT_DIR}/scripts/mainnet-emissions-keeper.sh run")
            return 0
            ;;
    esac
    return 1
}

acquire_pid() {
    local existing_pid=""
    mkdir -p "${RUNTIME_DIR}"
    if [[ -f "${PID_FILE}" ]]; then
        existing_pid="$(<"${PID_FILE}")"
        if keeper_process_is_running "${existing_pid}"; then
            die "mainnet keeper is already running as PID ${existing_pid}"
        fi
    fi
    printf '%s\n' "$$" >"${PID_FILE}"
    OWNS_PID=true
}

run_forever() {
    local pass=0
    acquire_pid
    trap request_stop INT TERM
    keeper_note "Mainnet keeper started; pass interval is ${INTERVAL_SECONDS}s."
    while (( STOP_REQUESTED == 0 )); do
        pass=$((pass + 1))
        keeper_note "Beginning scheduled pass ${pass}."
        run_pass || keeper_note "Pass ${pass} failed; retrying next interval."
        (( STOP_REQUESTED != 0 )) && break
        sleep "${INTERVAL_SECONDS}" &
        SLEEP_PID=$!
        wait "${SLEEP_PID}" || true
        SLEEP_PID=""
    done
    keeper_note "Mainnet keeper stopped."
}

show_status() {
    local pid=""
    if [[ -f "${PID_FILE}" ]]; then
        pid="$(<"${PID_FILE}")"
    fi
    if keeper_process_is_running "${pid}"; then
        printf 'running (PID %s)\n' "${pid}"
        [[ ! -f "${LOG_FILE}" ]] || tail -n 12 "${LOG_FILE}"
        return
    fi
    printf 'stopped\n'
    return 1
}

stop_keeper() {
    local pid=""
    [[ -f "${PID_FILE}" ]] && pid="$(<"${PID_FILE}")"
    keeper_process_is_running "${pid}" ||
        die "PID file does not identify a running mainnet keeper; refusing to signal"
    kill -TERM "${pid}"
    printf 'stop requested for PID %s\n' "${pid}"
}

main() {
    local command="${1:-}"
    case "${command}" in
        plan|once|run|status|stop) ;;
        help|-h|--help) usage; return ;;
        *) usage >&2; exit 2 ;;
    esac

    require_command awk
    require_command curl
    require_command jq
    require_command ps
    require_command stellar
    require_positive_integer "${INTERVAL_SECONDS}" "keeper interval"
    require_positive_integer "${INCLUSION_FEE}" "keeper inclusion fee"
    mkdir -p "${RUNTIME_DIR}"

    case "${command}" in
        status) show_status; return ;;
        stop) stop_keeper; return ;;
    esac

    export STELLAR_INCLUSION_FEE="${INCLUSION_FEE}"
    load_keeper_identity
    case "${command}" in
        plan) plan_pass ;;
        once) run_pass ;;
        run) run_forever ;;
    esac
}

trap cleanup EXIT
main "$@"
