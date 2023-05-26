

import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:logging/logging.dart';

_logging() {
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.object != null) {
      // ignore: avoid_print
      print('exception:${record.object}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('stackTrace:${record.stackTrace}');
    }
  });
}

late FeatureHub featurehub;
final users = Map<String, List<Todo>>();

void configureFeatureHub() {
  final apiKey = Platform.environment['FEATUREHUB_SERVER_API_KEY'];
  final hostUrl = Platform.environment['FEATUREHUB_EDGE_URL'];

  if (apiKey == null || hostUrl == null) {
    // ignore: avoid_print
    print('Please set the FEATUREHUB_SERVER_API_KEY and FEATUREHUB_EDGE_URL values.');
    exit(-1);
  }

  featurehub = FeatureHubConfig(hostUrl, [apiKey]).timeout(5);

  if (Platform.environment['STREAMING'] != null) {
    featurehub = featurehub.streaming();
  }

  final repo = featurehub.repository;

  repo.newFeatureStateAvailableStream.listen((event) {
    repo.availableFeatures.forEach((key) {
      final feature = repo.feature(key);
      // ignore: avoid_print
      print(
          'feature $key is of type ${feature.type} and has the value ${feature.value}');
    });
  });
}

class Todo {
  String id;
  String title;
  bool resolved;

  Todo(this.id, this.title, this.resolved);

  String toJson(ClientContext ctx) {
    String newTitle = processTitle(title, ctx);
    final val = {'id': id, 'title': newTitle, 'resolved': resolved};
    return jsonEncode(val);
  }

  static Todo fromJson(dynamic json) {
    return Todo(json['id'] ?? Random().nextInt(2000).toString(), json['title'] ?? 'none', json['resolved'] ?? false);
  }

  String processTitle(String title, ClientContext ctx) {
    var strFeature = ctx.feature('FEATURE_STRING');
    if (strFeature.set && title == 'buy') {
      title = "${title} ${strFeature.string}";
      print("string: ${title}");
    }

    var num = ctx.feature('FEATURE_NUMBER');
    if (num.set && title == 'pay') {
      title = '${title} ${num.number.toString()}';
      print("num: ${title}");
    }

    var jsonFeature = ctx.feature('FEATURE_JSON');
    if (jsonFeature.set && title == 'find') {
      final json = jsonFeature.json;
      title = '${title} ${json["foo"]}';
      print("json: ${title}");
    }

    var upperFeature = ctx.feature('FEATURE_TITLE_TO_UPPERCASE');
    print("upper feature is enabled ${upperFeature.enabled} vs ${upperFeature.value} -> ${title}");
    if (upperFeature.enabled) {
      title = title.toUpperCase();
      print("case: ${title}");
    }

    return title;
  }
}

Response listTodos(String user, ClientContext ctx) {
  List<Todo> todos = users[user] ?? [];
  var data = '[';

  data += todos.map((e) => e.toJson(ctx)).join(",");

  data = data + ']';

  return Response.ok(data, headers: { 'content-type': 'application/json'}, );
}

void main() async {
  _logging();

  configureFeatureHub();

  final app = Router();

  Future<ClientContext> _ctx(String user) async =>
    await featurehub.newContext().userKey(user).build();

  app.put('/todo/<user>/<id>/resolve', (Request req, String user, String id) async {
    final items = users[user] ?? [];
    items.firstWhereOrNull((todo) => todo.id == id)?.resolved = true;
    return listTodos(user, await _ctx(user));
  });

  app.delete('/todo/<user>/<id>', (Request req, String user, String id) async {
    final items = users[user] ?? [];
    items.removeWhere((element) => element.id == id);
    return listTodos(user, await _ctx(user));
  });

  app.delete('/todo/<user>', (Request req, String user) async {
    users[user] = [];
    return listTodos(user, await _ctx(user));
  });

  app.post('/todo/<user>', (Request req, String user) async {
    final body = await req.readAsString();
    users[user] = (users[user] ?? [])
      ..add(Todo.fromJson(jsonDecode(body)));
    return listTodos(user, await _ctx(user));
  });

  app.get('/todo/<user>', (Request req, String user) async {
    return listTodos(user, await _ctx(user));
  });

  app.get("/health/liveness", (Request req) {
    if (featurehub.repository.readiness == Readiness.Ready) {
      return Response.ok("its ok");
    }

    return Response.internalServerError(body: "repository not ready");
  });

  print("listening at http://localhost:8099");
  await io.serve(app, InternetAddress.anyIPv4, 8099);
}
