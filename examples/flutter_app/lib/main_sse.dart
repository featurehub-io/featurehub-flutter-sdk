import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_google_analytics_plugin/featurehub_plugin_g4.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

late FeatureHub featurehubApi;
ClientContext? fhContext;
late G4AnalyticsService g4;

void main() {
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  g4 = G4AnalyticsService(measurementId: '', debugMode: true, unnamedBecomeEventParameters: true);

  // Provide host url (Edge FeatureHub server) and server eval api key for an application environment
  featurehubApi = FeatureHubConfig(
      'http://localhost:8085',
      [
        'ddd28309-7a5d-4e5a-b060-3f02ddd9e771/NTd8uaqslH068AhAa5lOR7nOqzQISVciYuVsE6IV'
      ]).streaming();

  featurehubApi.usageAdapter.registerPlugin(g4);

  // featurehubApi.start().then((value) => fhContext = value);

  // Uncomment below if you would like to pass context when using split targeting rules

  featurehubApi.newContext()
      .userKey('susanna')
      .device(StrategyAttributeDeviceName.desktop)
      .platform(StrategyAttributePlatformName.macos)
      .attr('sausage', 'cumberlands')
      .build().then((value) => fhContext = value);

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Streaming Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Streaming Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;

  const MyHomePage({Key? key, required this.title}) : super(key: key);

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    fhContext?.recordAnalyticsEvent(g4.pageView(title: 'exampleapp'));
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (fhContext == null) {
      return const CircularProgressIndicator();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: StreamBuilder<FeatureStateHolder>(
          stream: fhContext!.feature('text_colour').featureUpdateStream,
          builder: (context, snapshot) {
            return ListView(
              children: [
                Container(
                  color: determineColour(snapshot.data),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(
                          'You have pushed the button this many times:',
                        ),
                        Text(
                          '$_counter',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ],
                    ),
                  ),
                )
              ],
            );
          }),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: Icon(Icons.add),
      ),
    );
  }

  Color determineColour(FeatureStateHolder? data) {
    // ignore: avoid_print
    print('colour changed? $data');
    if (data == null || !data.exists) {
      return Colors.white;
    }
    // ignore: avoid_print
    print('colour is ${data.string}');
    switch (data.string) {
      case 'blue':
        return Colors.blue;
      case 'yellow':
        return Colors.yellow;
      case 'purple':
        return Colors.purple;
      case 'green':
        return Colors.green;
      case 'red':
        return Colors.red;
      default:
        return Colors.white;
    }
  }
}
