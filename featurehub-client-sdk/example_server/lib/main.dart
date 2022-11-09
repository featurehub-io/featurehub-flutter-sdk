

import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

late FeatureHubConfig featurehub;
late ClientFeatureRepository repository;

final users = Map<String, List<Todo>>();

void configureFeatureHub() {
  final apiKey = Platform.environment['FEATUREHUB_CLIENT_API_KEY'] ?? '53ddb630-62f9-4e81-bf40-13f7aa1acf04/SqyuArvr1iBIicLNLepGokmrGrf1jRJxwfGn4nPp';
  final hostUrl = Platform.environment['FEATUREHUB_EDGE_URL'] ?? 'http://localhost:8064';

  repository = ClientFeatureRepository();

  repository.newFeatureStateAvailableStream.listen((event) {
    repository.availableFeatures.forEach((key) {
      final feature = repository.feature(key);
      // ignore: avoid_print
      print(
          'feature $key is of type ${feature.type} and has the value ${feature.value}');
    });
  });

  featurehub = FeatureHubConfig(hostUrl, [apiKey], repository, timeout: 0);
}

class Todo {
  String id;
  String title;
  bool resolved;

  Todo(this.id, this.title, this.resolved);

  String toJson() {
    String newTitle = processTitle(title);
    final val = {'id': id, 'title': newTitle, 'resolved': resolved};
    // print("encoding ${val}");
    return jsonEncode(val);
  }

  static Todo fromJson(dynamic json) {
    return Todo(json['id'] ?? Random().nextInt(2000).toString(), json['title'] ?? 'none', json['resolved'] ?? false);
  }

  String processTitle(String title) {
    var strFeature = repository.feature('FEATURE_STRING');
    if (strFeature.isSet && title == 'buy') {
      title = "${title} ${strFeature.stringValue}";
      print("string: ${title}");
    }

    var num = repository.feature('FEATURE_NUMBER');
    if (num.isSet && title == 'pay') {
      title = '${title} ${num.numberValue.toString()}';
      print("num: ${title}");
    }

    var jsonFeature = repository.feature('FEATURE_JSON');
    if (jsonFeature.isSet && title == 'find') {
      final json = jsonFeature.jsonValue;
      title = '${title} ${json["foo"]}';
      print("json: ${title}");
    }

    var upperFeature = repository.feature('FEATURE_TITLE_TO_UPPERCASE');
    print("upper feature is enabled ${upperFeature.isEnabled} vs ${upperFeature.value} -> ${title}");
    if (upperFeature.isEnabled) {
      title = title.toUpperCase();
      print("case: ${title}");
    }

    return title;
  }
}

Response listTodos(String user) {
  List<Todo> todos = users[user] ?? [];
  var data = '[';

  repository.clientContext.userKey(user).build();
  featurehub.request();

  data += todos.map((e) => e.toJson()).join(",");

  data = data + ']';

  return Response.ok(data, headers: { 'content-type': 'application/json'}, );
}

void main() async {
  configureFeatureHub();

  final app = Router();

  app.put('/todo/<user>/<id>/resolve', (Request req, String user, String id) {
    final items = users[user] ?? [];
    items.firstWhereOrNull((todo) => todo.id == id)?.resolved = true;
    return listTodos(user);
  });

  app.delete('/todo/<user>/<id>', (Request req, String user, String id) {
    final items = users[user] ?? [];
    items.removeWhere((element) => element.id == id);
    return listTodos(user);
  });

  app.delete('/todo/<user>', (Request req, String user) {
    users[user] = [];
    return listTodos(user);
  });

  app.post('/todo/<user>', (Request req, String user) async {
    final body = await req.readAsString();
    users[user] = (users[user] ?? [])
      ..add(Todo.fromJson(jsonDecode(body)));
    return listTodos(user);
  });

  app.get('/todo/<user>', (Request req, String user) {
    return listTodos(user);
  });

  app.get("/hello", (Request req) {
    return Response.ok("its ok");
  });

  print("listening at http://localhost:8099");
  var server = await io.serve(app, InternetAddress.anyIPv4, 8099);
}
