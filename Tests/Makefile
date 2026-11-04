CC ?= clang
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O1

BINARIES = test_press_machine test_badge_math

.PHONY: all test clean
all: test

test: $(BINARIES)
	@./test_press_machine
	@echo
	@./test_badge_math

test_press_machine: test_press_machine.c ../Sources/WQMPressMachine.c ../Sources/WQMPressMachine.h
	$(CC) $(CFLAGS) -o $@ test_press_machine.c ../Sources/WQMPressMachine.c

test_badge_math: test_badge_math.c ../Sources/WQMBadgeMath.c ../Sources/WQMBadgeMath.h
	$(CC) $(CFLAGS) -o $@ test_badge_math.c ../Sources/WQMBadgeMath.c

clean:
	rm -f $(BINARIES)
