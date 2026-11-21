1.5.0
=====
* Requires Dart 3.12.2 or later, and uses `lints` instead of `flutter_lints`
* A rollout strategy with a null or absent `attributes` (e.g. a pure percentage strategy) decodes as an empty list
  rather than failing the whole feature
* Polls FeatureHub Edge at `/features` (as the other SDKs do), not `/features/` as generated from the API definition

1.4.0
=====
* Updated SDK based on current Edge API

1.3.0
=====
* Update GitHub repository URL

1.2.0
=====
* Null safe version, minor API update

1.1.2
=====
* Documentation update

1.1.1
=====
* Updated API for Edge, including GET api.

1.0.1
=====
* Checks in the generated code

1.0.0
=====
* This API is generated and reflect the current state of the OpenAPI.
