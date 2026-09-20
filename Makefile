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

.PHONY: lint lint-crds lint-rgd-cel lint-no-hardcoded-partition lint-onboarding test-onboarding

lint: lint-crds lint-rgd-cel lint-no-hardcoded-partition lint-onboarding

lint-crds:
	bash hack/check-crd-classification.sh

lint-rgd-cel:
	bash hack/check-rgd-cel-balance.sh

lint-no-hardcoded-partition:
	bash hack/check-no-hardcoded-partition.sh

lint-onboarding:
	bash hack/check-family-kind-map.sh
	helm lint onboarding/tenant-namespace -f onboarding/tenant-namespace/tests/values-sample.yaml

test-onboarding:
	bash onboarding/tenant-namespace/tests/render_test.sh
