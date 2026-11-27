# Desktop serial receive latency and worker lifetime

## Two changes

The first fix changes one native reader call from `sp_blocking_read` to
`sp_blocking_read_next`. The former waits for all 255 requested bytes or the
500 ms timeout. The latter waits for some data and immediately returns the bytes
available. It preserves the buffer size, timeout and byte-stream contract.
Production-parser tests cover concatenated notification/MMR/reply frames at every
split position and one byte at a time; no parser rewrite is required.

The second fix moves blocking writes into one persistent worker per connection.
The worker serializes each complete command, including partial writes, bounded
drain polling and existing platform pacing. Admission is bounded to 32 pending
requests and 64 KiB. Each admitted request owns a copy of its bytes and a future;
close rejects new work, finishes accepted work and waits for worker exit. Errors
fail the affected request and any remaining requests when the worker exits.

The reader also needs an observable shutdown barrier. Its worker processes a
stop message between native reads and acknowledges termination through isolate
exit. Pause, resume and cancel serialize startup/shutdown, and `close()` now
returns a future. The native read timeout must be in `1..0xfffffffe` milliseconds.
The constructor rejects zero (an unbounded wait), the reserved Windows value
`0xffffffff`, and larger values before the unsigned native conversion can wrap
them. The default remains 500 ms. Awaiting close guarantees the reader no longer
uses the native handle, including when the stream subscription is paused.

The desktop transport serializes connect/disconnect/dispose. It detaches the
current reader/writer, joins both workers, cancels the subscription, then closes
the native port. It frees the native allocation only during dispose. Callbacks
from an old reader cannot tear down a replacement connection.

Physical testing exposed Linux `close()` blocking while a stalled CDC endpoint
still had unsent output. After the workers finish, shutdown flushes the remaining
output and closes in a separate isolate. This preserves the ownership barrier
without making the UI wait inside a native close. Normal writes retain their
existing bounded drain and pacing; disconnect discards any output still queued
after that policy has finished.

## Scope and integration

The first fix can ship independently. The second depends on the reader's awaited
close API. Both application changes pin exact public commits in
`rheasman/libserialport.dart`, with matching git-source lock entries; no local
path override is required. The library changes are proposed upstream in
[tadelv/libserialport.dart#1](https://github.com/tadelv/libserialport.dart/pull/1)
and [#2](https://github.com/tadelv/libserialport.dart/pull/2). Merge prompt receive
before worker shutdown. After upstream integration, the fork URL can return to
the upstream URL while preserving an exact verified revision.

No BLE/Android serial API, wire protocol, REST endpoint, database, notification
publication policy or shot scheduler changes. Desktop consumers still receive a
stream of bytes and write through the existing `SerialTransport` interface.
macOS/Windows hardware behavior and physical UI frame timing require separate
verification. Linux PTY tests exercise actual native I/O; they do not model all
USB drivers. See `tool/serial_test/README.md` for reproduction.
