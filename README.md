# Quetzal

A WebSocket server in Zig. It follows the server side of RFC 6455. It has no dependencies.
It needs Zig 0.17.1.

The `quetzal` binary is an echo server. It sends each text or binary message back unchanged.

## Build and run

```
zig build run
```

The server listens on 127.0.0.1:9001. Put a proxy in front of it for `wss`.

## What it does

- Opening handshake, with 400 and 426 replies for bad requests.
- Frame decoding and encoding, masking, and the shortest-length rule.
- Fragmented messages, with ping and pong between fragments.
- Close handshake, with close-code checks.
- UTF-8 checks on text messages and close reasons. A bad fragment fails as soon as it arrives.
- Limits for message size, handshake size, handshake time and idle time.
- A fixed pool of connections. Memory is allocated once, in `Server.init`.

## What it does not do

permessage-deflate, TLS, the client role, subprotocols, extensions, Origin checks, outgoing
fragmentation, streaming messages and broadcast.

## Options

`quetzal.Options` has no defaults. Set every field.

| Field | Meaning |
|---|---|
| `connections_max` | Size of the pool. A new socket is closed at once when the pool is full. |
| `message_size_max` | Largest message. A larger one gets close code 1009. |
| `handshake_size_max` | Largest HTTP request head. A larger one gets 400. |
| `handshake_timeout_ms` | Time allowed for the whole handshake. |
| `idle_timeout_ms` | Longest wait for the next bytes from a client. |

Each connection holds two buffers of about `message_size_max`. The echo server uses 16
connections and 16 MiB, because Autobahn case group 9 sends 16 MiB messages.

A client that sends one byte every `idle_timeout_ms` keeps its slot. Set the timeout with that
in mind.

## Tests

```
zig fmt --check . && zig build lint && zig build test
```

`zig build lint` checks the style rules: lines of at most 100 columns, one-line comments,
functions of at most 70 lines, split assertions, handled errors, and no shell scripts or
dependencies.

The unit tests cover the RFC 6455 examples, invalid frames, the state machine, and an echo over
TCP. Two fuzz tests run their seed inputs in `zig build test`.

## Autobahn

```
zig build autobahn
zig build autobahn -Dquick
```

This starts the echo server and runs the `crossbario/autobahn-testsuite` Docker image against
it. Docker must be able to run with `--network host`. The report goes to `reports/`.
`-Dquick` skips group 9, the large-message cases.

The run covers groups 1 to 7, 9 and 10, 301 cases. Group 12 and 13 need permessage-deflate and
are out of scope. A case passes when it is `OK`, `NON-STRICT` or `INFORMATIONAL`.

| Result | Cases |
|---|---|
| OK | 296 |
| NON-STRICT | 6.4.3, 6.4.4 |
| INFORMATIONAL | 7.1.6, 7.13.1, 7.13.2 |

Cases 6.4.3 and 6.4.4 split one frame into pieces and expect a failure before the frame ends.
The server checks UTF-8 when a frame is complete, so it fails a little later.
