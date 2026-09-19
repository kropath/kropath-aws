#!/usr/bin/env bash
# Copyright 2026 kropath Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Fails CI if onboarding/tenant-namespace/family-kind-map.yaml has drifted from crds/*config.yaml
# — e.g. a new family's CRD was added without regenerating the onboarding chart's slug->Kind map.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

committed="onboarding/tenant-namespace/family-kind-map.yaml"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cp "$committed" "$tmp"
./hack/gen-family-kind-map.sh >/dev/null

if ! diff -u "$tmp" "$committed"; then
  echo ""
  echo "onboarding/tenant-namespace/family-kind-map.yaml is stale — a crds/*config.yaml family" >&2
  echo "was added, removed, or renamed without regenerating it. Run:" >&2
  echo "  hack/gen-family-kind-map.sh" >&2
  echo "and commit the result." >&2
  cp "$tmp" "$committed"
  exit 1
fi

echo "family-kind-map.yaml is up to date."
