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
`RawUpdateFeatureListener`. Two stores are available:

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

Read detailed documentation on FeatureHub [here](https://docs.featurehub.io)

Visit Demo FeatureHub Admin Console [here](https://demo.featurehub.io)

https://user-images.githubusercontent.com/9538697/135741127-d813595c-28a4-4d5b-81f2-f754e02d584e.mov


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

fhConfig = FeatureHubConfig(
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
A failed call is caught and a Failure status is sent to the repository, which will have an updated error status
(such as FAILED, in the Readyness listener).

If the request has no data or an api key doesn't exist, that is not considered an error because they may just
not yet be available and you don't want your application to fail.

## Flutter sample app example

There is a full [example](https://github.com/featurehub-io/featurehub-flutter-sdk/blob/main/featurehub-openfeatures-common/example-flutter/lib/main.dart) you can follow that demonstrates how a feature with a key "CONTAINER_COLOUR" of type _string_ can be processed in the Flutter app. The container colour will get updated states based on the feature value, which can be "yellow", "green", "purple" and so on. (See the video clip above)


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

[SSE example](https://github.com/featurehub-io/featurehub-flutter-sdk/blob/main/featurehub-openfeatures-common/example-flutter/lib/main-sse.dart)

## Failure

If for some reason the connection to the FeatureHub server fails - either initially or for some reason during
the process, you will get a readyness event to indicate that it has now failed.

```dart
enum Readyness {
  NotReady = 'NotReady',
  Ready = 'Ready',
  Failed = 'Failed'
}

```
    
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

[Integration test example](https://github.com/featurehub-io/featurehub-flutter-sdk/blob/main/featurehub-openfeatures-common/example_old/test/integration_test.dart) 

## Client-side evaluation

We are not planning on implementing Client Side evaluation for Dart without direct request as it is mostly used client side in Flutter
apps.
