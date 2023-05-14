import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

FeatureHub? featurehubApi;
ClientContext? fhContext;

void main() {
  Logger.root.level = Level.WARNING; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  // There is an option to check for Readyness in appropriate circumstances.
  // repository!.readynessStream.listen((readyness) {
  //   if (readyness == Readyness.Ready) {
  //     //do something
  //   }
  //   else {
  //     //do something else
  //   }

  // Provide host url (Edge FeatureHub server) and server eval api key for an application environment
  featurehubApi = FeatureHubConfig(
      'http://localhost:8064/pistachio',
      [
        '135f4735-f1ab-4061-b69c-3a3debf2e344/CFArRq8UfTHcaK1fkOAtnKnbrFG0xQMcZuFPfUBh'
      ]).timeout(2);

  featurehubApi?.start().then((value) => fhContext = value);

  // Uncomment below if you would like to pass context when using split targeting rules

  // repository!.clientContext
  //     .userKey('susanna')
  //     .device(StrategyAttributeDeviceName.desktop)
  //     .platform(StrategyAttributePlatformName.macos)
  //     .attr('sausage', 'cumberlands')
  //     .build();
  // featurehubApi!.request();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;

  MyHomePage({Key? key, required this.title}) : super(key: key);

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: StreamBuilder<FeatureStateHolder>(
          stream: fhContext?.feature('CONTAINER_COLOUR').featureUpdateStream,
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
                          style: Theme.of(context).textTheme.headline4,
                        ),
                        ElevatedButton(
                            // Request feature updates via Get request
                            onPressed: () async => await fhContext?.build(),
                            child: Text('Refresh feature state'))
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
