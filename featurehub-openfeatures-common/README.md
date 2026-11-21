[![Build](https://github.com/featurehub-io/featurehub-flutter-sdk/actions/workflows/openfeatures.yml/badge.svg)](https://github.com/featurehub-io/featurehub-flutter-sdk/actions/workflows/openfeatures.yml) [![pub points](https://badges.bar/featurehub_openfeatures_common/pub%20points)](https://pub.dev/packages/featurehub_openfeatures_common/score)


# FeatureHub common libraries for Dart

The common libraries underpinning the FeatureHub OpenFeature providers for Dart:

- [`featurehub_openfeatures_server_sdk`](../featurehub-openfeatures-server-sdk):
  servers and command line applications
- [`featurehub_openfeatures_client_sdk`](../featurehub-openfeatures-client-sdk):
  Flutter (Android, iOS) and browser applications

Applications should normally use one of those providers. This package holds
what they share:

- the feature repository, which holds features and their states and raises
  events when they change;
- rollout strategy evaluation for **client-evaluated API keys** (containing
  `*`), a port of the TypeScript SDK's evaluation checked against it
  (`ClientFeatureRepository.evaluate`, `ApplyFeature`): percentage rollouts
  use the same murmur3 hashing, so a user lands in the same bucket on every
  FeatureHub platform;
- the polling and SSE transports (`FeatureHubConnection`); SSE uses
  [`featurehub_sse_client`](https://pub.dev/packages/featurehub_sse_client)
  on `dart:io` and the native `EventSource` in browsers;
- OpenFeature context mapping and resolution rules shared by both providers;
- raw feature updates and the `FeatureStore` interface, for stores that keep
  a copy of the features (see below).

The FeatureHub API it was built from (the previous `featurehub_client_sdk`)
is still available and is documented below.

## Feature stores

`ClientFeatureRepository.rawFeatureUpdates` publishes every feature change
as it arrives, before catch and release handling, with its source: a
`FeaturesReceived`, `FeatureReceived` or `FeatureDeleted`. A `FeatureStore`
uses it to keep a copy of the features. The providers attach their `stores`
before connecting to FeatureHub; a store loads what it holds into the
repository with `notify(..., source: ...)` and ignores updates from its own
source. This is the Dart equivalent of the TypeScript SDK's
`RawUpdateFeatureListener`.

Without a FeatureHub connection, `FeatureStoreTarget.host` and `apiKey`
are null. If the features come from your own server, `featuresUrl` is set
instead. These stores are available:

- [`featurehub_openfeatures_store_localstorage`](../featurehub-openfeatures-store-localstorage):
  browser storage, for the client provider in web applications;
- [`featurehub_openfeatures_store_redis`](../featurehub-openfeatures-store-redis):
  Redis, shared between server processes and with other FeatureHub SDKs.

## Value interceptors

A `ValueInterceptor` supplies feature values in place of FeatureHub's, for
example local overrides during development. Its `matched(key, featureState)`
is given the feature as FeatureHub delivered it, so it can return a value of
the feature's type (a bool, num or String, JSON as a string). Register one
with `repository.addValueInterceptor(...)`, or give it to a provider's
`interceptors`; the first registered interceptor that matches supplies the
value, overriding locked features unless `allowLockOverride: false`.
[`featurehub_openfeatures_yaml_interceptor`](../featurehub-openfeatures-yaml-interceptor)
reads overrides from a local YAML file.

## Client-evaluated API keys

With a client-evaluated key, FeatureHub sends each feature's rollout
strategies, and they are applied locally: for the repository's
`clientContext` when reading features through `ClientFeatureRepository`, or
for any context with `evaluate`:

```dart
final result = repository.evaluate(
  'colour',
  context: MapStrategyContext({'userkey': 'user-1', 'country': 'new_zealand'}),
);
print('${result.value} (strategy ${result.strategyId})');
```

The context is then never sent to FeatureHub, and a context change needs no
new request. Client-evaluated keys expose every strategy, so use them only in
trusted environments such as servers.

With a server-evaluated key, FeatureHub evaluates the features for one
context, so a connection serves **a single user** and cannot be shared
between users. Server-evaluated keys are intended for apps, browsers and
batch processes. Where context switching is required, such as a server
handling requests for different users, you must use a client-evaluated key.

## Serving features from your own server

A server can pass its features on to its own clients, for example a web
application whose API gives the browser its features rather than the browser
connecting to FeatureHub. On the server, `featureSnapshot` gives the
features and their SHA (`repository.featuresSha`):

```dart
// in a request handler, with a client-evaluated key
final snapshot = repository.featureSnapshot(
  context: {'targetingKey': userId, 'country': 'nz'},
);
return Response.ok(jsonEncode(snapshot), headers: {'content-type': 'application/json'});
```

With a context (an OpenFeature evaluation context, as a map), each feature is
evaluated for it as FeatureHub does for a server-evaluated key: the features
have that context's values, no strategies, and `v` the id of the strategy
that matched. The client only ever sees its own values. Without a context
(none, or an empty one) your code chooses with `includeStrategies`: by
default the features are evaluated as for an empty context; with
`includeStrategies: true` they are given as they are, strategies included,
for clients that evaluate them locally, so only do that for trusted clients.
Value interceptors are not applied.

Each API key can give different features, so a server may serve its clients
features from one key and use another for its own flags: one connection (or
provider) per key, each with its own repository. The server SDK's README
shows how, under "Several connections, with different API keys".

On the client, give the provider a `featuresUrl` instead of a host and API
key. A `FeatureHubConnection` with one (and no API key) uses the
`FeatureSnapshotTransport`, which polls actively or passively through a
`FeatureSnapshotClient`. It sends the context as query
parameters and the last `ETag` as `If-None-Match`, and loads each snapshot
as a full set of features.

To load a snapshot yourself, for example in a transport of your own (see
`transportFactory`), `repository.loadFeatureSnapshot` takes what the server
returned: the snapshot, its JSON as a map or a string, or just a list of
features. It loads them as a full set, and `repository.featuresSha` then
identifies them (for example as an `ETag`).

```dart
final response = await http.get(Uri.parse('https://my.app/api/features'));
repository.loadFeatureSnapshot(response.body);
```

Read detailed documentation on FeatureHub [here](https://docs.featurehub.io)

Visit Demo FeatureHub Admin Console [here](https://demo.featurehub.io)

https://user-images.githubusercontent.com/9538697/135741127-d813595c-28a4-4d5b-81f2-f754e02d584e.mov


## Headers and proxies

Every provider and `FeatureHubConnection` takes:

- `headers`, sent with every request: FeatureHub polling, FeatureHub
  streaming, and your own server's features API. Use them for an API gateway,
  extra authentication, or tracing. In browsers, streaming uses the native
  `EventSource`, which cannot send headers, so use polling (or your own
  transport) if they must be sent.
- `dio`, the `Dio` that makes the polling requests;
- `httpClient`, the `http.Client` that makes the streaming connections
  (`dart:io` only).

Give your own clients to go through a proxy. On `dart:io`, for example:

```dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/io_client.dart';

HttpClient proxied() => HttpClient()
  ..findProxy = ((uri) => 'PROXY proxy.example.com:3128')
  ..addProxyCredentials(
    'proxy.example.com',
    3128,
    'corp',
    HttpClientBasicCredentials('user', 'secret'),
  );

FeatureHubProvider(
  host: 'https://edge.example.com',
  apiKey: apiKey,
  headers: {'x-gateway-key': 'abc123'},
  dio: Dio()
    ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: proxied),
  httpClient: IOClient(proxied()),
);
```

Proxy credentials belong on the `HttpClient`, as above, because headers go
to the server rather than to the proxy. `connectTimeout` only applies to
clients the SDK creates, so set it on your own clients if you need it.

## Transports

A `FeatureHubConnection` fills its repository through one of three built-in
transports, chosen by what it is given (or through your own; see below):

| Given | Transport | Modes |
|---|---|---|
| a `host` and an `apiKey` | `FeatureHubSseTransport`, streaming from FeatureHub Edge | `streaming` |
| a `host` and an `apiKey` | `FeatureHubPollingTransport`, polling FeatureHub Edge through a `FeatureHubRestClient` | `activePolling`, `passivePolling` |
| a `featuresUrl`, and no `apiKey` | `FeatureSnapshotTransport`, polling your own server through a `FeatureSnapshotClient` | `activePolling`, `passivePolling` |

`activePolling` polls every `pollInterval`; `passivePolling` fetches only
when a flag is read and the features are older than `pollInterval`. Both
polling transports share their scheduling (`PollingTransport`). A
`pollInterval` of 0 polls once, at start-up, and never again (a context
change still fetches); any other interval must be at least 5 seconds, and a
FeatureHub `Cache-Control: max-age` (read only from a `200` or `236`) below
that is raised to it. `validatePollInterval` checks an interval.

## Writing your own transport

The SDK specifications are in
[featurehub-sdk-docs](https://github.com/featurehub-io/featurehub-sdk-docs/tree/1.0-initial-log) (tag `1.0-initial-log`).
[`featurehub-protocol.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/1.0-initial-log/specs/featurehub-protocol.yaml)
is a machine-readable specification of the FeatureHub protocol as the SDKs
use it: the feature encoding and SHA, polling scheduling, the repository,
the transport contract, provider wiring and FeatureHub Edge's polling and
streaming, with test vectors, for implementing them in other languages.
[`feature-snapshot-protocol.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/1.0-initial-log/specs/feature-snapshot-protocol.yaml)
specifies the separate snapshot protocol, built on it: your own server
re-serving features to its clients, and the snapshot client.
[`openfeature-resolution.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/1.0-initial-log/specs/openfeature-resolution.yaml)
specifies how the providers resolve a flag, so other-language providers give
the same results: the order of checks, type conversion, reasons, variants,
error codes and flag metadata.
[`feature-store.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/1.0-initial-log/specs/feature-store.yaml) specifies feature stores:
the store contract, how store features are treated, the local storage, Redis
and YAML formats (shared with the other SDKs), and how stores pair with
value interceptors.
[`rollout-strategies.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/1.0-initial-log/specs/rollout-strategies.yaml) specifies
rollout strategy evaluation (percentage rollouts and every matcher), with the
golden fixture generated from the TypeScript SDK as its conformance suite.
NUMBER attributes are the one deliberate difference: a number in the context or
a strategy must be exactly an integer or a decimal (`12`, `-5`, `2.5`), so
`"12abc"`, `"1e3"` and `"0x10"` are not numbers and never match, where the
TypeScript SDK reads them as 12, 1000 and 0.

A transport is what fetches the features: the built-in ones stream or poll
FeatureHub, or poll your own server. To use something else, such as
WebSockets, another SSE client or a message queue, write a
`FeatureHubTransport` and give the provider (or `FeatureHubConnection`) a
`transportFactory`. It is called with a `FeatureHubTransportTarget`, which
holds:

- the `repository` to fill;
- the settings the provider was given: `host`, `apiKey`, `featuresUrl`,
  `mode`, `pollInterval`, `headers`, `reconnectPolicy`, the timeouts, and any
  `dio` and `httpClient`;
- `sendsContext`, and the context to fetch for, as `contextAttributes`
  (`{'userkey': ['fred'], ...}`) or `contextHeader` (FeatureHub's
  `x-featurehub` form).

A transport implements four methods:

| Method | What it must do |
|---|---|
| `start()` | Start fetching. Initialization waits, up to `waitForReady`, for the first full set of features. |
| `contextChanged()` | If `sendsContext`, fetch the features for the new context and notify them as a full set; the provider waits for that. Otherwise do nothing. |
| `refreshIfStale()` | Passive mode: fetch if the features are older than `pollInterval`. Called as flags are resolved. Otherwise do nothing. |
| `close()` | Stop, and release any connections. |

It gives what it receives to the repository with `notify`:

| Call | When |
|---|---|
| `notify(SSEResultState.features, features)` | The full set of features (a `List<FeatureState>`, or their JSON). The first makes the provider ready; features missing from a later set are removed. Anything that is not a list is ignored (logged), changing nothing; a feature without an id, key, version or type is skipped, and counts as not in the set. |
| `notify(SSEResultState.feature, feature)` | One feature added or updated (an invalid one is skipped). |
| `notify(SSEResultState.deleteFeature, feature)` | One feature deleted: only its `key` is needed. |
| `notify(SSEResultState.bye, null)` | The connection was lost and is being re-established. The repository's readiness does not change and the provider reports nothing (not `stale`); features arrive again on reconnection. |
| `notify(SSEResultState.failure, null)` | The connection has failed for good (for example an invalid key). Stop trying. The repository's `connectionFailed` becomes true. Before any features readiness is `Failed` and the provider fails to initialize; after them readiness is `Stale`, and the provider reports `stale` for good and keeps resolving from the last features. |

FeatureHub's event stream sends exactly these, as event names (`features`,
`feature`, `delete_feature`, `bye`, `failure`) with JSON data, so a
transport relaying them can pass each one on with
`notify(SSEResultStateExtension.fromJson(name), jsonDecode(data))` (or
`decodeFeatureHubEventData(data)`). A `config` event whose data has an
`edge.stale` key, whatever its value (`featureHubConfigIsStale(data)`), means
the environment will not change again: call `markEnvironmentStale()` and
stop. Other `config` events are ignored. `FeatureSnapshot.from` reads the snapshots your own
server serves.

A WebSocket transport, whose server sends `{"event": ..., "data": ...}`
messages and is sent the context when it changes, looks like this (it is
also a test, in `test/openfeature/custom_transport_test.dart`):

```dart
class WebSocketTransport implements FeatureHubTransport {
  final FeatureHubTransportTarget target;
  WebSocket? _socket;

  WebSocketTransport(this.target);

  @override
  Future<void> start() async {
    final socket = await WebSocket.connect(
      target.featuresUrl!,
      headers: target.headers,
    );
    _socket = socket;
    socket.listen(
      (message) {
        final json = jsonDecode(message as String) as Map<String, dynamic>;
        target.repository.notify(
          SSEResultStateExtension.fromJson(json['event']),
          json['data'],
        );
      },
      onDone: () => target.repository.notify(SSEResultState.bye, null),
    );
    _sendContext();
  }

  void _sendContext() =>
      _socket?.add(jsonEncode({'context': target.contextAttributes}));

  @override
  Future<void> contextChanged() async => _sendContext();

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => _socket?.close();
}

FeatureHubProvider(
  featuresUrl: 'wss://my.app/features',
  transportFactory: WebSocketTransport.new,
);
```

Whether the context is sent depends on the API key. With a client-evaluated
key it never is, and the strategies are evaluated locally. With a
server-evaluated key it always is. Without a key (only a `featuresUrl`, or
nothing), `sendContext` decides: it defaults to true for the client provider
and false for the server provider. A production transport would also
reconnect after a lost connection, for example using `reconnectPolicy`.

## Getting started

Add dependency:

```yaml
dependencies:
  featurehub_openfeatures_common: ^1.3.0 #latest version
```

Add import package:
```dart
import 'package:featurehub_openfeatures_common/featurehub.dart';
```

Follow these 3 steps to connecting to FeatureHub:

### 1. Locate your API Key 
Find and copy your _Server evaluated API Key_ from the FeatureHub Admin Console on the API Keys page -
you will use this in your code to configure feature updates for your environments.
It should look similar to this: ```default/806d0fe8-2842-4d17-9e1f-1c33eedc5f31/tnZHPUIKV9GPM4u0koKPk1yZ3aqZgKNI7b6CT76q```.
Note: This SDK only accepts _Server evaluated API key_ which is designed for insecure clients, e.g. Browser or Mobile. This also means you evaluate one user per client. More on this [here](https://docs.featurehub.io/#_client_and_server_api_keys)

### 2. Connect to the FeatureHub server:

Create FeatureHub Repository that holds feature states by providing your FeatureHub server url and API Key from the previous step:

```dart
repository = ClientFeatureRepository();

fhConfig = FeatureHubRestClient(
'http://localhost:8903',
[
'default/806d0fe8-2842-4d17-9e1f-1c33eedc5f31/tnZHPUIKV9GPM4u0koKPk1yZ3aqZgKNI7b6CT76q'
],
repository!);
```

### 3. Get features state from your code:

```dart
class Sample extends StatelessWidget {
  const Sample({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
            appBar: AppBar(
              title: Text('My app'),
            ),
            body: StreamBuilder<FeatureStateHolder>(
                    stream: repository!
                            .feature('CONTAINER_COLOUR_FEATURE')
                            .featureUpdateStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return SizedBox.shrink();
                      return Container(
                              color: snapshot.data?.booleanValue == true
                                      ? Colors.red
                                      : Colors.green,
                              child: Text('Hello world!'));
                    }));
  }
}
```


### 4. Make the call to get latest feature states from the FeatureHub server: 

```dart
fhConfig!.request();
```

`request` is an async method and it will return its content directly to the Repository.
A rejection (a 4xx) is sent to the repository as a failure, which sets `connectionFailed` (and readiness `Failed`
before any features, `Stale` after them).

If the request has no data or an api key doesn't exist, that is not considered an error because they may just
not yet be available and you don't want your application to fail.

## Feature state methods

* Get a raw feature value through "Get" methods
    - `getFlag('FEATURE_KEY')` returns a boolean feature value or _null_ if the feature does not exist
    - `getNumber('FEATURE_KEY')` | `getString('FEATURE_KEY')` | `getJson('FEATURE_KEY')` returns the value of the feature or _null_ if the feature value is empty or does not exist
    - `exists('FEATURE_KEY')` returns _true_ if feature key exists, otherwise _false_
    - `feature('FEATURE_KEY')` | `getFeatureState('FEATURE_KEY')` returns `FeatureStateHolder` if feature key exists or _null_ if the feature value is not set or does not exist





## Advanced usage with Rollout Strategies

FeatureHub supports _server side_ evaluation of complex rollout strategies
that are applied to individual feature values in a specific environment. This includes support of preset rules, e.g. per **_user key_**, **_country_**, **_device type_**, **_platform type_** as well as **_percentage splits_** rules and custom rules that you can create according to your application needs.

For more details on rollout strategies, targeting rules and feature experiments see the [core documentation](https://docs.featurehub.io/#_rollout_strategies_and_targeting_rules).



#### Coding for Rollout strategies
There are several preset strategies rules we track specifically: `user key`, `country`, `device` and `platform`. However, if those do not satisfy your requirements you also have an ability to attach a custom rule. Custom rules can be created as following types: `string`, `number`, `boolean`, `date`, `date-time`, `semantic-version`, `ip-address`

FeatureHub SDK will match your users according to those rules, so you need to provide attributes to match on in the SDK:

**Sending preset attributes:**

Provide the following attribute to support `userKey` rule:

```dart
    repository.clientContext.userKey('ideally-unique-id').build(); 
```

to support `country` rule:

```dart
    repository.clientContext.country(StrategyAttributeCountryName.NewZealand).build(); 
```

to support `device` rule:

```dart
    repository.clientContext.device(StrategyAttributeDeviceName.Browser).build(); 
```

to support `platform` rule:

```dart
    repository.clientContext.platform(StrategyAttributePlatformName.Android).build(); 
```

to support `semantic-version` rule:

```dart
    repository.clientContext.version('1.2.0').build(); 
```

or if you are using multiple rules, you can combine attributes as follows:

```dart
    repository.clientContext.userKey('ideally-unique-id')
      .country(StrategyAttributeCountryName.NewZealand)
      .device(StrategyAttributeDeviceName.Browser)
      .platform(StrategyAttributePlatformName.Android)
      .version('1.2.0')
      .build(); 
```

**Sending custom attributes:**

To add a custom key/value pair, use `attr(key, value)`

```dart
    repository.clientContext.attr('first-language', 'russian').build();
```

Or with array of values (only applicable to custom rules):

```dart
   repository.clientContext.attrs('languages', ['russian', 'english', 'german']).build();
```

You can also use `repository.clientContext.clear()` to empty your context.

In all cases, you need to call `build()` followed by `featurehubApi!.request()` to re-trigger passing of the new attributes to the server for recalculation.


**Coding for percentage splits:**
For percentage rollout you are only required to provide the `userKey` or `sessionKey`.

```dart
    repository.clientContext.userKey('ideally-unique-id').build();
```
or

```dart
    repository.clientContext.sessionKey('session-id').build();
```

For more details on percentage splits and feature experiments see [Percentage Split Rule](https://docs.featurehub.io/#_percentage_split_rule).

## Updating features via SSE (server-sent events)

In the examples above the mechanism to retrieve feature states from the FeatureHub server is based on the `GET` request. However, there is also an option to update the FeatureHub repository using SSE protocol. The advantage of SSE method is that it provides real time updates for features by keeping a link open to the FeatureHub
Edge Server. However, as you can imagine this is an expensive operation to do on a battery and we do not recommend it
for Mobile except for short periods. Please consider carefully if you decide to use this method.

Because these two update methods are interchangeable, you can include them in the same application. You
could swap between *GET* when your app swaps to the background and *EventSource* when your app swaps to the foreground 
if immediate updates are important.

## Failure

The repository's readiness says whether it holds features, and whether they are current:

```dart
enum Readyness {
  NotReady, // no features are held
  Ready,    // features are held and are current
  Stale,    // features are held and keep being resolved, but may not be current
  Failed,   // final: the connection failed before any features were received
}
```

Readiness is `Stale` while a context change is in progress (server-evaluated keys: until the new context's
features arrive), and for good once the source has stopped: the connection failed after features
(`connectionFailed`, `connectionFailedStream`) or the environment went stale (`environmentStale`,
`environmentStaleStream`). A full set of features makes it `Ready` again, unless the source has stopped. Readiness
never goes straight from `Ready` to `NotReady` (`shutdownFeatures` goes `Ready`, `Stale`, `NotReady`), and nothing
makes it `Failed` once features have arrived. A lost connection being re-established (a `bye`) changes nothing.
    
## FeatureHub Test API

The FeatureHub Test API is available in this SDK, but it is not broken out into a separate class. The purpose of the
test API is to allow you to update features primarily when writing automated integration tests. 

We provide a method to do this
using the `FeatureServiceApi.setFeatureState` method. Use of the API is based on the rights of your API Key. 
Generally you should only give write access to service accounts in test environments.

When specifying the key, the Edge service will get the latest value of the feature and compare your changes against
it, compare them to your permissions and act accordingly.  

You need to pass in an instance of a FeatureStateUpdate, which takes three values, all of which are optional:

- `lock` - boolean type. If true it will attempt to lock, false - attempts to unlock. No value will not make any change.
- `value` - this is `dynamic` kind of value and is passed when you wish to _set_ a value. Do not pass it if you wish to unset the value.
For a flag this means setting it to false (if null), but for the others it will make it null (not passing it). 
- `updateValue` - set this to true if you wish to make the value field null. Otherwise, there is no way to distinguish
between not setting a value, and setting it to null.

We don't provide a wrapper class for this because most of the code comes directly from the `featurehub_client_api` and
you need to include that and its dependencies in your project to use this capability.

Sample code might look like this:

```dart
final _api = FeatureServiceApiDelegate(ApiClient(basePath: hostURL));
_api.setFeatureState(apiKey, featureKey, FeatureStateUpdate()..lock = false ..value = 'TEST'); 
```   

## Client-side evaluation

We are not planning on implementing Client Side evaluation for Dart without direct request as it is mostly used client side in Flutter
apps.
