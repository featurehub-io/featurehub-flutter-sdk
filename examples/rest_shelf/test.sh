#!/bin/sh
curl -v -XPOST localhost:8099/todo/irina --data-binary '{"id":"1", "title":"food shopping"}'
curl -v localhost:8099/todo/irina