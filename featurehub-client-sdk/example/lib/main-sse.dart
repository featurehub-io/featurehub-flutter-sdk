import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:flutter/material.dart';

ClientFeatureRepository? repository;
FeatureHubConfig? featurehubApi;

void main() {
  repository = ClientFeatureRepository();

  // Listen to Feature Repository changes in real time using SSE (Server Sent Events protocol)
  // Provide host url (Edge FeatureHub server) and server eval api key for an application environment
  EdgeStreaming(
      'http://localhost:8903',
      'default/96f88200-a164-4d7c-8946-edc38f0b4520/leq9H9qGOJyb57sunVlGKW64w7OAgdhAKHXnNcos',
      repository!);

  // Uncomment below if you would like to pass context when using split targeting rules

  // repository!.clientContext
  //     .userKey('susanna')
  //     .device(StrategyAttributeDeviceName.desktop)
  //     .platform(StrategyAttributePlatformName.macos)
  //     .attr('sausage', 'cumberlands')
  //     .build();

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
          stream: repository!.feature('CONTAINER_COLOUR').featureUpdateStream,
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
    print('colour is ${data.stringValue}');
    switch (data.stringValue) {
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
