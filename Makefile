CFLAGS = -g -O3 -Wall -fPIC
ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS += -I$(ERLANG_PATH)

ifeq ($(shell uname),Darwin)
	LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
	LDFLAGS =
endif

PRIV = priv
NIF = $(PRIV)/mcu_mix_nif.so
SRC = c_src/mcu_mix_nif.c

.PHONY: all clean

all: $(PRIV) $(NIF)

$(PRIV):
	mkdir -p $(PRIV)

$(NIF): $(SRC) | $(PRIV)
	$(CC) $(CFLAGS) $(LDFLAGS) -shared -o $@ $(SRC)

clean:
	rm -rf $(NIF) $(NIF).dSYM
