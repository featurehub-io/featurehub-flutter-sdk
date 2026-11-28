# Builds the FeatureHub OpenFeature server provider's example (the todo server,
# featurehub-openfeatures-server-sdk/example/main.dart) against the packages in
# this repository. Build from the repository root, as the provider depends on
# its sibling packages by path:
#
#   docker build -t featurehub/dart-example .
#   docker run -p 8099:8099 -e FEATUREHUB_EDGE_URL=... \
#     -e FEATUREHUB_CLIENT_API_KEY=... featurehub/dart-example
FROM dart:3.14 AS build

WORKDIR /src
COPY featurehub-client-api featurehub-client-api
COPY featurehub-sse-client featurehub-sse-client
COPY featurehub-openfeatures-common featurehub-openfeatures-common
COPY featurehub-openfeatures-server-sdk featurehub-openfeatures-server-sdk

WORKDIR /src/featurehub-openfeatures-server-sdk
RUN dart pub get
RUN mkdir -p /out && dart compile exe example/main.dart -o /out/todo-server

# a minimal image: the Dart runtime's libraries and the compiled server
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/todo-server /app/todo-server
EXPOSE 8099
CMD ["/app/todo-server"]
