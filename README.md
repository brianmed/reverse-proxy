reverse-proxy
==============

Reverse HTTP Proxy

## Features

   * HTTP reverse proxy (GET/POST)

   * WebSockets

   * VirtualHosts (JSON/DBI/LoadBalance)

   * SSL

## Installation

    $ cpan App::rhttp

## Configuration

    $ rhttp.pl -add vhost:dsn:dbi:Pg:dbname=rhttp
    $ rhttp.pl -add listen:127.0.0.1:80

    # Configures round-robin loadbalancing for 127.0.0.1:80 because the header is the same.
    $ echo "insert into vhost (header, config) values ('127.0.0.1:80', '127.0.0.1:4000:0');" | psql rhttp
    $ echo "insert into vhost (header, config) values ('127.0.0.1:80', '127.0.0.1:5000:0');" | psql rhttp

    $ rhttp.pl

    This allows for two vhosts that both point to 127.0.0.1 port 4000 and 5000;
    they are loadbalanced.  In addition, the reverse proxy listens on port 80.

    The vhost is basically a string match against the Host: header field.

## Running

    $ rhttp.pl

