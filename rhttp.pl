#!/usr/bin/env perl

package Backend;

use strict;
use warnings;

use feature qw(:5.10);

use Mojo::Base 'AnyEvent::Handle';

use AnyEvent::Socket;
use IO::String;

has qw(browser);
has qw(headers);
has qw(headers_done);
has qw(wtf_buffer);
has qw(send_size);
has qw(content_length);
has qw(keep_alive);
has qw(websocket);

sub DESTROY {
    # say("DESTROY: Backend");
}

sub new {
    my ($self, %ops) = @_;

    my $backend;
    $backend = shift->SUPER::new(
        fh => $ops{fh},
        timeout => 45,
        on_error => sub {
            AE::log error => $_[2];
            $_[0]->destroy;
        },
        on_eof => sub {
            $backend->destroy;
            undef($backend);
            AE::log info => "Done.";
        }, 
        on_read => \&default_read,
    );

    $backend->browser(delete $ops{browser});
    $backend->browser->backend($backend);  # Hrmm

    $backend->init;

    return($backend);
}

sub default_read {
   my ($backend) = @_;
 
   if ($backend->websocket) {
       $backend->push_read(\&pipe_websocket);
   }
   else {
       $backend->push_read(line => \&get_headers);
   }
}

sub init {
    my ($backend) = @_;

    $backend->headers(IO::String->new);
    $backend->headers_done(0);
    $backend->send_size(0);
    $backend->content_length(undef);
    $backend->wtf_buffer("");
    $backend->keep_alive(1);
    $backend->websocket(0);
}

sub get_headers {
    my ($backend, $line, $eol) = @_;

    my $h = $backend->headers;

    if (!$line) {
        print($h "\015\012");
        $backend->headers_done(1);
        $backend->stop_read;

        $h->setpos(0);
        while (<$h>) {
            print(">>> $_") if ($ENV{HTTP_PROXY_LOG});

            if (/Content-Length: (\d+)/) {
                $backend->content_length($1);
                $backend->send_size($1);
            }
            if (/Connection: close/) {
                $backend->keep_alive(0);
            }
            if (/Sec-WebSocket-Accept/) {
                $backend->websocket(1);
                $backend->browser->websocket(1);
            }
        }
        $h->setpos(0);

        # "pipe" content if avail, if not, then restart
        if ($backend->content_length) {
            # Send the response header, then "pipe" the content
            $backend->browser->push_write(${ $backend->headers->string_ref });
            $backend->browser->on_drain(sub { $backend->unshift_read(sub { shift->pipe_body($backend->browser) }) });  # Who sells see shores?
        }
        elsif ($backend->websocket && $backend->browser->websocket) {
            $backend->start_read;
            $backend->browser->push_write(${ $backend->headers->string_ref });

            $backend->browser->on_drain(sub { 
                my $browser = shift;
                $browser->timeout(60);
                $browser->backend->timeout(60);
                say("+++ Websocket pipe") if $ENV{HTTP_PROXY_LOG};
                $browser->on_drain(undef);
                $browser->backend->on_drain(undef);
            });
        }
        else {
            $backend->browser->push_write(${ $backend->headers->string_ref });
            $backend->browser->on_drain(sub { shift->restart($backend) });
        }
    }
    elsif ($line && !$backend->headers_done) {
        print($h "$line$eol");
    }
    else {
        $backend->wtf_buffer($backend->wtf_buffer ."$line$eol");
    }
}

sub pipe_websocket {
    my ($backend) = @_;

    my $msg = $backend->rbuf;
    substr($backend->rbuf, 0) = "";
    $backend->browser->push_write($msg);

    say(">>> [ws:brw] " . length($msg)) if $ENV{HTTP_PROXY_LOG};
}

