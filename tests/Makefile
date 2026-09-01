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

# NOTE: every service suite must keep its own explicit `test-<service>:` target.
# tests/select-tests.sh discovers the known services by grepping this file for
# `^test-<service>:` lines, so collapsing these into a `test-%:` pattern rule would
# silently break CI's changed-file test selection (it would fall back to the full
# suite, or skip a service, depending on the diff).
.PHONY: setup teardown test chainsaw-e2e lint-test-scripts \
	test-acm test-apigateway test-apigatewayv2 test-athena test-autoscaling test-cloudfront \
	test-cloudtrail test-cloudwatch test-cloudwatchlogs test-cognito test-documentdb test-dsql test-dynamodb test-ec2 test-ecr test-ecs test-efs \
	test-eks test-elasticache test-elb test-eventbridge test-glue test-iam test-keyspaces test-kinesis test-kms \
	test-lambda test-memorydb test-mq test-msk test-opensearch test-pipes test-policy test-rds test-route53 test-s3 test-secretsmanager \
	test-sns test-sqs test-ssm test-stepfunctions

setup:
	./setup.sh $(CLUSTER_NAME)
	mkdir -p test-results

# lint-test-scripts: fail fast when a kubectl get in a - script: step addresses an ACK resource
# by an unqualified bare or short name instead of <plural>.<service>.services.k8s.aws.
#
# Any `kubectl get <word>` where <word> is a known ACK resource name (listed below) and does
# NOT already contain a dot is an error — it will resolve to whichever API group sorts first in
# the discovery cache and silently break when a second ACK service installs a CRD with the same
# plural (see docs/frequent-rgd-errors.md §"Ambiguous kubectl Resource Name").
lint-test-scripts:
	@echo "==> Checking for unqualified ACK resource names in chainsaw test scripts..."
	@./lint-test-scripts.sh
	@echo "==> lint-test-scripts: PASS"

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

test-keyspaces:
	chainsaw test keyspaces/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-kinesis:
	chainsaw test kinesis/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

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

test-documentdb:
	chainsaw test documentdb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-dsql:
	chainsaw test dsql/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-dynamodb:
	chainsaw test dynamodb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-eventbridge:
	chainsaw test eventbridge/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-elb:
	chainsaw test elb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-rds:
	chainsaw test rds/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-cloudtrail:
	chainsaw test cloudtrail/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-cloudwatch:
	chainsaw test cloudwatch/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-cloudwatchlogs:
	chainsaw test cloudwatchlogs/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-cognito:
	chainsaw test cognito/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-cloudfront:
	chainsaw test cloudfront/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-ec2:
	chainsaw test ec2/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-athena:
	chainsaw test athena/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-autoscaling:
	chainsaw test autoscaling/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-lambda:
	chainsaw test lambda/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-ecs:
	chainsaw test ecs/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-eks:
	chainsaw test eks/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-mq:
	chainsaw test mq/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-msk:
	chainsaw test msk/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-pipes:
	chainsaw test pipes/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-ecr:
	chainsaw test ecr/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-efs:
	chainsaw test efs/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-apigateway:
	chainsaw test apigateway/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-apigatewayv2:
	chainsaw test apigatewayv2/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-elasticache:
	chainsaw test elasticache/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-memorydb:
	chainsaw test memorydb/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-acm:
	chainsaw test acm/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-opensearch:
	chainsaw test opensearch/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-ssm:
	chainsaw test ssm/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-stepfunctions:
	chainsaw test stepfunctions/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-route53:
	chainsaw test route53/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/

test-glue:
	chainsaw test glue/ --config $(CHAINSAW_CONFIG) --parallel 4 --report-format JUNIT-TEST --report-path test-results/
