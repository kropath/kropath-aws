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

.PHONY: setup teardown test test-iam test-kms test-sqs test-secretsmanager test-sns test-dynamodb test-eventbridge test-elb test-rds

setup:
	./setup.sh $(CLUSTER_NAME)
	mkdir -p test-results

teardown:
	./teardown.sh $(CLUSTER_NAME)

CHAINSAW_CONFIG := ../.chainsaw.yaml

test:
	chainsaw test . --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/
# 	$(MAKE) teardown

chainsaw-e2e:
	chainsaw test chainsaw/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-iam:
	chainsaw test iam/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-policy:
	chainsaw test policy/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-kms:
	chainsaw test kms/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-s3:
	chainsaw test s3/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-sqs:
	chainsaw test sqs/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-secretsmanager:
	chainsaw test secretsmanager/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-sns:
	chainsaw test sns/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-dynamodb:
	chainsaw test dynamodb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-eventbridge:
	chainsaw test eventbridge/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-elb:
	chainsaw test elb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-rds:
	chainsaw test rds/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/
