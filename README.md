reverse-proxy
==============

Reverse HTTP Proxy

## Features

   * HTTP reverse proxy (GET/POST)
   * WebSockets
   * VirtualHosts
   * SSL

## Installation

    $ git clone https://github.com/brianmed/reverse-proxy .

## Configuration

    $ perl rhttp.pl -add vhost:localhost=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add vhost:127.0.0.1:80=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add listen:127.0.0.1:80

    This allows for two vhosts that both point to 127.0.0.1 port 3001.  In
    addition, the reverse proxy listens on port 80.

    The vhost is basically a string match against the Host: header field.

## Running

    $ perl rhttp.pl

