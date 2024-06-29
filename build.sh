#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
trap "rm -rf temp/*tmp.* temp/*/*tmp.*; exit 130" INT

CONFIG_FILE="${1:-config.toml}"
LAST_CONFIG_HASH_FILE="last_config_hash.txt"

if [ "${1-}" = "clean" ]; then
    rm -rf temp build logs build.md $LAST_CONFIG_HASH_FILE
    exit 0
fi

# Function to check if config file has been updated
config_update() {
    local current_hash
    current_hash=$(md5sum "$CONFIG_FILE" | awk '{ print $1 }')

    if [ -f "$LAST_CONFIG_HASH_FILE" ]; then
        local last_hash
        last_hash=$(cat "$LAST_CONFIG_HASH_FILE")

        if [ "$current_hash" == "$last_hash" ]; then
            echo "0"  # No update
            return
        fi
    fi

    # Save the current hash for future comparisons
    echo "$current_hash" > "$LAST_CONFIG_HASH_FILE"
    echo "1"  # Update found
}

if [ "${2-}" = "--config-update" ]; then
    config_update
    exit 0
fi

# Rest of the build.sh script
source utils.sh

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

toml_prep "$(cat 2>/dev/null "$CONFIG_FILE")" || abort "could not find config file '$CONFIG_FILE'\n\tUsage: $0 <config.toml>"

# -- Main config --
main_config_t=$(toml_get_table "")
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
    if [ "$OS" = Android ]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
LOGGING_F=$(toml_get "$main_config_t" logging-to-file) && vtf "$LOGGING_F" "logging-to-file" || LOGGING_F=false
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER=""
DEF_INTEGRATIONS_VER=$(toml_get "$main_config_t" integrations-version) || DEF_INTEGRATIONS_VER=""
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER=""
DEF_PRERELEASE=$(toml_get "$main_config_t" prerelease) || DEF_PRERELEASE=true
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="anddea/revanced-patches"
DEF_INTEGRATIONS_SRC=$(toml_get "$main_config_t" integrations-source) || DEF_INTEGRATIONS_SRC="anddea/revanced-integrations"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="E85Addict/revanced-cli"
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand) || DEF_RV_BRAND="ReVanced"
mkdir -p $TEMP_DIR $BUILD_DIR

: >build.md
ENABLE_MAGISK_UPDATE=$(toml_get "$main_config_t" enable-magisk-update) || ENABLE_MAGISK_UPDATE=true
if [ "$ENABLE_MAGISK_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
    pr "You are building locally. Magisk updates will not be enabled."
    ENABLE_MAGISK_UPDATE=false
fi
# -----------------

if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be within 0-9"; fi
if [ "$LOGGING_F" = true ]; then mkdir -p logs; fi

# -- check_deps --
jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
java --version >/dev/null || abort "\`openjdk 17\` is not installed. install it with 'apt install openjdk-17-jre' or equivalent"
zip --version >/dev/null || abort "\`zip\` is not installed. install it with 'apt install zip' or equivalent"
# ----------------
rm -rf revanced-magisk/bin/*/tmp.*
get_prebuilts

set_prebuilts() {
    local integrations_src=$1 patches_src=$2 cli_src=$3 integrations_ver=$4 patches_ver=$5 cli_ver=$6
    local patches_dir=${patches_src%/*}
    local integrations_dir=${integrations_src%/*}
    local cli_dir=${cli_src%/*}
    cli_ver=${cli_ver#v}
    integrations_ver="${integrations_ver#v}"
    patches_ver="${patches_ver#v}"
    app_args[cli]=$(find "${TEMP_DIR}/${cli_dir,,}-rv" -name "revanced-cli-${cli_ver:-*}-all.jar" -type f -print -quit 2>/dev/null) && [ "${app_args[cli]}" ] || return 1
    app_args[integ]=$(find "${TEMP_DIR}/${integrations_dir,,}-rv" -name "revanced-integrations-${integrations_ver:-*}.apk" -type f -print -quit 2>/dev/null) && [ "${app_args[integ]}" ] || return 1
    app_args[ptjar]=$(find "${TEMP_DIR}/${patches_dir,,}-rv" -name "revanced-patches-${patches_ver:-*}.jar" -type f -print -quit 2>/dev/null) && [ "${app_args[ptjar]}" ] || return 1
    app_args[ptjs]=$(find "${TEMP_DIR}/${patches_dir,,}-rv" -name "patches-${patches_ver:-*}.json" -type f -print -quit 2>/dev/null) && [ "${app_args[ptjs]}" ] || return 1
}

build_rv_w() {
    if [ "$LOGGING_F" = true ]; then
        logf=logs/"${table_name,,}.log"
        : >"$logf"
        { build_rv 2>&1 "$(declare -p app_args)" | tee "$logf"; } &
    else
        build_rv "$(declare -p app_args)" &
    fi
}

declare -A cliriplib
idx=0
for table_name in $(toml_get_table_names); do
    if [ -z "$table_name" ]; then continue; fi
    t=$(toml_get_table "$table_name")
    enabled=$(toml_get "$t" enabled) && vtf "$enabled" "enabled" || enabled=true
    if [ "$enabled" = false ]; then continue; fi
    if ((idx >= PARALLEL_JOBS)); then
        wait -n
        idx=$((idx - 1))
    fi

    declare -A app_args
    patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
    patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
    integrations_src=$(toml_get "$t" integrations-source) || integrations_src=$DEF_INTEGRATIONS_SRC
    integrations_ver=$(toml_get "$t" integrations-version) || integrations_ver=$DEF_INTEGRATIONS_VER
    cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
    cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER
    prerelease=$(toml_get "$t" prerelease) || prerelease=$DEF_PRERELEASE

    if ! set_prebuilts "$integrations_src" "$patches_src" "$cli_src" "$integrations_ver" "$patches_ver" "$cli_ver"; then
        if ! RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$integrations_src" "$integrations_ver" "$patches_src" "$patches_ver" "$prerelease")"; then
            abort "could not download rv prebuilts"
        fi
        read -r rv_cli_jar rv_integrations_apk rv_patches_jar rv_patches_json <<<"$RVP"
        app_args[cli]=$rv_cli_jar
        app_args[integ]=$rv_integrations_apk
        app_args[ptjar]=$rv_patches_jar
        app_args[ptjs]=$rv_patches_json
    fi
    if [[ -v cliriplib[${app_args[cli]}] ]]; then app_args[riplib]=${cliriplib[${app_args[cli]}]}; else
        if [[ $(java -jar "${app_args[cli]}" patch 2>&1) == *rip-lib* ]]; then app_args[riplib]=rip-lib; cliriplib[${app_args[cli]}]=rip-lib; else
            app_args[riplib]=""
        fi
    fi
    app_args[dest]="${BUILD_DIR}/${table_name,,}"
    app_args[patches_name]=$patches_src
    app_args[patches_ver]=$patches_ver
    build_rv_w &
    idx=$((idx + 1))
done
wait
