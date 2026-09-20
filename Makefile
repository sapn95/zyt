# The local one-word gate. CI runs the same commands, one job each, so that a
# red check names itself instead of being a log to go and read.
.PHONY: check fmt lint test format install

check: fmt lint test

fmt:
	stylua --check .
	ruff format --check .

lint:
	luacheck .
	ruff check .
	shellcheck scripts/*.sh
	./scripts/leak-lint.sh

# luacov *adds to* luacov.stats.out rather than replacing it, so a second run in
# the same checkout counts every line the first run hit as well. Left alone, the
# reported percentage climbs with the number of times anybody has run the tests.
test:
	rm -f luacov.stats.out luacov.report.out
	busted --coverage
	luacov
	lua scripts/coverage-floor.lua
	python3 -m unittest discover -s tests

# Rewrites the files rather than checking them. Never run in CI.
format:
	stylua .
	ruff format .

install:
	./scripts/zyt link
