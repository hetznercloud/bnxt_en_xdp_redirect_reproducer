#include "common.h"
#include <bpf_helpers.h>

SEC("prog")
int just_pass(struct xdp_md *ctx) { return XDP_PASS; }

char _license[] SEC("license") = "GPL";
