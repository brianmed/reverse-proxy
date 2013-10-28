reverse-proxy
==============

Reverse HTTP Proxy

## Features

   * HTTP reverse proxy (GET/POST)

   * WebSockets

   * VirtualHosts

## Installation

    $ git clone https://github.com/brianmed/reverse-proxy .

## Configuration

    $ perl reverse_http.pl -add vhost:localhost:3152=127.0.0.1:8080
    $ perl reverse_http.pl -add vhost:127.0.0.1:3152=127.0.0.1:8080
    $ perl reverse_http.pl -add port:3152

    This allows for two vhosts that both point to 127.0.0.1 port 8080.  In
    addition, the reverse proxy listens on port 3152.

    The vhost is basically a string match against the Host: header field.

## Running

    $ perl reverse_http.pl

