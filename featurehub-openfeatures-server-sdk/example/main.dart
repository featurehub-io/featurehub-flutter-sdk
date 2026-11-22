// A todo server using FeatureHub through OpenFeature, with the Shelf
// framework: a Dart version of the FeatureHub Python SDK's example
// (https://github.com/featurehub-io/featurehub-python-sdk/tree/main/example).
//
// Run with:
//
//   FEATUREHUB_EDGE_URL=http://localhost:8085 \
//   FEATUREHUB_CLIENT_API_KEY='default/<environment>/<client-evaluated key>' \
//   dart run example/main.dart
//
// The provider reads its configuration from these variables: use
// FEATUREHUB_SERVER_API_KEY instead for a server-evaluated key, and set
// FEATUREHUB_CONNECT_INTERVAL (a duration, such as 30s) to poll for feature
// updates instead of streaming them (the default), or FEATUREHUB_CONNECT_TYPE
// (active, passive or streaming) to choose the mode. PORT (default 8099) is the server's port.
// The features used are FEATURE_TITLE_TO_UPPERCASE (boolean),
// FEATURE_STRING (string), FEATURE_NUMBER (number) and FEATURE_JSON (JSON
// with a "foo" field), each evaluated for the user in the request.
//
// GET /features serves every feature to the server's own clients (such as a
// browser), evaluated for the context in the query parameters, for example
// /features?targetingKey=fred&country=nz. With no query parameters the
// features are evaluated as for an empty context, unless
// serveStrategiesWithoutContext (below) is set: then they are served as they
// are, rollout strategies included, for clients that evaluate them locally (a
// provider with sendContext: false). That exposes every strategy, so only
// set it for trusted clients. Its ETag is the
// features' SHA, so a client sending it back in If-None-Match gets a 304
// until the features change. A client provider polls it with
// FeatureHubProvider(featuresUrl: '<this server>/features'). It needs a
// client-evaluated key (FEATUREHUB_CLIENT_API_KEY): with a server-evaluated
// one FeatureHub evaluates the features for this server's single context, so
// every client would get those values, and the server refuses to start.
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:logging/logging.dart';
import 'package:openfeature_dart_server_sdk/client.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart'
    show FlagEvaluationDetails;
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';
import 'package:openfeature_dart_server_sdk/provider_lifecycle.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

final _log = Logger('todo-server');

class Todo {
  final String id;
  final String title;
  bool resolved;

  Todo(this.id, this.title, {this.resolved = false});

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'resolved': resolved,
  };

  @override
  String toString() => '$id $title $resolved';
}

/// Each user's todos.
final users = <String, List<Todo>>{};

List<Todo> userTodos(String user) => users.putIfAbsent(user, () => []);

/// FeatureHub features evaluated for one user.
class UserFeatures {
  final FeatureClient _client;
  final EvaluationContext _context;

  UserFeatures(this._client, String user)
    : _context = EvaluationContext(targetingKey: user, attributes: const {});

  /// True if the feature exists and has a value.
  static bool _isSet(FlagEvaluationDetails<Object?> details) =>
      details.errorCode == null && details.reason != 'DISABLED';

  Future<bool> isEnabled(String key) =>
      _client.getBooleanFlag(key, defaultValue: false, context: _context);

  Future<String?> string(String key) async {
    final details = await _client.getStringEvaluationDetails(
      key,
      defaultValue: '',
      context: _context,
    );
    return _isSet(details) ? details.value : null;
  }

  Future<num?> number(String key) async {
    final details = await _client.getDoubleEvaluationDetails(
      key,
      defaultValue: 0,
      context: _context,
    );
    if (!_isSet(details)) return null;
    final value = details.value;
    // FeatureHub numbers are often whole: show 3 rather than 3.0
    return value == value.truncateToDouble() ? value.toInt() : value;
  }

  Future<Map<String, dynamic>?> json(String key) async {
    final details = await _client.getObjectEvaluationDetails(
      key,
      defaultValue: const {},
      context: _context,
    );
    return _isSet(details) ? details.value : null;
  }
}

