#!/bin/bash

set -eEuo pipefail

: ${BPFTOOL:=bpftool}

: ${EXT_IF:=eth0}

# Host to fetch a http resource from. Must be an IPv4 address.
: ${TEST_HOST:=185.12.64.3}
# HTTP resource to fetch. Should not be smaller than 10MB.
: ${TEST_RESOURCE:=ubuntu/packages/pool/main/l/linux-signed/linux-image-6.3.0-7-generic_6.3.0-7.7_arm64.deb}

: ${BPF_INGRESS_PROG:=ingress_by_map}
: ${BPF_EGRESS_PROG:=egress_by_map}

: ${REDIR_IF:=in0}
: ${CLONE_IF:=out0}
: ${BPFFS_DIR:=/sys/fs/bpf/redirect}
: ${BPF_REDIRECT_OBJ:=bpf/redirect.o}
: ${BPF_PASS_OBJ:=bpf/pass.o}

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

__setup_ingress_redirect() {
	local idx=$(<"/sys/class/net/$REDIR_IF/ifindex")
	__set_redirect 0 "$idx"
}

__setup_egress_redirect() {
	local idx=$(<"/sys/class/net/$EXT_IF/ifindex")
	__set_redirect 1 "$idx"
}

__unset_ingress_redirect() {
	__set_redirect 0 0
}

__unset_egress_redirect() {
	__set_redirect 1 0
}

cleanup() {
	ip link set "$EXT_IF" xdp off
	rm -rf "$BPFFS_DIR"
	ip link del "$REDIR_IF" || true
}

get_fib_info_to_target() {
	local ext_if=$1
	local target=$2

	# Parse route to the test host on the external interface.
	local route_parts=($(ip route get "$target" dev "$ext_if"))
	if [[ ${route_parts[1]} != "via" ]]; then
		echo "route not a nexthop route (missing via)? '${route_parts[@]}'" >&2
		return 1
	elif [[ ${route_parts[5]} != "src" ]]; then
		echo "route has no src addr hint (missing src)? '${route_parts[@]}'" >&2
		return 1
	fi

	local local_addr=${route_parts[6]}
	local local_mac=$(<"/sys/class/net/$ext_if/address")
	local gw_addr=${route_parts[2]}
	local gw_mac=$(ip -br neigh show "$gw_addr" | awk 'NR==1 {print $3}')

	if [[ -z $gw_mac ]]; then
		echo "no neighbor entry found for gateway address '$gw_addr'" >&2
		return 1
	fi

	echo "$local_addr" "$local_mac" "$gw_addr" "$gw_mac"
}

send_on_clone() {
	__setup_egress_redirect
	read local_addr local_mac gw_addr gw_mac < <(get_fib_info_to_target "$EXT_IF" "$TEST_HOST")
	ip route replace "$TEST_HOST" via "$gw_addr" dev "$CLONE_IF" onlink
}

send_on_ext() {
	__unset_egress_redirect
	ip route flush dev "$CLONE_IF" >&/dev/null || true
}

receive_on_clone() {
	__setup_ingress_redirect
}

receive_on_ext() {
	__unset_ingress_redirect
}

set_mode() {
	local mode=$1

	case "$mode" in
	redirect_none | n)
		send_on_ext
		receive_on_ext
		;;
	redirect_ingress | i)
		send_on_ext
		receive_on_clone
		;;
	redirect_egress | e)
		send_on_clone
		receive_on_ext
		;;
	redirect_both | b)
		send_on_clone
		receive_on_clone
		;;
	*)
		echo "mode not supported: $mode (available: redirect_[none|ingress|egress|both] | [n|i|e|b]))" >&2
		return 1
		;;
	esac
}

setup_ifaces() {
	local local_addr="$1"
	local local_mac="$2"
	local gw_addr="$3"
	local gw_mac="$4"

	# The veth CLONE_IF is supposed to be a simple clone of the external interface addresses.
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
	ip link set "$EXT_IF" xdp pinned "$BPFFS_DIR/$BPF_INGRESS_PROG"
	ip link set "$REDIR_IF" xdp pinned "$BPFFS_DIR/$BPF_EGRESS_PROG"
	ip link set "$CLONE_IF" xdp obj "$BPF_PASS_OBJ"
}

run_test() {
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

check_setup() {
	if ! $BPFTOOL map show name redirects >&/dev/null; then
		echo "missing redirects map. Did you run setup yet? Maybe try cleanup then setup." >&2
		return 1
	fi
}

build_bpf() (
	pushd bpf
	make
)

cmd="${1:-}"
shift

case "$cmd" in
cleanup)
	cleanup
	;;
reset)
	cleanup
	;&
setup)
	build_bpf
	trap cleanup ERR
	setup_ifaces $(get_fib_info_to_target "$EXT_IF" "$TEST_HOST")
	;;
set_mode)
	check_setup
	set_mode $1
	;;
run)
	check_setup
	run_test
	;;
"")
	echo "no command given. (available: cleanup, setup, set_mode <mode>, run, reset)"
	;;
*)
	echo "unknown command: $cmd (available: cleanup, setup, set_mode <mode>, run, reset)"
	;;
esac
