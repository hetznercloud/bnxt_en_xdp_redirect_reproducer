#include "common.h"
#include <bpf_endian.h>
#include <bpf_helpers.h>

enum redirect_target {
  REDIRECT_TARGET_INGRESS,
  REDIRECT_TARGET_EGRESS,
  REDIRECTS_MAX_ENTRIES,
} redirect_target;

struct {
  __uint(type, BPF_MAP_TYPE_DEVMAP);
  __uint(max_entries, REDIRECTS_MAX_ENTRIES);
  __type(key, __u32);
  __type(value, struct bpf_devmap_val);
} redirects SEC(".maps");

SEC("xdp")
int egress(__attribute__((unused)) struct xdp_md *ctx) {
  return bpf_redirect_map(&redirects, REDIRECT_TARGET_EGRESS, XDP_PASS);
}

SEC("xdp")
int ingress(struct xdp_md *ctx) {
  return bpf_redirect_map(&redirects, REDIRECT_TARGET_INGRESS, XDP_PASS);
}
