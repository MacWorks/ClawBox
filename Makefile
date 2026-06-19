setup:
	@./clawbox setup; \
	status=$$?; \
	if [ $$status -eq 42 ]; then \
		exit 0; \
	else \
		exit $$status; \
	fi

test:
	bash ./tests/run-all-tests.sh

reset:
	./dev/reset.sh

