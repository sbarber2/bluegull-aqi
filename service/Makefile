.PHONY: install lint pylint pytest build validate clean \
        dynamodb-local-setup dynamodb-local-start dynamodb-local-stop run-local

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
