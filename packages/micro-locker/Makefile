CC = gcc
CFLAGS = -s -Wall -O3
BIN ?= $(PWD)/target

CFLAGS_DBUS = $(shell pkg-config --cflags --libs dbus-1)

default: $(BIN)/micro-locker
$(BIN)/micro-locker: *.c
	mkdir -p "$(BIN)"
	$(CC) $(CFLAGS) $< -o $@ $(CFLAGS_DBUS)

clean:
	rm -f $(BIN)/micro-locker

.PHONY: clean