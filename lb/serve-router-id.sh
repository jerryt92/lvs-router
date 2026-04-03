#!/bin/sh
# One HTTP request per connection; ignore request body.
while IFS= read -r line; do
  line=$(printf '%s' "$line" | tr -d '\r')
  [ -z "$line" ] && break
done
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n'
cat /run/router-http/router_id
