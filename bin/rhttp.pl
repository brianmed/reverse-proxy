#!/usr/bin/env perl

package Base;

use Modern::Perl;
use Carp qw();

# Kudos to Mojo::Base

sub import {
    my $class = shift;

    my $caller = caller;
    no strict 'refs';
    *{"${caller}::has"} = sub { attr($caller, @_) };
}

sub attr {
    my ($class, $attrs, $default) = @_;
    return unless ($class = ref $class || $class) && $attrs;

    Carp::croak 'Default has to be a code reference or constant value'
    if ref $default && ref $default ne 'CODE';

    for my $attr (@{ref $attrs eq 'ARRAY' ? $attrs : [$attrs]}) {
        Carp::croak qq{Attribute "$attr" invalid} unless $attr =~ /^[a-zA-Z_]\w*$/;

        # Header (check arguments)
        my $code = "package $class;\nsub $attr {\n  if (\@_ == 1) {\n";

        # No default value (return value)
        unless (defined $default) { $code .= "    return \$_[0]{'$attr'};" }

        # Default value
        else {
            # Return value
            $code .= "    return \$_[0]{'$attr'} if exists \$_[0]{'$attr'};\n";

            # Return default value
            $code .= "    return \$_[0]{'$attr'} = ";
            $code .= ref $default eq 'CODE' ? '$default->($_[0]);' : '$default;';
        }

        # Store value
        $code .= "\n  }\n  \$_[0]{'$attr'} = \$_[1];\n";

        # Footer (return invocant)
        $code .= "  \$_[0];\n}";

        Carp::croak "error: $@" unless eval "$code;1";
    }
}

package Backend;

use strict;
use warnings;

our @ISA = qw(Base AnyEvent::Handle);
BEGIN {
    Base->import;
}

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
    my %tls = ();
    if ($ops{vhost}{tls}) {
        $tls{tls} = "connect";
    }
    $backend = shift->SUPER::new(
        fh => $ops{fh},
        timeout => 30,
        on_timeout => sub {
            AE::log error => "Operation timed out";

            $backend->destroy;
        },
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
        %tls
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
            print(">>> $_") if ($ENV{RHTTP_PROXY_LOG});

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
                say("+++ Websocket pipe") if $ENV{RHTTP_PROXY_LOG};
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

    say(">>> [ws:brw] " . length($msg)) if $ENV{RHTTP_PROXY_LOG};
}

sub pipe_body {
    my ($backend, $browser) = @_;

    if ($backend->content_length == $backend->send_size) {
        $browser->on_drain(undef);
    }

    if ($backend->wtf_buffer) {
        $browser->push_write($backend->wtf_buffer);
        $backend->send_size($backend->send_size - length($backend->wtf_buffer));
        say(">>> [f] " . $backend->content_length() . " " . $backend->send_size() . " " . length($backend->wtf_buffer)) if $ENV{RHTTP_PROXY_LOG};
        $backend->wtf_buffer(undef);
    }

    my $msg = $backend->rbuf;
    substr($backend->rbuf, 0) = "";

    $backend->send_size($backend->send_size - length($msg));

    if (0 == $backend->send_size) {
        say(">>> [s] " . $backend->content_length() . " " . $backend->send_size() . " " . length($msg)) if $ENV{RHTTP_PROXY_LOG};
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
        say(">>> [w] " . $backend->content_length() . " " . $backend->send_size() . " " . length($msg)) if $ENV{RHTTP_PROXY_LOG};
        $browser->push_write($msg);
    }

    return 0;
}

package Browser;

use strict;
use warnings;

