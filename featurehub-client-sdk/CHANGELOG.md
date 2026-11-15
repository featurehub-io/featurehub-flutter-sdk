1.5.0
=====
* Requires Dart 3.10 or later; upgraded to dio 5, openapi_dart_common 5, rxdart 0.28 and the 1.4.0
  featurehub_sse_client
* Reconnection is now handled by featurehub_sse_client rather than by the SDK (dart:io only; browsers use the
  native EventSource, which already reconnects). `EventSourceRepositoryListener` takes an optional
  `reconnectPolicy` to configure it. By default the connection is retried after 3s when lost, after 30s on a
  5xx, and stops on a 4xx.
  * while reconnecting the repository is marked not ready (`bye`)
  * a `failure` event or a stale edge closes the connection
  * if the event source gives up, a 4xx is reported to the repository as `failure`, anything else as `bye`
  * the initial connection is also retried, rather than raising an unhandled error
  * a client context change now drops the connection and reconnects with the new context header (previously
    it attempted to reopen the existing connection with the old header)
* `EventSourceRepositoryListener.closed` is now implemented on dart:io
* `SSEResultState.config` and `SSEResultState.error` are ignored by the repository
* adopted `package:lints` recommended rules and fixed all analyzer issues

1.4.0
=====
* Support for Fastly with GET requests and SSE requests
* Support for server side control of polling intervals
* Support for polling intervals (previous a check always called the server)
* Support for expired environments
* Deprecated jaeger interceptor

1.3.1
=====
* More robust reconnection in the face of disconnection

1.3.0
=====
* Introduce FeatureHubConfig
* Documentation updates
* Examples updates

1.2.0
=====
* null safe version

1.1.4
=====
* documentation updates

1.1.3
=====
* allow the release process for catch & release to turn the catch flag off once released. Ensure turning
  release off also releases caught flags.

1.1.2
=====
* Updated documentation

1.1.1
=====
* Update documentation
* Update for rollout support
* Update for w3c correlation context


1.0.1
=====
* Update to support the GET API and add documentation for the GET and Test APIs.
 
1.0.0
=====
* initial release of API. Dart IO support, with all platform support.
