# vim:set ft= ts=4 sw=4 et fdm=marker:

use lib 'lib';
use Test::Nginx::Socket;

repeat_each(2);

plan tests => repeat_each() * (blocks() * 5 + 10);

our $HtmlDir = html_dir;

$ENV{TEST_NGINX_CLIENT_PORT} ||= server_port();
$ENV{TEST_NGINX_MEMCACHED_PORT} ||= 11211;

no_long_string();
#no_diff();
#log_level 'warn';

run_tests();

__DATA__

=== TEST 1: sanity
--- http_config eval
    "lua_package_path '$::HtmlDir/?.lua;./?.lua';"
--- config
    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;
        content_by_lua '
            local test = require "test"
            local port = ngx.var.port
            test.go(port)
            test.go(port)
        ';
    }
--- user_files
>>> test.lua
module("test", package.seeall)

function go(port)
    local sock = ngx.socket.tcp()
    local ok, err = sock:connect("127.0.0.1", port)
    if not ok then
        ngx.say("failed to connect: ", err)
        return
    end

    ngx.say("connected: ", ok, ", reused: ", sock:getreusedtimes())

    local req = "flush_all\r\n"

    local bytes, err = sock:send(req)
    if not bytes then
        ngx.say("failed to send request: ", err)
        return
    end
    ngx.say("request sent: ", bytes)

    local line, err, part = sock:receive()
    if line then
        ngx.say("received: ", line)

    else
        ngx.say("failed to receive a line: ", err, " [", part, "]")
    end

    local ok, err = sock:setkeepalive()
    if not ok then
        ngx.say("failed to set reusable: ", err)
    end
end
--- request
GET /t
--- response_body_like
^connected: 1, reused: \d+
request sent: 11
received: OK
connected: 1, reused: [1-9]\d*
request sent: 11
received: OK
--- no_error_log eval
["[error]",
"lua socket keepalive: free connection pool for "]
--- error_log eval
qq{lua socket get keepalive peer: using connection
lua socket keepalive create connection pool for key "127.0.0.1:$ENV{TEST_NGINX_MEMCACHED_PORT}"
}



=== TEST 2: free up the whole connection pool if no active connections
--- http_config eval
    "lua_package_path '$::HtmlDir/?.lua;./?.lua';"
--- config
    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;
        content_by_lua '
            local test = require "test"
            local port = ngx.var.port
            test.go(port, true)
            test.go(port, false)
        ';
    }
--- request
GET /t
--- user_files
>>> test.lua
module("test", package.seeall)

function go(port, keepalive)
    local sock = ngx.socket.tcp()
    local ok, err = sock:connect("127.0.0.1", port)
    if not ok then
        ngx.say("failed to connect: ", err)
        return
    end

    ngx.say("connected: ", ok, ", reused: ", sock:getreusedtimes())

    local req = "flush_all\r\n"

    local bytes, err = sock:send(req)
    if not bytes then
        ngx.say("failed to send request: ", err)
        return
    end
    ngx.say("request sent: ", bytes)

    local line, err, part = sock:receive()
    if line then
        ngx.say("received: ", line)

    else
        ngx.say("failed to receive a line: ", err, " [", part, "]")
    end

    if keepalive then
        local ok, err = sock:setkeepalive()
        if not ok then
            ngx.say("failed to set reusable: ", err)
        end

    else
        sock:close()
    end
end
--- response_body_like
^connected: 1, reused: \d+
request sent: 11
received: OK
connected: 1, reused: [1-9]\d*
request sent: 11
received: OK
--- no_error_log
[error]
--- error_log eval
["lua socket get keepalive peer: using connection",
"lua socket keepalive: free connection pool for "]



=== TEST 3: upstream sockets close prematurely
--- http_config eval
    "lua_package_path '$::HtmlDir/?.lua;./?.lua';"
--- config
   server_tokens off;
   keepalive_timeout 100ms;
   location /t {
        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, err = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive()
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive close handler",
"lua socket keepalive: free connection pool for "]
--- timeout: 3



=== TEST 4: http keepalive
--- http_config eval
    "lua_package_path '$::HtmlDir/?.lua;./?.lua';"
