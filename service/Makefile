.PHONY: install lint pylint pytest build validate clean

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

pytest:
	poetry run pytest -vv tests

build: src/requirements.txt
	sam build

validate:
	sam validate --lint

clean:
	rm -rf .aws-sam src/requirements.txt
