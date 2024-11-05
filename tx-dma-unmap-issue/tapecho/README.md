# tapecho

Simple tap device echoing any packet received. Intended for XDP debugging
purposes only!

## Build

Requires liburing. On Ubuntu, install `liburing-dev`. Then build:

```
$ make
```

## Run

Running the command creates/opens a tap device with the name `tapecho`. Any
packet sent to it is echoed back as is.

```
# ./tapecho
```

Terminate by `SIGINT` (`CTRL+C`).

