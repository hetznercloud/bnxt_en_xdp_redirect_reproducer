#!/bin/bash

set -eEuo pipefail

# Override bpftool command, if it is not in $PATH.
: ${BPFTOOL:=bpftool}

# The uplink interface. This is the bnxt_en interface.
: ${UPLINK_IF:=eth0}

# Host to fetch a http resource from. Must be an IPv4 address.
: ${TEST_HOST:=185.12.64.3}
# HTTP resource to fetch. Should not be smaller than 10MB.
: ${TEST_RESOURCE:=/ubuntu/packages/pool/main/l/linux-signed/kernel-signed-image-5.4.0-100-generic-di_5.4.0-100.113_amd64.udeb}

: ${REDIR_IF:=in0}
: ${CLONE_IF:=out0}
: ${BPFFS_DIR:=/sys/fs/bpf/redirect}
: ${BPF_REDIRECT_OBJ:=bpf/redirect.o}

REDIRECT_TARGET_EGRESS=1

__byte_fmt() {
	local -i i="$1"
	local -i max="$2"
	for ((n = 0; n < max; n++)); do
		printf "%#x\n" $((i % 256))
		i=$((i / 256))
	done
}

__set_redirect() {
	local key="$(__byte_fmt "$1" 4)"
	local value="$(__byte_fmt "$2" 8)"
	$BPFTOOL map update name redirects key $key value $value
}

cleanup() {
	ip link set "$UPLINK_IF" xdp off
	rm -rf "$BPFFS_DIR"
	ip link del "$REDIR_IF" || true
}

# Parse forwarding information needed to send test traffic out on the clone
# interface. We use the uplink interface's IPv4 and MAC address, so there's
# no need to modify the packet in any way in eBPF.
get_fib_info_to_target() {
	local UPLINK_IF=$1
	local target=$2

	# Parse route to the test host on the uplink interface.
	local route_parts=($(ip route get "$target" dev "$UPLINK_IF"))
	if [[ ${route_parts[1]} != "via" ]]; then
		echo "route not a nexthop route (missing via)? '${route_parts[@]}'" >&2
		return 1
	elif [[ ${route_parts[5]} != "src" ]]; then
		echo "route has no src addr hint (missing src)? '${route_parts[@]}'" >&2
		return 1
	fi

	local uplink_idx=$(<"/sys/class/net/$UPLINK_IF/ifindex")
	local local_addr=${route_parts[6]}
	local local_mac=$(<"/sys/class/net/$UPLINK_IF/address")
	local gw_addr=${route_parts[2]}
	local gw_mac=$(ip -br neigh show "$gw_addr" | awk 'NR==1 {print $3}')

	if [[ -z $gw_mac ]]; then
		echo "no neighbor entry found for gateway address '$gw_addr'" >&2
		return 1
	fi

	echo "$uplink_idx" "$local_addr" "$local_mac" "$gw_addr" "$gw_mac"
}

# Create a veth pair. Copy IP and MAC addresses from the uplink interface so
# we can easily send on the veth interface and redirect from the peer to the
# uplink interface. Replies will just be received on the uplink interface
# itself.
setup_ifaces() {
	local uplink_idx local_addr local_mac gw_addr gw_mac

	read uplink_idx local_addr local_mac gw_addr gw_mac \
		< <(get_fib_info_to_target "$UPLINK_IF" "$TEST_HOST")

	# The veth CLONE_IF is supposed to be a simple clone of the external interface
	# addresses.
	ip link add "$REDIR_IF" type veth peer "$CLONE_IF" addr "$local_mac"
	ethtool -K "$CLONE_IF" rx off tx off >/dev/null

	for iface in "$REDIR_IF" "$CLONE_IF"; do
		# No IPv6 needed.
		ip link set "$iface" addrgenmode none
		ip link set "$iface" up
	done

	ip addr add "${local_addr}/32" dev "$CLONE_IF"
	ip neigh add "$gw_addr" dev "$CLONE_IF" lladdr "$gw_mac"

	mkdir -p "$BPFFS_DIR"
	$BPFTOOL prog loadall "$BPF_REDIRECT_OBJ" /sys/fs/bpf/redirect/ type xdp
	# Load a program that call bpf_redirect but doesn't actually redirect. This
	# is enough to trigger to issue.
	ip link set "$UPLINK_IF" xdp pinned "$BPFFS_DIR/ingress"
	# Load a program that actually redirects traffic to the bnxt_en interface.
	ip link set "$REDIR_IF" xdp pinned "$BPFFS_DIR/egress"

	# Provision the redirect map.
	__set_redirect $REDIRECT_TARGET_EGRESS "$uplink_idx"

	# Send traffic to the test host on the clone interface so the traffic is
	# triggering some XDP_redirects to the bnxt_en interface.
	ip route replace "$TEST_HOST" via "$gw_addr" dev "$CLONE_IF" onlink
}

# If setup is done, this traffic will be sent out on the clone interface, so
# doing XDP redirects, but the responses will be received on the uplink
# interface directly.
run_curl() {
	for local_port in {32700..32767}; do
		echo "Local Port $local_port:"
		curl \
			--output /dev/null \
			--fail \
			--max-time 5 \
			--no-progress-meter \
			--local-port $local_port \
			"http://$TEST_HOST/$TEST_RESOURCE" && echo works || echo failed
	done
}

build_bpf() (
	pushd bpf
	make --quiet
)

cmd="${1:-}"
shift

case "$cmd" in
cleanup)
	cleanup
	;;
setup)
	build_bpf
	trap cleanup ERR
	setup_ifaces
	;;
run_curl)
	run_curl
	;;
"")
	echo "no command given. (available: cleanup, setup, run_curl)"
	;;
*)
	echo "unknown command: $cmd (available: cleanup, setup, run_curl)"
	;;
esac
