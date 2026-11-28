# Example: the todo-server end-to-end tests

This example uses the provider as an end-to-end test harness. It is a Dart
implementation of FeatureHub's todo-server tests
([`todo-server-tests.yaml`](https://github.com/featurehub-io/featurehub-sdk-docs/blob/main/specs/todo-server-tests.yaml)),
written as standard `package:test` tests.

The tests change features in FeatureHub with `FeatureHubFeatureUpdater`, wait
for each change to reach a `FeatureHubProvider`, then call a todo server's
API and check that the server picked up the change. The todo server can be
written in any language with any FeatureHub SDK, for example this
repository's
[server example](../../featurehub-openfeatures-server-sdk/example/main.dart).

- [`todo_server_test.dart`](todo_server_test.dart): the scenarios.
- [`harness.dart`](harness.dart): the configuration, the feature updates, the
  waits and the todo API client.

## What you need

- A FeatureHub environment with the features `FEATURE_TITLE_TO_UPPERCASE`
  (boolean), `FEATURE_STRING` (string), `FEATURE_NUMBER` (number) and
  `FEATURE_JSON` (JSON). Their values don't matter, because each test sets
  the values it needs.
- A client-evaluated API key for that environment. Its service account needs
  the read, change value, lock and unlock permissions.
- A todo server using the same environment.

## Running

```sh
APP_SERVER_URL=http://localhost:8099 \
FEATUREHUB_EDGE_URL=http://localhost:8085 \
FEATUREHUB_CLIENT_API_KEY='default/<environment id>/<client-evaluated key>' \
dart test example/todo_server_test.dart
```

| Variable | Meaning |
|---|---|
| `APP_SERVER_URL` | The todo server (default `http://localhost:8099`) |
| `FEATUREHUB_EDGE_URL` | FeatureHub Edge (required) |
| `FEATUREHUB_CLIENT_API_KEY` | The API key above (required) |
| `FEATUREHUB_CONNECT_INTERVAL` | Set it (for example to `5s`) when the todo server polls at that interval. The tests then poll too, and wait longer for each change. Unset, they stream |
| `FEATUREHUB_SNAPSHOT_URL` | Optional: the todo server's `GET /features`. The tests then read their features from there rather than from Edge, so each change travels from FeatureHub through the todo server. Changes are still made through Edge |

Add `-t todo-api` to run only the tests that call the todo server. These
check the server and its SDK. Add `-t featurehub-only` to run only the tests
that check this SDK's feature updater and locking against FeatureHub.
