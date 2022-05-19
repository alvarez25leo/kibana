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

echo "--- Jest: merging coverage files and generating the final combined report"
yarn nyc report --nycrc-path src/dev/code_coverage/nyc_config/nyc.jest.config.js

echo "--- Functional: merging json files and generating the final combined report"
souce .buildkite/scripts/steps/code_coverage/merge.sh

# TODO-TRE: When we do the FINAL MERGE, we may need replace our anchor (LEETRE) to the
# KIBANA_DIR of the final merge worker so that the merge works: so they point to the
# current source absolute path

set +e
splitCoverage
listReports
splitMerge
listReports
set -e

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