--- config
   server_tokens off;
   location /t {
        keepalive_timeout 60s;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, err = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive()
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log eval
["[error]",
"lua socket keepalive close handler: fd:",
"lua socket keepalive: free connection pool for "]
--- timeout: 4



=== TEST 5: lua_socket_keepalive_timeout
--- config
   server_tokens off;
   location /t {
       keepalive_timeout 60s;
       lua_socket_keepalive_timeout 100ms;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive()
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive close handler",
"lua socket keepalive: free connection pool for ",
"lua socket keepalive timeout: 100 ms",
qr/lua socket connection pool size: 30\b/]
--- timeout: 4



=== TEST 6: lua_socket_pool_size
--- config
   server_tokens off;
   location /t {
       keepalive_timeout 60s;
       lua_socket_keepalive_timeout 100ms;
       lua_socket_pool_size 1;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive()
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive close handler",
"lua socket keepalive: free connection pool for ",
"lua socket keepalive timeout: 100 ms",
qr/lua socket connection pool size: 1\b/]
--- timeout: 4



=== TEST 7: "lua_socket_keepalive_timeout 0" means unlimited
--- config
   server_tokens off;
   location /t {
       keepalive_timeout 60s;
       lua_socket_keepalive_timeout 0;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive()
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive timeout: unlimited",
qr/lua socket connection pool size: 30\b/]
--- timeout: 4



=== TEST 8: setkeepalive(timeout) overrides lua_socket_keepalive_timeout
--- config
   server_tokens off;
   location /t {
        keepalive_timeout 60s;
        lua_socket_keepalive_timeout 60s;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive(123)
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive close handler",
"lua socket keepalive: free connection pool for ",
"lua socket keepalive timeout: 123 ms",
qr/lua socket connection pool size: 30\b/]
--- timeout: 4



=== TEST 9: sock:setkeepalive(timeout, size) overrides lua_socket_pool_size
--- config
   server_tokens off;
   location /t {
       keepalive_timeout 60s;
       lua_socket_keepalive_timeout 100ms;
       lua_socket_pool_size 100;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive(101, 25)
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive close handler",
"lua socket keepalive: free connection pool for ",
"lua socket keepalive timeout: 101 ms",
qr/lua socket connection pool size: 25\b/]
--- timeout: 4



=== TEST 10: sock:keepalive_timeout(0) means unlimited
--- config
   server_tokens off;
   location /t {
       keepalive_timeout 60s;
       lua_socket_keepalive_timeout 1000ms;

        set $port $TEST_NGINX_CLIENT_PORT;
        content_by_lua '
            local port = ngx.var.port

            local sock = ngx.socket.tcp()

            local ok, err = sock:connect("127.0.0.1", port)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local req = "GET /foo HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: keepalive\\r\\n\\r\\n"

            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send request: ", err)
                return
            end

            ngx.say("request sent: ", bytes)

            local reader = sock:receiveuntil("\\r\\n0\\r\\n\\r\\n")
            local data, res = reader()

            if not data then
                ngx.say("failed to receive response body: ", err)
                return
            end

            ngx.say("received response of ", #data, " bytes")

            local ok, err = sock:setkeepalive(0)
            if not ok then
                ngx.say("failed to set reusable: ", err)
            end

            ngx.location.capture("/sleep")

            ngx.say("done")
        ';
    }

    location /foo {
        echo foo;
    }

    location /sleep {
        echo_sleep 1;
    }
--- request
GET /t
--- response_body
connected: 1
request sent: 61
received response of 156 bytes
done
--- no_error_log
[error]
--- error_log eval
["lua socket keepalive timeout: unlimited",
qr/lua socket connection pool size: 30\b/]
--- timeout: 4



=== TEST 11: sanity (uds)
--- http_config eval
"
    lua_package_path '$::HtmlDir/?.lua;./?.lua';
    server {
        listen unix:/tmp/test-nginx.sock;
        default_type 'text/plain';

        server_tokens off;
        location /foo {
            echo foo;
            more_clear_headers Date;
        }
    }
"
--- config
    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;
        content_by_lua '
            local test = require "test"
            local port = ngx.var.port
            test.go(port)
            test.go(port)
        ';
    }
--- request
GET /t
--- user_files
>>> test.lua
module("test", package.seeall)

function go(port)
    local sock = ngx.socket.tcp()
    local ok, err = sock:connect("unix:/tmp/test-nginx.sock")
    if not ok then
        ngx.say("failed to connect: ", err)
        return
    end

    ngx.say("connected: ", ok, ", reused: ", sock:getreusedtimes())

    local req = "GET /foo HTTP/1.1\r\nHost: localhost\r\nConnection: keepalive\r\n\r\n"

    local bytes, err = sock:send(req)
    if not bytes then
        ngx.say("failed to send request: ", err)
        return
    end
    ngx.say("request sent: ", bytes)

    local reader = sock:receiveuntil("\r\n0\r\n\r\n")
    local data, err = reader()

    if not data then
        ngx.say("failed to receive response body: ", err)
        return
    end

    ngx.say("received response of ", #data, " bytes")

    local ok, err = sock:setkeepalive()
    if not ok then
        ngx.say("failed to set reusable: ", err)
    end
end
--- response_body_like
^connected: 1, reused: \d+
request sent: 61
received response of 119 bytes
connected: 1, reused: [1-9]\d*
request sent: 61
received response of 119 bytes
--- no_error_log eval
["[error]",
"lua socket keepalive: free connection pool for "]
--- error_log eval
["lua socket get keepalive peer: using connection",
'lua socket keepalive create connection pool for key "unix:/tmp/test-nginx.sock"']

