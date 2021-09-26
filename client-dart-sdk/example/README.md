# Flutter Examples

## Using Rest api 

For this example refer to `main.dart` file

This example demonstrates FeatureHub Dart SDK implementation 
using GET api request to get feature states from the FeatureHub repository.

In this case, the Refresh Feature State button is used to request updated features which
trigger the stream to update and repaint the screen. 

It expects a string feature called CONTAINER_COLOUR to exist and have a set value of
blue, purple, yellow, green or red .

## Using SSE protocol (server-sent events)

For this example refer to `main-sse.dart` file

In this case colour of the container will be updated in real-time. Please refer to the main readme for details on this method. 

## Integration test 

For this example refer to `test/integration_test.dart` file