our @ISA = qw(Base AnyEvent::Handle);
BEGIN {
    Base->import;
}


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

    my %tls = ();
    if ($main::Config{cert_file}) {
        if ($main::Config{listen}{"${host}:$port"}{tls}) {
            $tls{tls} = "accept";
            $tls{tls_ctx} = { cert_file => $main::Config{cert_file}, key_file => $main::Config{key_file} };
        }
    }

    my $browser;
    $browser = shift->SUPER::new(
        fh => $fh,
        timeout => 30,
        on_timeout => sub {
            my $h = $browser->headers;
            $h->setpos(0);

            my $line = <$h> || "";
            $line =~ s#\015\012##;
            chomp($line);

            $line = $line && !$tls{tls} ? " [$line]" : "";

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
        %tls,
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

    say("===") if $ENV{RHTTP_PROXY_LOG};

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

    say(">>> [ws:bck] " . length($msg)) if $ENV{RHTTP_PROXY_LOG};
}

sub pipe_browser_content {
    my ($browser) = @_;

    my $msg = $browser->rbuf;
    substr($browser->rbuf, 0) = "";

    $browser->send_size($browser->send_size - length($msg));
    say(">>> " . $browser->content_length() . " " . $browser->send_size() . " " . length($msg)) if $ENV{RHTTP_PROXY_LOG};
    say("    >>> $msg") if $ENV{RHTTP_PROXY_LOG};

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
            print("<<< $_") if ($ENV{RHTTP_PROXY_LOG});
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
    my $vhost;

    foreach my $key (keys %$vhosts) {
        if ($key =~ m/^dbi/) {
            my $config = DBX->vhost($key, $host_header);
            if ($config) {
                my ($tls);

                ($host, $port, $tls) = split(/:/, $config);

                $vhost = {};
                $$vhost{host} = $host;
                $$vhost{port} = $port;
                $$vhost{tls} = $tls;
                
                last;
            }
        }
        if ($host_header eq $key) {
            $host = $vhosts->{$key}{host};
            $port = $vhosts->{$key}{port};
            $vhost = $vhosts->{$key};
        }
    }

    if (!$host && !$port) {
        if ($ENV{RHTTP_PROXY_LOG}) {
            say("Can't tcp_connect without a host and port: " . $host_header);
        }

        return;
    }

    tcp_connect($host => $port, sub {
        eval {
            my $fh = shift or die "unable to connect: [$host:$port]: $!";
            say("tcp_connect($_[0]:$_[1]) [$$vhost{tls}]") if ($ENV{RHTTP_PROXY_LOG});
            my $backend = Backend->new(fh => $fh, browser => $browser, vhost => $vhost);

            $backend->browser->parse_header;
        };
        warn($@) if $@;
    }) unless $browser->backend;
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

package DBX;

use DBIx::Connector;

sub vhost {
    my ($self, $dsn, $header) = @_;

    state $conn = {};
    state $lb = {};
    
    $$conn{$dsn} //= DBIx::Connector->new($dsn, undef, undef, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 0,
        pg_server_prepare => 0,
        pg_enable_utf8 => 1,
    });

    my $sql = "SELECT COUNT(config) FROM vhost WHERE header = ?";
    my $count = col($$conn{$dsn}, $sql, undef, $header);

    if (!$$lb{$header} || $count != $$lb{$header}{count}) {
        $$lb{$header} = {};
        $$lb{$header}{count} = $count;
        $$lb{$header}{offset} = 0;
    }

    my $offset = $$lb{$header}{offset};

    $sql = "SELECT config FROM vhost WHERE header = ? ORDER BY config LIMIT 1 OFFSET $offset";

    # It's a loadbalancer
    ++$offset;
    if ($offset >= $count) {
        $$lb{$header}{offset} = 0;
    }
    else {
        $$lb{$header}{offset} = $offset;
    }
    
    return(col($$conn{$dsn}, $sql, undef, $header));
}
sub col {
    my $conn = shift;
    my $sql = shift;
    my $attrs = shift;
    my @vars = @_;

    my $ret = $conn->dbh()->selectcol_arrayref($sql, $attrs, @vars);
    if ($ret && $$ret[0]) {
        return($$ret[0]);
    }

    return(undef);
}

package main;

use strict;
use warnings;

use Modern::Perl;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Log;
use AnyEvent::Socket;
use Getopt::Long;
use JSON::PP;

our $VERSION = "0.03";

$| = 1;

$AnyEvent::Log::FILTER->level("info");

our %Config = (
    config_file => "rhttp.json",
    cert_file => "",
    key_file => "",
    vhost => {},
    listen => {}
);

# load balancer with round-robin, least-connected

GetOptions(\%Config, "config_file|config=s", "host=s", "port=s", "add=s", "del=s") or exit;

if ($Config{add}) {
    my $json_config = config($Config{config_file});

    my $add = delete($Config{add});
    %Config = %{$json_config} if defined $json_config;

    if ($add =~ m#^vhost:(?<vhost>[^=]+)=(?<host>[^:]+):(?<port>\d+):tls_(?<tls>off|on)#) {
        my ($vhost, $host, $port, $tls) = ($+{vhost}, $+{host}, $+{port}, $+{tls});

        $Config{vhost}{$vhost}{host} = $host;
        $Config{vhost}{$vhost}{port} = $port;
        $Config{vhost}{$vhost}{tls} = "off" eq $tls ? 0 : 1;
    }
    elsif ($add =~ m#^vhost:dsn:(?<dsn>.*)#) {
        my ($dsn) = ($+{dsn});

        $Config{vhost}{$dsn} = 1;
    }
    elsif ($add =~ m#^listen:(?<ip>[^:]+):(?<port>\d+):tls_(?<tls>off|on)#) {
        my ($ip, $port, $tls) = ($+{ip}, $+{port}, $+{tls});

        $Config{listen}{"${ip}:$port"} = {ip => $ip, port => $port, tls => "off" eq $tls ? 0 : 1 };
    }
    elsif ($add =~ m#^host:(?<host>.*)#) {
        $Config{host} = $+{host};
    }
    elsif ($add =~ m#^port:(?<port>.*)#) {
        $Config{port} = $+{port};
    }
    elsif ($add =~ m#^cert_file:(?<cert_file>.*)#) {
        $Config{cert_file} = $+{cert_file};
    }
    elsif ($add =~ m#^key_file:(?<key_file>.*)#) {
        $Config{key_file} = $+{key_file};
    }
    else {
        die("Unknown -add option ($add)\n");
    }

    config($Config{config_file}, JSON::PP->new->ascii->pretty->encode(\%Config));

    exit;
}

