.PHONY: install lint pylint pytest build validate clean coldstart-gate \
        dynamodb-local-setup dynamodb-local-start dynamodb-local-stop run-local \
        deploy delete enable disable

# Which named samconfig.toml config-env / stack this targets -- override
# per invocation, e.g. `make deploy ENV=stage`. Only "dev" is actually
# deployed as of bluegull-aqi-q9r.35; stage/prod exist in samconfig.toml
# but are untested.
ENV ?= dev
AWS_PROFILE ?= AdministratorAccess-843088391598
AWS_REGION := us-east-2
STACK_NAME = bluegull-aqi-$(ENV)

install:
	poetry install

# SAM's Python BuildMethod reads requirements.txt from CodeUri (src/), not
# pyproject.toml -- generated fresh each build, never committed (see
# src/.gitignore). poetry.lock is the actual source of truth.
src/requirements.txt: pyproject.toml poetry.lock
	poetry export --without-hashes -f requirements.txt -o src/requirements.txt

lint: pylint

pylint:
	poetry run pylint src tests

# DynamoDB Local is started automatically by a session-scoped pytest fixture
# (tests/conftest.py) -- explicit start/stop below is for `make run-local`
# and manual debugging, not required before `make pytest`.
pytest:
	poetry run pytest -vv tests

build: src/requirements.txt
	sam build

validate:
	sam validate --lint

# AWS-free cold-start proxy (bluegull-aqi-q9r.25) -- requires `make build`
# to have already produced .aws-sam/build/AqiFunction.
coldstart-gate:
	poetry run python3 bin/coldstart_gate.py

clean:
	rm -rf .aws-sam src/requirements.txt

dynamodb-local-setup:
	poetry run python3 bin/dynamodb_local.py setup

dynamodb-local-start:
	poetry run python3 bin/dynamodb_local.py start

dynamodb-local-stop:
	poetry run python3 bin/dynamodb_local.py stop

# No Docker, no SAM CLI, no AWS deploy -- see doc/DESIGN.md "Local
# development (no AWS required)". Requires service/.env with a real
# AIRNOW_API_KEY (copy from .env.example).
run-local:
	poetry run python3 bin/run_local.py

# Real AWS deploy -- builds first so the deployed artifact always matches
# current source. Interactive: samconfig.toml's confirm_changeset = true
# means this shows the changeset and asks before applying, same as running
# `sam deploy` by hand. See doc/DEVINSTALL.md and README.md's own
# "Deploying" section.
deploy: build
	sam deploy --config-env $(ENV) --profile $(AWS_PROFILE)

# Tears down the whole CloudFormation stack -- Lambda, DynamoDB table (and
# its cached data), API Gateway, IAM role, ACM cert, Route53 alias record.
# `sam delete` prompts for confirmation itself; deliberately not passing
# --no-prompts, since this is destructive. Does NOT touch the Route53
# hosted zone or DNS delegation (bluegull-aqi-q9r.6/8ef.18) -- those are
# managed outside this stack, so a future re-deploy won't need to redo
# that. The CloudWatch log group has DeletionPolicy: Retain and survives
# too, on purpose (template.yaml).
delete:
	sam delete --stack-name $(STACK_NAME) --region $(AWS_REGION) --profile $(AWS_PROFILE)

# Kill switch (bluegull-aqi-q9r.35's "how do we disable it while not in
# use" follow-up): sets the deployed Lambda's reserved concurrency to a
# literal 0, which blocks every invocation outright. Different from
# template.yaml's own 0 sentinel (which means "no reservation at all,
# share the account's unreserved pool") -- this is the opposite, an
# explicit hard block, and unlike a real reservation it consumes nothing
# from the account's unreserved-executions floor, so it's always allowed
# regardless of the current quota situation. Outside CloudFormation
# entirely -- no redeploy needed either direction, reverses instantly via
# `make enable`. API Gateway still accepts requests and the client sees an
# error, but nothing downstream (Lambda execution, AirNow calls, DynamoDB)
# actually runs, which is where the real cost/quota exposure lives.
disable:
	@fn=$$(aws cloudformation describe-stack-resource \
		--stack-name $(STACK_NAME) --logical-resource-id AqiFunction \
		--query 'StackResourceDetail.PhysicalResourceId' --output text \
		--region $(AWS_REGION) --profile $(AWS_PROFILE)); \
	echo "Disabling $$fn (reserved concurrency -> 0, blocks all invocations)"; \
	aws lambda put-function-concurrency --function-name "$$fn" \
		--reserved-concurrent-executions 0 \
		--region $(AWS_REGION) --profile $(AWS_PROFILE) >/dev/null && \
	echo "Disabled."

# Reverses `make disable` -- removes the reserved-concurrency override
# entirely, returning the function to the account's shared unreserved
# pool (the same state a fresh `make deploy` leaves it in today, per
# bluegull-aqi-q9r.35).
enable:
	@fn=$$(aws cloudformation describe-stack-resource \
		--stack-name $(STACK_NAME) --logical-resource-id AqiFunction \
		--query 'StackResourceDetail.PhysicalResourceId' --output text \
		--region $(AWS_REGION) --profile $(AWS_PROFILE)); \
	echo "Re-enabling $$fn (removing reserved-concurrency override)"; \
	aws lambda delete-function-concurrency --function-name "$$fn" \
		--region $(AWS_REGION) --profile $(AWS_PROFILE) && \
	echo "Enabled."
