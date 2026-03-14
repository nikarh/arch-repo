CC = gcc
CFLAGS = -s -Wall -O3
BIN ?= $(PWD)/target
NAME = xorg-on-input-hierarchy-change

CFLAGS_LIBS = $(shell pkg-config --cflags --libs x11 xi)

default: $(BIN)/$(NAME)
$(BIN)/$(NAME): *.c
	$(CC) $(CFLAGS) -o $@ $< $(CFLAGS_LIBS)

clean:
	rm -f $(BIN)/$(NAME)

.PHONY: clean