Future<String> processTitle(UserFeatures features, String title) async {
  var newTitle = title;

  final string = await features.string('FEATURE_STRING');
  if (string != null && title == 'buy') {
    newTitle = '$title $string';
  }

  final number = await features.number('FEATURE_NUMBER');
  if (number != null && title == 'pay') {
    newTitle = '$title $number';
  }

  final json = await features.json('FEATURE_JSON');
  if (json != null && title == 'find') {
    newTitle = '$title ${json['foo']}';
  }

  if (await features.isEnabled('FEATURE_TITLE_TO_UPPERCASE')) {
    newTitle = newTitle.toUpperCase();
  }

  return newTitle;
}

Response jsonResponse(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Future<Response> todoList(
  FeatureClient client,
  String user, {
  int status = 200,
}) async {
  final features = UserFeatures(client, user);
  final todos = [
    for (final todo in userTodos(user))
      Todo(
        todo.id,
        await processTitle(features, todo.title),
        resolved: todo.resolved,
      ).toJson(),
  ];
  return jsonResponse(todos, status: status);
}

/// The OpenFeature evaluation context in [request]'s query parameters:
/// `targetingKey` for the user, and any other attributes. A parameter given
/// more than once is a list.
Map<String, Object?> queryContext(Request request) => {
  for (final MapEntry(:key, :value) in request.url.queryParametersAll.entries)
    key: value.length == 1 ? value.single : value,
};

/// True if the `If-None-Match` header in [request] matches [etag] (a quoted
/// entity tag): it is `*`, or one of its tags, weak (`W/`) or not, is [etag].
bool ifNoneMatch(Request request, String etag) {
  final header = request.headers['if-none-match'];
  if (header == null) return false;
  return header
      .split(',')
      .map((tag) => tag.trim())
      .map((tag) => tag.startsWith('W/') ? tag.substring(2) : tag)
      .any((tag) => tag == '*' || tag == etag);
}

/// Whether `GET /features` with no query parameters serves the features as
/// they are, rollout strategies included (true), or evaluated as for an empty
/// context (false). Your choice: true suits trusted clients that evaluate the
/// features locally (a provider with `sendContext: false`); false never
/// exposes a strategy.
const serveStrategiesWithoutContext = false;

/// Serves the features evaluated for the context in the query parameters.
/// With none, [includeStrategies] decides: the features as they are,
/// strategies included, or evaluated as for an empty context (see
/// [ClientFeatureRepository.featureSnapshot]). Their SHA is the ETag: 304 if
/// the client already has them.
Response features(
  Request request,
  FeatureHubProvider provider, {
  bool includeStrategies = serveStrategiesWithoutContext,
}) {
  final repository = provider.repository;
  if (repository == null) return Response(503);

  // the features evaluated for one context change only when the features do
  // (the SHA is of their ids and versions), and the context is in the URL,
  // so the SHA validates each URL's response
  final etag = '"${repository.featuresSha}"';
  const caching = {'cache-control': 'no-cache'};
  if (ifNoneMatch(request, etag)) {
    return Response.notModified(headers: {'etag': etag, ...caching});
  }

  final FeatureSnapshot snapshot;
  try {
    snapshot = repository.featureSnapshot(
      context: queryContext(request),
      includeStrategies: includeStrategies,
    );
  } on InvalidContextException catch (e) {
    return Response.badRequest(body: e.message);
  }
  return Response.ok(
    jsonEncode(snapshot),
    headers: {'content-type': 'application/json', 'etag': etag, ...caching},
  );
}

Router buildRouter(
  FeatureClient client,
  FeatureHubProvider provider,
  bool Function() ready,
) {
  Future<Response> helloWorld(Request request, String name) async =>
      Response.ok(
        await UserFeatures(client, name).isEnabled('FEATURE_TITLE_TO_UPPERCASE')
            ? 'HELLO WORLD'
            : 'hello world',
      );

  return Router()
    // the Python example has synchronous and asynchronous versions; in Dart
    // they are the same
    ..get('/async-name/<name>', helloWorld)
    ..get('/name/<name>', helloWorld)
    ..get(
      '/foo/<someId>',
      (Request request, String someId) => jsonResponse({'echo': someId}),
    )
    ..put('/todo/<user>/<id>/resolve', (
      Request request,
      String user,
      String id,
    ) async {
      for (final todo in userTodos(user)) {
        if (todo.id == id) {
          todo.resolved = true;
          return todoList(client, user);
        }
      }
      return Response.notFound('');
    })
    ..delete('/todo/<user>/<id>', (
      Request request,
      String user,
      String id,
    ) async {
      final todos = userTodos(user);
      final index = todos.indexWhere((todo) => todo.id == id);
      if (index < 0) return Response.notFound('');
      todos.removeAt(index);
      return todoList(client, user);
    })
    ..delete('/todo/<user>', (Request request, String user) {
      users.remove(user);
      return Response(204);
    })
    ..post('/todo/<user>', (Request request, String user) async {
      final Object? data;
      try {
        data = jsonDecode(await request.readAsString());
      } on FormatException {
        return Response.badRequest();
      }
      if (data is! Map || data['title'] is! String) {
        return Response.badRequest();
      }

      userTodos(user).add(
        Todo(
          '${data['id']}',
          data['title'] as String,
          resolved: data['resolved'] == true,
        ),
      );
      return todoList(client, user, status: 201);
    })
    ..get('/todo/<user>', (Request request, String user) {
      return todoList(client, user);
    })
    ..get('/features', (Request request) => features(request, provider))
    // the process is up and serving requests, whether or not it has features
    ..get('/health/liveness', (Request request) => Response.ok('OK'))
    ..get(
      '/health/readiness',
      (Request request) =>
          ready() ? Response.ok('OK') : Response.internalServerError(),
    );
}

/// Allows requests from any origin, as the Python example's flask_cors does.
Middleware cors() {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': '*',
    // so browser code can read the ETag
    'Access-Control-Expose-Headers': 'ETag',
  };
  return (Handler inner) => (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: headers);
    }
    final response = await inner(request);
    return response.change(headers: headers);
  };
}

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8099;

  // the OpenFeature SDK prints all log records (and sets the root level to
  // ALL) when the API is first created; show INFO and above
  final api = OpenFeatureAPI();
  Logger.root.level = Level.FINE;

  // the provider reads FEATUREHUB_EDGE_URL, FEATUREHUB_CLIENT_API_KEY (or
  // FEATUREHUB_SERVER_API_KEY), FEATUREHUB_CONNECT_TYPE and
  // FEATUREHUB_CONNECT_INTERVAL
  final FeatureHubProvider provider;
  try {
    provider = FeatureHubProvider();
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  // GET /features evaluates the features for each client's context, which
  // needs their strategies: a server-evaluated key delivers features already
  // evaluated for this server's own context, which every client would get
  if (!provider.clientEvaluated) {
    stderr.writeln(
      'This server serves features to its own clients (GET /features), so it '
      'needs a client-evaluated API key (containing *), set in '
      '${FeatureHubProvider.clientApiKeyVariable}; the key given is '
      'server-evaluated.',
    );
    exit(1);
  }

  // ready once the provider has features. PROVIDER_STALE does not change
  // that: the features' source has stopped updating (the environment is
  // stale, or the key was rejected), but this server still works and serves
  // the last features, so it should stay in service
  var ready = false;
  provider.providerEvents.listen((event) {
    if (event.type == ProviderLifecycleEventType.PROVIDER_READY) ready = true;
  });

  _log.info(
    'starting featurehub (${provider.host}, '
    '${provider.pollInterval == null ? 'streaming' : 'polling every ${provider.pollInterval}'})',
  );
  await api.setProviderAndWait(provider);
  final client = api.getClient('todo-server');

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(cors())
      .addHandler(buildRouter(client, provider, () => ready).call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  _log.info('listening on http://${server.address.host}:${server.port}');

  // shut down cleanly on Ctrl-C, or when a container is stopped (SIGTERM)
  await Future.any([
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ]);
  _log.info('shutting down');
  await server.close();
  await OpenFeatureAPI.resetInstance();
  exit(0);
}
