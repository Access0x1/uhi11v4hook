# hooks/Makefile — one name per step, so every session runs the same commands.
#
#   make install   libraries into lib/ at their pins, six SHAs checked
#   make build     compile
#   make test      run every test
#   make fmt       format src/ and test/ (writes files)
#   make context   check every manifest in context/ against the tree, and every hook's routing note
#   make gate      pins, format check, clean build, tests (at least one must run), manifests:
#                  what must pass before a commit

.PHONY: install build test fmt context gate

install:
	./install-deps.sh

build:
	forge build

test:
	forge test -vv

fmt:
	forge fmt

context:
	python3 context/check_context.py
	python3 context/check_routing.py

# `forge test` exits 0 when it finds no tests ("No tests found in project!"), which a stale
# cache can cause: seen 2026-10-01 after a static analyser's partial build. So the gate builds
# from scratch and then requires that tests actually ran and all passed.
gate:
	./install-deps.sh
	forge fmt --check
	forge build --force
	@forge test > out/gate-test.log 2>&1; status=$$?; cat out/gate-test.log; \
	if [ $$status -ne 0 ] || ! grep -Eq '[1-9][0-9]* tests passed, 0 failed, 0 skipped' out/gate-test.log; then \
		echo "gate: forge test failed, or ran no tests"; exit 1; \
	fi
	python3 context/check_context.py
	python3 context/check_routing.py