sub pipe_body {
    my ($backend, $browser) = @_;

    if ($backend->content_length == $backend->send_size) {
        $browser->on_drain(undef);
    }

    if ($backend->wtf_buffer) {
        $browser->push_write($backend->wtf_buffer);
        $backend->send_size($backend->send_size - length($backend->wtf_buffer));
        say(">>> [f] " . $backend->content_length() . " " . $backend->send_size() . " " . length($backend->wtf_buffer)) if $ENV{HTTP_PROXY_LOG};
        $backend->wtf_buffer(undef);
    }

    my $msg = $backend->rbuf;
    substr($backend->rbuf, 0) = "";

    $backend->send_size($backend->send_size - length($msg));

    if (0 == $backend->send_size) {
        say(">>> [s] " . $backend->content_length() . " " . $backend->send_size() . " " . length($msg)) if $ENV{HTTP_PROXY_LOG};
        $browser->stop_read;
        $backend->stop_read;
        $browser->push_write($msg);

        if ($browser->keep_alive && $backend->keep_alive) {
            $browser->on_drain( sub { shift->restart($backend) } );
        }
        else {
            $browser->on_drain( sub { shutdown($$backend{fh}, 1); $backend->timeout(1); } );
        }

        return 1;
    }
    else {
        say(">>> [w] " . $backend->content_length() . " " . $backend->send_size() . " " . length($msg)) if $ENV{HTTP_PROXY_LOG};
        $browser->push_write($msg);
    }

    return 0;
}

package Browser;

use strict;
use warnings;

use feature qw(:5.10);

use Mojo::Base 'AnyEvent::Handle';

use AnyEvent::Socket;
use IO::String;

has qw(backend);
has qw(headers);
has qw(headers_done);
has qw(host_header);
has qw(content_length);
has qw(send_size);
has qw(keep_alive);
has qw(websocket);

sub DESTROY {
    my ($browser) = @_;

    # say("DESTROY: Browser");

    if ($browser->backend) {
        $browser->backend->destroy;
    }
}

sub new {
    my ($self, $fh, $host, $port) = @_;

    my $browser;
    $browser = shift->SUPER::new(
        fh => $fh,
        timeout => 45,
        on_timeout => sub {
            my $h = $browser->headers;
            $h->setpos(0);

            my $line = <$h> || "";
            $line =~ s#\015\012##;
            chomp($line);

            $line = $line ? " [$line]" : "";

            AE::log error => "Operation timed out$line";

            if ($browser->backend) {
                $browser->backend->destroy;
            }

            $browser->destroy;
        },
        on_error => sub {
            AE::log error => $_[2];
            $browser->destroy;
        },
        on_eof => sub {
            $browser->destroy;
            if ($browser->backend) {
                $browser->backend->destroy;

                undef($browser->backend);
            }
            undef($browser);
            AE::log info => "Done.";
        }, 
        on_read => \&default_read,
    );

    $browser->init;

    return($browser);
}

sub init {
    my ($browser) = @_;

    $browser->headers(IO::String->new);
    $browser->headers_done(0);
    $browser->host_header("");
    $browser->content_length(undef);
    $browser->send_size(0);
    $browser->keep_alive(1);
    $browser->websocket(0);
}

sub restart {
    my ($browser, $backend) = @_;

    say("===") if $ENV{HTTP_PROXY_LOG};

    $backend->init;
    $browser->init;

    $browser->on_drain(undef);
    $backend->on_drain(undef);

    $browser->start_read;
    $backend->start_read;
}

sub pipe_websocket {
    my ($browser) = @_;

    my $msg = $browser->rbuf;
    substr($browser->rbuf, 0) = "";

    $browser->backend->push_write($msg);

    say(">>> [ws:bck] " . length($msg)) if $ENV{HTTP_PROXY_LOG};
}

sub pipe_browser_content {
    my ($browser) = @_;

    my $msg = $browser->rbuf;
    substr($browser->rbuf, 0) = "";

    $browser->send_size($browser->send_size - length($msg));
    say(">>> " . $browser->content_length() . " " . $browser->send_size() . " " . length($msg)) if $ENV{HTTP_PROXY_LOG};
    say("    >>> $msg") if $ENV{HTTP_PROXY_LOG};

    $browser->backend->push_write($msg);

    if (0 == $browser->send_size) {
        return 1;
    }

    return 0;
}

sub default_read {
   my ($browser) = @_;
 
   if ($browser->websocket) {
       $browser->push_read(\&pipe_websocket);
   }
   else {
       $browser->push_read(line => \&get_headers);
   }
}

sub get_headers {
    my ($browser, $line, $eol) = @_;

    my $h = $browser->headers;

    if (!$line) {
        print($h "\015\012");
        $browser->headers_done(1);

        $h->setpos(0);
        while (<$h>) {
            if (/Host:\s+([:\d\w\.-]+)/) {
                my $tmp = $1;
                $tmp =~ s#\015\012##;
                $browser->host_header($tmp);
            }
            if (/Content-Length: (\d+)/) {
                $browser->content_length($1);
                $browser->send_size($1);
            }
            if (/Connection: close/) {
                $browser->keep_alive(0);
            }
            print("<<< $_") if ($ENV{HTTP_PROXY_LOG});
        }
        $h->setpos(0);

        $browser->connect_backend;
    }
    elsif ($line && !$browser->headers_done) {
        print($h "$line$eol");
    }
    else {
        die;
    }
}