if ($Config{del}) {
    my $json_config = config($Config{config_file});

    my $del = delete($Config{del});
    %Config = %{$json_config} if defined $json_config;

    if ($del =~ m#^vhost:(?<vhost>\S+)#) {
        my ($vhost) = ($+{vhost});

        if ($Config{vhost}{$vhost}) {
            delete($Config{vhost}{$vhost});
        }
        else {
            die("No vhost config found for ($vhost)\n");
        }
    } elsif ($del =~ m#^listen:(?<ip>[^:]+):(?<port>\d+)#) {
        my ($ip, $port) = ($+{host}, $+{port});

        my $listen = "${ip}:$port";

        if ($Config{listen}{$listen}) {
            delete($Config{listen}{$listen});
        }
        else {
            die("No listen config found for ($listen)\n");
        }
    }

    config($Config{config_file}, JSON::PP->new->ascii->pretty->encode(\%Config));

    exit;
}

my $json_config = config($Config{config_file});
%Config = %{$json_config} if defined $json_config;

if (0 == keys %{$Config{vhost}} || 0 == keys %{$Config{listen}}) {
    warn("Please configure rhttp.pl.\n");
    warn("Possibly:\n\n");

    warn("\$ perl rhttp.pl -add vhost:domain.com:80=127.0.0.1:3001:tls_off\n");
    warn("\$ perl rhttp.pl -add vhost:domain.com=127.0.0.1:3001:tls_off\n");
    warn("\$ perl rhttp.pl -add listen:192.168.10.12:80:tls_oiff\n");
    warn("\$ perl rhttp.pl -add listen:192.168.10.12:443:tls_on\n");

    exit;
}

my %server = ();

foreach my $listen (sort keys %{$Config{listen}}) {
    my ($host, $port) = split(/:/, $listen);

    say("tcp_server($host:$port) [tls: $Config{listen}{$listen}{tls}]") if ($ENV{RHTTP_PROXY_LOG});
    $server{$listen} = tcp_server($host, $port, sub {
        my ($fh, $peerhost, $peerport) = @_;

        my $listen = "${host}:$port";

        say("proxy_accept($peerhost:$peerport) [tls: $Config{listen}{$listen}{tls}]") if ($ENV{RHTTP_PROXY_LOG});

        Browser->new($fh, $host, $port);
    });
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

__END__


=pod

=head1 NAME

rhttp.pl - Reverse HTTP Proxy

=head1 SYNOPSIS

B<rhttp.pl>

=head1 OPTIONS

=over 4

=item B<-config>

Which config file to use.

=item B<-add>

Modify stored config file.  See below.

=item B<-del>

Modify stored config file.  See below.

=item B<-host>

IP to listen on.  Can be set in config file.

=item B<-port>

Port to listen on.  Can be set in config file.

=item B<-cert_file>

SSL cert file

=item B<-key_file>

SSL key file

=back

=head1 DESCRIPTION

This is a reverse http proxy that supports:

    HTTP/HTTPS reverse proxy (GET/POST)

    WebSockets

    VirtualHosts

    SSL

=head1 EXAMPLES

Run a reverse http proxy on domain.com and domain.net that routes to
127.0.0.1:3001 and 127.0.0.1:3002.  The proxy will listen on ip 192.168.10.12.

    $ perl rhttp.pl -add vhost:domain.com:80=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add vhost:domain.com=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add vhost:localhost=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add vhost:127.0.0.1:80=127.0.0.1:3001:tls_off
    $ perl rhttp.pl -add listen:127.0.0.1:80
    $ perl rhttp.pl

    $ perl rhttp.pl -del vhost:localhost
    $ perl rhttp.pl -del listen:127.0.0.1:80

=head1 NOTES

This program is considered beta.

=head1 AUTHOR
 
Brian Medley - C<bpmedley@cpan.org>

=cut
