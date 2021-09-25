import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:flutter/material.dart';

ClientFeatureRepository? featurehub;
FeatureHubSimpleApi? featurehubApi;

void main() {
  featurehub = ClientFeatureRepository();

  // Provide host url (Edge FeatureHub server) and server eval api key for an application environment
  featurehubApi = FeatureHubSimpleApi(
      'http://localhost:8903',
      [
        'default/806d0fe8-2842-4d17-9e1f-1c33eedc5f31/tnZHPUIKV9GPM4u0koKPk1yZ3aqZgKNI7b6CT76q'
      ],
      featurehub!);

  // Request feature updates via Get request
  featurehubApi!.request();

  // Uncomment below if you would like to pass context when using split targeting rules

  // featurehub!.clientContext
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
          stream: featurehub!.feature('CONTAINER_COLOUR').featureUpdateStream,
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
                            onPressed: () => featurehubApi!.request(),
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
