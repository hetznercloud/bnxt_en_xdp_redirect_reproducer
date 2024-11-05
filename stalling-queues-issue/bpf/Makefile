CLANG = clang
BPF_OBJS = redirect.o pass.o

all: $(BPF_OBJS)

%.o: %.c common.h
	$(CLANG) -v -g -Wall  -O2 -target bpfel -nostdinc -Ilibbpf -c $< -o $@

.PHONY: clean
clean:
	rm -rfv $(BPF_OBJS)
