#!/usr/bin/env bash

set -euo pipefail

source .buildkite/scripts/common/util.sh

export CODE_COVERAGE=1

base=target/kibana-coverage
target=$base/functional
first=$base/first

splitCoverage() {
  echo "--- Running splitCoverage"
  count=$(ls $1 | wc -l | xargs) # xargs trims whitespace
  echo "### total: $count"

  mkdir -p $first
  half=$(($count / 2))
  echo "### half: $half"

  for x in $(seq 1 $half); do
    mv "$1/$(ls $1 | head -1)" $first
  done

  echo "### first half:"
  wc -l $first
  echo "### rest"
  wc -l $target
}

splitMerge() {
  echo "--- Merge the first half of the coverage files"
  firstCombined="${first}-combined"
  mkdir -p $firstCombined
  COVERAGE_TEMP_DIR=$first yarn nyc report --nycrc-path \
    src/dev/code_coverage/nyc_config/nyc.functional.config.js --report-dir $firstCombined
  mv "${firstCombined}/*.json" $target || echo "--- No coverage files found at ${firstCombined}/*.json"
  mv "${firstCombined}/**/*.json" $target || echo "--- No coverage files found at ${firstCombined}/**/*.json"

  echo "--- Merge the rest of the coverage files"
  yarn nyc report --nycrc-path src/dev/code_coverage/nyc_config/nyc.functional.config.js
}

listReports() {
  ls -R $base
}

finalReplace() {
  echo "### KIBANA_DIR in finalReplace fn: $KIBANA_DIR"
#  TODO-TRE: Drop hardcoded replacement anchor
  anchor=LEETRE
  sed -ie "s|$anchor|${KIBANA_DIR}|g" \
    target/kibana-coverage/functional/*.json
}
