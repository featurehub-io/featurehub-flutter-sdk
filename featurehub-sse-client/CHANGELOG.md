# Changelog
* 1.5.0
- requires Dart SDK 3.12.2 or later, to match the FeatureHub OpenFeature packages
- `EventSource.connect` takes an optional `connectTimeout` (for the client it creates when none is supplied;
  `dart:io` only) and `requestTimeout` (how long each connection attempt waits for the server to respond). An attempt
  that times out is a network error (status `0`), retried under the reconnect policy; the initial `connect` throws
* 1.4.0
- requires Dart SDK 3.10 or later; upgraded dependencies (http ^1.5.0, collection, http_parser, logging)
- removed use of http's private `encodingForCharset`, which newer http versions no longer provide
- `EventSourceReadyState` values renamed to `connecting`, `open`, `closed`; the uppercase names remain as deprecated aliases
- ready state changes are now logged via `logging` instead of `print`
- adopted `package:lints` recommended rules and fixed all analyzer issues
- event stream parsing now follows the WHATWG SSE specification:
  - the last event ID persists across events until the server sends a new `id` field, so `Last-Event-ID` is sent
    correctly on reconnection (previously any event without an `id`, or a heartbeat comment, cleared it)
  - every event's `id` is the current last event ID (`""` if none), rather than `null` when the block had no `id` field
  - blocks with no `data` field (e.g. heartbeat comments, id-only blocks) are no longer dispatched as empty events
  - events without an `event` field have the type `"message"` rather than `null`
  - invalid `retry` values are ignored rather than throwing, and `id` values containing NULL are ignored
  - malformed UTF-8 is replaced rather than throwing, and a leading BOM is ignored
  - the decoded stream now propagates errors and completion
- new `EventSource.lastEventId` getter
- the client is now responsible for reconnecting, configured with a new `ReconnectPolicy` (`reconnectPolicy:` on
  `EventSource.connect`):
  - reconnects when the server closes the stream, on network/stream errors, and on retryable statuses
  - by default stops on non-retryable statuses (1xx-4xx) and retries 5xx using a separate `serverErrorDelay`
  - configurable `delay`, `serverErrorDelay`, `maxAttempts` (consecutive, reset on a successful connection),
    `backoffMultiplier`, `maxDelay`, `honourServerRetry` and `shouldRetryStatus`; `ReconnectPolicy.none` disables it
  - defaults: 3s delay (or the server's `retry:` value), 30s after a 5xx, unlimited attempts, no backoff
    (previously the delay doubled on every failed attempt, forever)
  - each scheduled reconnection is delivered to listeners as an `EventSourceReconnect` event (type `"reconnect"`),
    also available as `EventSource.onReconnect`
  - when the policy gives up, the final `EventSourceSubscriptionException` is added to the stream as an error and the
    ready state becomes `closed`; the ready state is now `connecting` (not `closed`) while waiting to reconnect
- new `EventSource.close()`, which also cancels a pending reconnection
- `EventSourceSubscriptionException.statusCode` is now the real HTTP status (non-200 responses were previously reported
  as `500`), and `0` when no HTTP response was received (network errors, dropped connections); see `isHttpError`
- the ready state controller no longer receives the same state twice in a row
- if the first connection is made by a listener (`openOnlyOnFirstListener`), failures follow the reconnect policy
  rather than raising an unhandled error; `connect()` and `reopen()` still throw if their connection attempt fails
* 1.3.3 
- bumped http package from ^0.13.0 to ^1.1.0 and SDK version to < 3.9.9
 - upgrades for major functionality in 1.5.9
* 1.3.2 - print statement leakages
* 1.3.1 - bug fix around the closing of the connection and support for notification of status of event stream, and reopening 
* 1.3.0 - repository url change and formatting updates 
* 1.2.0 - null save version
* 1.0.0 - this is the fork and re-release of the eventsource package
