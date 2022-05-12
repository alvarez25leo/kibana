#!/usr/bin/env bash

set -euo pipefail

source .buildkite/scripts/common/util.sh

export CODE_COVERAGE=1 # Kibana is bootstrapped differently for code coverage

.buildkite/scripts/bootstrap.sh

echo "--- Build Platform Plugins"
NODE_OPTIONS=--max_old_space_size=14336 node scripts/build_kibana_platform_plugins --no-examples --test-plugins

is_test_execution_step

export JOB_NUM=$BUILDKITE_PARALLEL_JOB
export JOB=ftr-configs-${JOB_NUM}

FAILED_CONFIGS_KEY="${BUILDKITE_STEP_ID}${BUILDKITE_PARALLEL_JOB:-0}"

# a FTR failure will result in the script returning an exit code of 10
exitCode=0

configs="${FTR_CONFIG:-}"

if [[ "$configs" == "" ]]; then
  echo "--- downloading ftr test run order"
  buildkite-agent artifact download ftr_run_order.json .
  configs=$(jq -r '.groups[env.JOB_NUM | tonumber].names | .[]' ftr_run_order.json)
fi

failedConfigs=""
results=()

while read -r config; do
  if [[ ! "$config" ]]; then
    continue
  fi

  echo "--- $ node scripts/functional_tests --config $config --exclude-tag ''skipCoverage''"
  start=$(date +%s)

  # prevent non-zero exit code from breaking the loop
  set +e
  NODE_OPTIONS=--max_old_space_size=14336 \
    ./node_modules/.bin/nyc \
    --nycrc-path ./src/dev/code_coverage/nyc_config/nyc.server.config.js \
    node scripts/functional_tests \
    --config="$config" \
    --exclude-tag "skipCoverage"
  lastCode=$?
  set -e

  dasherize() {
    withoutExtension=${1%.*}
    dasherized=$(echo "$withoutExtension" | tr '\/' '\-')
  }
  dasherize $config

#  # Server side and client side (server and public dirs)
#  if [[ -d "$KIBANA_DIR/target/kibana-coverage/server" ]]; then
#    echo "--- Server and Client side code coverage collected"
#    mkdir -p target/kibana-coverage/functional
#    mv target/kibana-coverage/server/coverage-final.json "target/kibana-coverage/functional/xpack-${dasherized}-server-coverage.json"
#  fi

  # Each browser unload event, creates a new coverage file.
  # So, we merge them here.
  if [[ -d "$KIBANA_DIR/target/kibana-coverage/functional" ]]; then
    echo "--- Merging code coverage for FTR Config: $config"
    yarn nyc report --nycrc-path src/dev/code_coverage/nyc_config/nyc.functional.config.js --reporter json
    rm -rf target/kibana-coverage/functional/*
    mv target/kibana-coverage/functional-combined/coverage-final.json \
      "target/kibana-coverage/functional/${dasherized}-coverage-final.json"
  else
    echo "--- Code coverage not found in: $KIBANA_DIR/target/kibana-coverage/functional"
  fi

  timeSec=$(($(date +%s) - start))
  if [[ $timeSec -gt 60 ]]; then
    min=$((timeSec / 60))
    sec=$((timeSec - (min * 60)))
    duration="${min}m ${sec}s"
  else
    duration="${timeSec}s"
  fi

  results+=("- $config
    duration: ${duration}
    result: ${lastCode}")

  if [ $lastCode -ne 0 ]; then
    exitCode=10
    echo "FTR exited with code $lastCode"
    echo "^^^ +++"

    if [[ "$failedConfigs" ]]; then
      failedConfigs="${failedConfigs}"$'\n'"$config"
    else
      failedConfigs="$config"
    fi
  fi
done <<<"$configs"

if [[ "$failedConfigs" ]]; then
  buildkite-agent meta-data set "$FAILED_CONFIGS_KEY" "$failedConfigs"
fi

echo "--- FTR configs complete"
printf "%s\n" "${results[@]}"
echo ""

# Force exit 0 to ensure the next build step starts.
exit 0