sub connect_backend {
    my ($browser) = @_;

    my $vhosts = $main::Config{vhost};

    my $host_header = $browser->host_header;
    my $host;
    my $port;

    foreach my $vhost (keys %$vhosts) {
        if ($host_header eq $vhost) {
            $host = $vhosts->{$vhost}{host};
            $port = $vhosts->{$vhost}{port};
        }
    }

    if (!$host && !$port) {
        if ($ENV{HTTP_PROXY_LOG}) {
            say("Can't tcp_connect without a host and port: " . $host_header);
        }

        return;
    }

    tcp_connect($host => $port, sub {
        eval {
            my $fh = shift or die "unable to connect: [$host:$port]: $!";
            say("tcp_connect($_[0]:$_[1])") if ($ENV{HTTP_PROXY_LOG});
            my $backend = Backend->new(fh => $fh, browser => $browser);

            $backend->browser->parse_header;
        };
        warn($@) if $@;
    });
}

sub parse_header {
    my ($browser) = @_;

    if ($browser->content_length) {
        # Send headers to backend
        $browser->stop_read;
        $browser->backend->push_write(${ $browser->headers->string_ref });

        # "pipe" content data if avail, if not, then read backend headers
        if ($browser->content_length) {
            $browser->backend->on_drain(sub { $browser->unshift_read(sub { shift->pipe_browser_content }) });
        }
    }
    else {
        # Write the non post request
        $browser->backend->push_write(${ $browser->headers->string_ref });
    }
}


package main;

use strict;
use warnings;

use feature qw(:5.10);

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Log;
use Getopt::Long;
use JSON::PP;

$| = 1;

$AnyEvent::Log::FILTER->level("info");

our %Config = (
    config_file => "rhttp.json",
    host => "127.0.0.1",
    port => "80",
    vhost => {},
);

GetOptions(\%Config, "config_file|config=s", "host=s", "port=s", "add=s");

if ($Config{add}) {
    my $json_config = config($Config{config_file});

    my $add = delete($Config{add});
    %Config = %{$json_config} if defined $json_config;

    if ($add =~ m#^vhost:(?<vhost>[^=]+)=(?<host>[^:]+):(?<port>\d+)#) {
        my ($vhost, $host, $port) = ($+{vhost}, $+{host}, $+{port});

        $Config{vhost}{$vhost}{host} = $host;
        $Config{vhost}{$vhost}{port} = $port;
    }
    elsif ($add =~ m#^host:(?<host>.*)#) {
        $Config{host} = $+{host};
    }
    elsif ($add =~ m#^port:(?<port>.*)#) {
        $Config{port} = $+{port};
    }

    config($Config{config_file}, JSON::PP->new->ascii->pretty->encode(\%Config));

    exit;
}

my $json_config = config($Config{config_file});
%Config = %{$json_config} if defined $json_config;

say("tcp_server($Config{host}:$Config{port})") if ($ENV{HTTP_PROXY_LOG});
my $server = tcp_server($Config{host}, $Config{port}, \&proxy_accept);

sub proxy_accept {
    my ($fh, $host, $port) = @_;

    say("proxy_accept($host:$port)") if ($ENV{HTTP_PROXY_LOG});
    my $browser = Browser->new($fh, $host, $port);
}

my $done = AnyEvent->condvar;
my $w = AnyEvent->signal (signal => "INT", cb => sub { $done->send });
$done->recv;

sub dumper {
    require Data::Dumper;
    $Data::Dumper::Useqq = 1;
    $Data::Dumper::Useqq = 1;

    print Data::Dumper::Dumper(\@_);
}

sub config {
    my ($file, $json) = @_;

    if ($json) {
        open(my $h, "> $file") or die("error: open: $file\n");
        print($h $json);
        close($file);

        return(JSON::PP::decode_json($json));
    }
    else {
        unless (-f $file) {
            return(undef);
        }

        open(my $h, $file) or die("error: open: $file\n");
        my $text = join("", <$h>);
        close($file);

        return(JSON::PP::decode_json($text));
    }
}
