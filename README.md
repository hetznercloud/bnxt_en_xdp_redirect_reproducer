# bnxt_en XDP redirect issue reproducer

Simple reproducer for an eBPF XDP redirect issue we observe with BroadCom 
NetExtreme NICs (bnxt_en driver).

## The issue

On machines with Broadcom NetExtreme NICs (kernel driver bnxt_en), we observe
strange behavior when using eBPF XDP programs redirecting from and to such a
NIC. With just a bit of traffic some local ports stop working and can not
be used anymore - traffic just stalls for those local ports and keeps doing so.
In order to make traffic work again as expected, a reinitializing of the NIC is 
necessary.

We can only reproduce the issue with XDP_REDIRECT involved. With a XDP program 
attached that just passes traffic there where no issues observed, even when
saturating the link.

The issue was present with 1, 16 or 32 (of 37 possible) queues. Disabling all
offloads did not help. On the remote side packets arrived but the responses did
not reach the local side, so issue appears to be on the receiving side. The
issue is present when using the XDP helper functions `bpf_redirect` as well as
`bpf_redirect_map`.

With the provided reproducer script, the issue can be reproduced by sending
traffic on an veth interface that gets redirected to the bnxt_en NIC and 
response traffic is received without even being redirected on the bnxt_en
interface. Once some stalls happen, no matter how the traffic is sent, the same
tuples stall until the NIC is reinitialized. It appears like some NIC queues
get stuck.

## Hardware

* Broadcom Inc. and subsidiaries BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller

## Kernel versions tested with issue present

* 5.15
* 5.19
* 6.2
* 6.3
* 6.4

## Concept of this reproducer

The eBPF programs are kept very simple in order to have only the problematic
part in it (redirect).

In order to keep the requirements simple and don't need any addresses except
the hosts addresses, we just use a veth pair to redirect our test traffic to the
uplink and back. The test traffic is just a http download. In order to 
keep the ebpf programs simple, we just use the MAC and IP address of the 
external interface on the veth interface as well. The downloads are done with a
series of local ports (32700 - 32767 which are the ports just before the usual
dynamic port range). Outgoing packets are just redirected and incoming packets
that have the destination port from that range are redirected to veth interface.

## How to reproduce

### Software requirements

* clang/llvm for building the bpf programs (tested with clang/llvm 15)
* curl
* bpftool

If the bpftool binary matching the running kernel is not in your PATH, you can
set the BPFTOOL environment variable which is consumed by the script.

The broadcom NIC is assumed to be eth0 but can be set by environment variable 
EXT_IF.

### Execution

In order to avoid our test ports being blocked in time-wait state, set
the time-wait buckets to 0 so no connection ends up in that state and we don't 
have to wait for them before we can test again.

```
sysctl net.ipv4.tcp_max_tw_buckets=0
```

Setup the veth interfaces that are used for redirecting from/to:

```
# bash reproducer.sh setup
```

Set the mode of the script so egress traffic is sent on the veth interface and
redirected to the bnxt_en interface, but response traffic is just passed to the
host directly:

```
# bash reproducer.sh set_mode redirect_egress
```

The issue is visible when running the `run` subcommand of the script and output 
looks like the following example. It prints the port it is using and if the curl
download succeeded it prints "works", so the issue is not present. It prints 
"failed" (usually right after a curl error message) if the curl did not succeed.
This is the issue being visible. If the test is run again, it will stall at the
same ports.

For us, it usually works right on the first run. If it doesn't for you, try a
couple of times until there are failed ports like in the example below.

```
# bash reproducer.sh run
...
Local Port 32732:
works
Local Port 32733:
works
Local Port 32734:
curl: (28) Operation timed out after 5001 milliseconds with 6641722 out of 16560536 bytes received
failed
Local Port 32735:
works
Local Port 32736:
works
Local Port 32737:
works
Local Port 32738:
works
Local Port 32739:
curl: (28) Connection timed out after 5001 milliseconds
failed
Local Port 32740:
works
Local Port 32741:
works
...
```

Once the NIC is in that state, the connections will stall consistenly, even when
the connections are tried directly on the external interface (redirects map is 
empty (this can be set by running `bash reproducer.sh set_mode redirect_none`).

## Usage of reproducer.sh

See the script's head for environment variables consumed by the script.

### setup

The subcommand creates a veth pair so we can redirect from/to interfaces. It 
builds the bpf programs, loads and attaches them but does not provision the 
redirect map, so no redirect happen yet.

### set_mode

There are 4 modes that can be set. They are setting up the redirect map with
the correct (or no) values and add a route on the clone interface if traffic
is to be sent on the interface.

You can do multiple test runs in various modes. The external interface is not
changed, so once a broken state is observed in a mode, you can change the mode
and the issue should be visible in the new mode as well.

#### redirect_none (short: n)

Traffic is just sent out and received on the external interface. This is the
active mode right after `setup` has been executed.

#### redirect_ingress (short: i)

Traffic is sent out on the external interface but replies are redirected and
received on the veth interface.

#### redirect_egress (short: e)

Traffic is sent out on the veth interface but replies received on the external
interface directly.

#### redirect_both (short: b)

Traffic is sent out and received on the veth interface. Redirects happening in
both directions.

### run

Does some traffic by downloading a file using curl from a series of local ports
(32700-32767). This should work without issues repeatedly.

### cleanup

Detach the XDP program from the external interface. Delete the veth interfaces.
Unload the eBPF programs. The detach of the XDP program triggers an init of the
NIC and clears the issue.

### reset

Combines `cleanup` and `setup` in one command.
