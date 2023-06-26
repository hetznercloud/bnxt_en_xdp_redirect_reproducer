#include "common.h"
#include <bpf_endian.h>
#include <bpf_helpers.h>

#define ETH_PROTO_IPV4 0x0800
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

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

enum counter_key {
  COUNTER_KEY_INGRESS_MATCH,
  COUNTER_KEY_INGRESS_REDIRECT_SUCCESS,
  COUNTER_KEY_EGRESS_REDIRECT_SUCCESS,
  COUNTERS_MAX_ENTRIES,
} counter_key;

struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, COUNTERS_MAX_ENTRIES);
  __type(key, __u32);
  __type(value, __u64);
} counters SEC(".maps");

static __always_inline void count(const enum counter_key key) {
  __u32 *count = bpf_map_lookup_elem(&counters, &key);
  if (count) {
    __sync_fetch_and_add(count, 1);
  }
}

struct l4stubhdr {
  __u16 sport;
  __u16 dport;
};

/* Check if ingress packets are replies to our test packet. Test packets are
 * supposed to UDP or TCP sent with a local port from the range 32700 to 32767.
 * This port range is just ahead of the default dynamic port range of current
 * kernels that starts with 32768.
 * So only UDP and TCP packets with destination port in the range 32700 to 32767
 * return true.
 */
static __always_inline bool is_test_pkt_reply(struct xdp_md *ctx) {
  void *data = (void *)(long)ctx->data;
  void *data_end = (void *)(long)ctx->data_end;

  struct ethhdr *eth = data;
  struct iphdr *ip = (struct iphdr *)(eth + 1);
  struct l4stubhdr *l4stub = (struct l4stubhdr *)(ip + 1);

  if ((void *)(l4stub + 1) > data_end) {
    return false;
  }
  if (eth->h_proto != bpf_htons(ETH_PROTO_IPV4) || ip->ihl != 5) {
    return false;
  }

  if (ip->protocol != IPPROTO_TCP && ip->protocol != IPPROTO_UDP) {
    return false;
  }

  __u16 dport = bpf_ntohs(l4stub->dport);
  return dport >= 32700 && dport <= 32767;
}

/* For egress, just redirect anything to the uplink interface. */
SEC("xdp")
int egress_by_map(__attribute__((unused)) struct xdp_md *ctx) {
  int verdict = bpf_redirect_map(&redirects, REDIRECT_TARGET_EGRESS, XDP_PASS);
  if (verdict == XDP_REDIRECT) {
    count(COUNTER_KEY_EGRESS_REDIRECT_SUCCESS);
  }

  return verdict;
}

SEC("xdp")
int egress_no_map(__attribute__((unused)) struct xdp_md *ctx) {
  int key = REDIRECT_TARGET_EGRESS;
  struct bpf_devmap_val *value = bpf_map_lookup_elem(&redirects, &key);

  if (!value) {
    return XDP_PASS;
  }

  int verdict = bpf_redirect(value->ifindex, 0);
  if (verdict == XDP_REDIRECT) {
    count(COUNTER_KEY_EGRESS_REDIRECT_SUCCESS);
  }

  return verdict;
}

/* For ingress, redirect only packets passing our spec in is_test_pkt(). */
SEC("xdp")
int ingress_by_map(struct xdp_md *ctx) {
  if (!is_test_pkt_reply(ctx)) {
    return XDP_PASS;
  }
  count(COUNTER_KEY_INGRESS_MATCH);

  int verdict = bpf_redirect_map(&redirects, REDIRECT_TARGET_INGRESS, XDP_PASS);
  if (verdict == XDP_REDIRECT) {
    count(COUNTER_KEY_INGRESS_REDIRECT_SUCCESS);
  }

  return verdict;
}

SEC("xdp")
int ingress_no_map(struct xdp_md *ctx) {
  if (!is_test_pkt_reply(ctx)) {
    return XDP_PASS;
  }
  count(COUNTER_KEY_INGRESS_MATCH);

  int key = REDIRECT_TARGET_INGRESS;
  struct bpf_devmap_val *value = bpf_map_lookup_elem(&redirects, &key);

  if (!value) {
    return XDP_PASS;
  }

  int verdict = bpf_redirect(value->ifindex, 0);
  if (verdict == XDP_REDIRECT) {
    count(COUNTER_KEY_INGRESS_REDIRECT_SUCCESS);
  }

  return verdict;
}
