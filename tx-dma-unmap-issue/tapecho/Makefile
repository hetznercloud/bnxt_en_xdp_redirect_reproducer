CCFLAGS ?= -Wall -O2 -D_GNU_SOURCE -luring
all_targets = tapecho

.PHONY: tapecho clean

all: $(all_targets)

clean:
	rm -f $(all_targets)

tapecho:
	$(CC) tapecho.c -o ./tapecho  ${CCFLAGS}

