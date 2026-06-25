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

CLUSTER_NAME ?= kropath-aws-test

.PHONY: setup teardown test test-iam test-kms

setup:
	./setup.sh $(CLUSTER_NAME)

teardown:
	./teardown.sh $(CLUSTER_NAME)

test: setup
	chainsaw test . --parallel 4 --report-format junit --report-path test-results/
	$(MAKE) teardown

test-iam:
	chainsaw test iam/ --parallel 4 --report-format junit --report-path test-results/

test-kms:
	chainsaw test kms/ --parallel 4 --report-format junit --report-path test-results/
