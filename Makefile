EMACS ?= emacs
SRC := $(wildcard xiiif*.el)
TESTS := $(wildcard tests/*-test.el)

.PHONY: test compile clean

test:
	$(EMACS) -Q -batch -L . -L tests \
	  $(foreach f,$(TESTS),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q -batch -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

clean:
	rm -f *.elc tests/*.elc
