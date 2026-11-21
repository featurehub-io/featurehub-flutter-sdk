# SSE-Client 

A client only library for using EventSource or Server-Sent Events (SSE). 

This library implements the interface as described [here](https://html.spec.whatwg.org/multipage/comms.html#server-sent-events).

## Origin

This packages is a clone of the `eventsource` library but because we have not been able to get critical changes
merged in, we have had to release this package instead. It drops the incomplete server functionality and we have
renamed the library to `featurehub_sse_client`.

Further, with Dart now supporting target platform detection (when detecting dart.io vs dart.html) it makes more sense
to use the browser specific SSE client (`dart:html / EventSource`) as it is native to the browser.

## Client usage

For more advanced usage, see the `example/` directory. 
Creating a new EventSource client is as easy as a single call.
The http package is used under the hood, so wherever this package works, this library will also work.
Browser usage is slightly different.

```dart
EventSource eventSource = await EventSource.connect("http://example.com/events");
// in browsers, you need to pass a http.BrowserClient:
EventSource eventSource = await EventSource.connect("http://example.com/events", 
    client: http.BrowserClient());
```

If you wish to have it connect only when the first listener attaches (and not otherwise), then pass the
optional parameter `openOnlyOnFirstListener` (as true). If you wish to close it after the last listener detaches, then
pass the optional parameter `closeOnLastListener`.

```dart
EventSource eventSource = await EventSource.connect("http://example.com/events", 
  openOnlyOnFirstListener: true, closeOnLastListener: true);
```

You can also listen for events from the event source now, but you will need to provide your own stream controller. If
you wish to listen to the events as the stream opens and closes, please pass in a `StreamController<>`

## Reconnection

The client reconnects automatically when the server closes the stream, when the connection fails, or when the
server responds with a retryable status. By default it retries 5xx responses (using a longer delay) and stops on
any other non-200 status, such as 4xx. This is configured with a `ReconnectPolicy`:

```dart
EventSource eventSource = await EventSource.connect("http://example.com/events",
  reconnectPolicy: ReconnectPolicy(
    delay: Duration(seconds: 3),             // after a dropped connection or network error
    serverErrorDelay: Duration(seconds: 30), // after a 5xx response
    maxAttempts: 10,                         // consecutive attempts; null (the default) retries forever
  ));

eventSource.onReconnect.listen((r) =>
  print("reconnect attempt ${r.attempt} in ${r.delay} (status ${r.statusCode})"));
```

Each scheduled reconnection is also delivered to every listener of the event source as an `EventSourceReconnect`
event (its `event` is `"reconnect"`). A `retry:` field sent by the server replaces `delay`, as the SSE specification
requires, unless `honourServerRetry` is false. `backoffMultiplier` and `maxDelay` add exponential backoff, and
`shouldRetryStatus` changes which statuses are retried. Use `ReconnectPolicy.none` to disable reconnection.

When the policy gives up, the final `EventSourceSubscriptionException` is added to the stream as an error and
`readyState` becomes `closed`. Call `close()` to stop the event source yourself, and `reopen()` to start it again.

The initial `connect()` (and `reopen()`) throws if its connection attempt fails; reconnection applies once connected.

## Timeouts

```dart
EventSource eventSource = await EventSource.connect("http://example.com/events",
  connectTimeout: Duration(seconds: 10), // establishing the connection (dart:io)
  requestTimeout: Duration(seconds: 30)); // waiting for the server to respond
```

`connectTimeout` applies to the client the event source creates when you do not pass your own `client`, and only on
`dart:io`. `requestTimeout` limits how long each connection attempt waits for the server's response (status and
headers); the event stream itself then stays open. An attempt that times out is retried according to the
`reconnectPolicy`. Both default to waiting indefinitely.

## Licensing

This project is available under the MIT license, as can be found in the LICENSE file.
