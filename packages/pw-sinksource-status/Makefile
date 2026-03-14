CC = gcc
CXX = g++
CFLAGS = -s -Wall -O3
CXXFLAGS = -s -Wall -O3 -std=c++23
BIN ?= $(PWD)/target
NAME = pw-sinksource-status

PW_FLAGS = $(shell pkg-config --cflags --libs libpipewire-0.3)

default: $(BIN)/$(NAME) $(BIN)/$(NAME_CXX)

$(BIN)/$(NAME): pw-sinksource-status.c | $(BIN)
	$(CC) $(CFLAGS) -o $@ $< $(PW_FLAGS)

$(BIN):
	mkdir -p $(BIN)

clean:
	rm -f $(BIN)/$(NAME) $(BIN)/$(NAME_CXX)

.PHONY: clean default
