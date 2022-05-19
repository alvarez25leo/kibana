#!/usr/bin/env bash

set -euo pipefail

source .buildkite/scripts/common/util.sh

export CODE_COVERAGE=1
echo "--- Reading Kibana stats cluster creds from vault"
export USER_FROM_VAULT="$(retry 5 5 vault read -field=username secret/kibana-issues/prod/coverage/elasticsearch)"
export PASS_FROM_VAULT="$(retry 5 5 vault read -field=password secret/kibana-issues/prod/coverage/elasticsearch)"
export HOST_FROM_VAULT="$(retry 5 5 vault read -field=host secret/kibana-issues/prod/coverage/elasticsearch)"
export TIME_STAMP=$(date +"%Y-%m-%dT%H:%M:00Z")

echo "--- Download previous git sha"
.buildkite/scripts/steps/code_coverage/reporting/downloadPrevSha.sh
previousSha=$(cat downloaded_previous.txt)

echo "--- Upload new git sha"
.buildkite/scripts/steps/code_coverage/reporting/uploadPrevSha.sh

.buildkite/scripts/bootstrap.sh

echo "--- Download coverage arctifacts"
buildkite-agent artifact download target/kibana-coverage/jest/* .
buildkite-agent artifact download target/kibana-coverage/functional/* .

echo "--- process HTML Links"
.buildkite/scripts/steps/code_coverage/reporting/prokLinks.sh

echo "--- collect VCS Info"
.buildkite/scripts/steps/code_coverage/reporting/collectVcsInfo.sh

# echo "--- Replace path in coverage json files"
# export COVERAGE_TEMP_DIR=$KIBANA_DIR/target/kibana-coverage
# sed -i -e "s|/var/lib/buildkite-agent/builds/kb-n2-4-spot-2-[[:alnum:]\-]\{16\}/elastic/kibana-code-coverage-main/kibana|${KIBANA_DIR}|g" \
#   $COVERAGE_TEMP_DIR/**/*.json
# #sed -ie "s|\/var\/lib\/buildkite-agent\/builds\/kb-n2-4-spot-2-[[:alnum:]\-]*\/elastic\/kibana-code-coverage-main\/kibana|${KIBANA_DIR}|g" \
# #  $COVERAGE_TEMP_DIR/**/*.json

echo "--- Jest: merging coverage files and generating the final combined report"
yarn nyc report --nycrc-path src/dev/code_coverage/nyc_config/nyc.jest.config.js

echo "--- Functional: merging json files and generating the final combined report"
target=target/kibana-coverage/functional
first="target/kibana-coverage/first"
splitCoverage () {
  count=$(ls $1 | wc -l | xargs) # xargs trims whitespace
  echo "### total: $count"

  mkdir -p $first
  half=$(($count / 2))
  echo "### half: $half"

  for x in $(seq 1 $half); do
    mv "$1/$(ls $1 | head -1)" $first
  done
}

echo "--- Running splitCoverage fn"
splitCoverage $target
echo "### first half:"
wc -l $first
echo "### rest"
wc -l $target

splitMerge () {
  echo "--- Merge the first half of the coverage files"
  firstCombined="${first}-combined"
  COVERAGE_TEMP_DIR=$first yarn nyc report --nycrc-path \
    src/dev/code_coverage/nyc_config/nyc.functional.config.js --report-dir $firstCombined
  mv "${firstCombined}/*.json" $target || echo "--- No coverage files found at ${firstCombined}/*.json"
  mv "${firstCombined}/**/*.json" $target || echo "--- No coverage files found at ${firstCombined}/**/*.json"

  echo "--- Merge the rest of the coverage files"
  yarn nyc report --nycrc-path src/dev/code_coverage/nyc_config/nyc.functional.config.js
}

splitMerge

$seached=target/kibana-coverage
echo "--- Grep for replaced paths, in every folder under $searched, should find none"
grep -R $KIBANA_DIR $searched

# archive reports to upload as build artifacts
echo "--- Archive and upload combined reports"
tar -czf target/kibana-coverage/jest/kibana-jest-coverage.tar.gz target/kibana-coverage/jest-combined
tar -czf target/kibana-coverage/functional/kibana-functional-coverage.tar.gz target/kibana-coverage/functional-combined
buildkite-agent artifact upload 'target/kibana-coverage/jest/kibana-jest-coverage.tar.gz'
buildkite-agent artifact upload 'target/kibana-coverage/functional/kibana-functional-coverage.tar.gz'

echo "--- Upload coverage static site"
.buildkite/scripts/steps/code_coverage/reporting/uploadStaticSite.sh

echo "--- Ingest results to Kibana stats cluster"
.buildkite/scripts/steps/code_coverage/reporting/ingestData.sh 'Elastic/kibana-code-coverage' \
  ${BUILDKITE_BUILD_NUMBER} ${BUILDKITE_BUILD_URL} ${previousSha} \
  'src/dev/code_coverage/ingest_coverage/team_assignment/team_assignments.txt'
