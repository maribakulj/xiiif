EMACS ?= emacs
SRC := $(wildcard xiiif*.el)
TESTS := $(wildcard tests/*-test.el)

.PHONY: test compile compile-strict clean

# Run the full ERT suite; `make test` picks up any tests/*-test.el
# automatically so new suites are covered without Makefile edits.
test:
	$(EMACS) -Q -batch -L . -L tests \
	  $(foreach f,$(TESTS),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

# Plain byte-compile: warnings are reported but do not fail the build.
# Kept permissive so a legitimate warning in an upstream Emacs version
# does not block unrelated test runs in CI.
compile:
	$(EMACS) -Q -batch -L . \
	  -f batch-byte-compile $(SRC)

# Strict byte-compile: warnings are errors. Used locally and in a
# dedicated CI job so regressions still get caught.
compile-strict:
	$(EMACS) -Q -batch -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

clean:
	rm -f *.elc tests/*.elc
