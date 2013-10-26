package Backend;

use strict;
use warnings;

use feature qw(:5.16);

use Mojo::Base 'AnyEvent::Handle';

use AnyEvent::Socket;
use IO::String;

has qw(headers);
has qw(headers_done);
has qw(wtf_buffer);
has qw(send_size);
has qw(content_length);

sub DESTROY {
    say("DESTROY: Backend");
}

sub new {
    my ($self, %ops) = @_;

    my $backend;
    $backend = shift->SUPER::new(
        fh => $ops{fh},
        timeout => 4,
        on_error => sub {
            AE::log error => $_[2];
            $_[0]->destroy;
        },
        on_eof => sub {
            $backend->destroy; # destroy handle
            undef($backend);
            AE::log info => "Done.";
        }, 
    );

    $backend->init;

    return($backend);
}

sub init {
    my ($backend) = @_;

    $backend->headers(IO::String->new);
    $backend->headers_done(0);
    $backend->send_size(0);
    $backend->wtf_buffer("");
}

sub get_headers {
    my ($backend, $line, $eol, $browser) = @_;

    my $h = $backend->headers;

    if (!$line) {
        print($h "\015\012");
        $backend->headers_done(1);

        $h->setpos(0);
        while (<$h>) {
            print(">>> $_") if ($ENV{HTTP_PROXY_LOG});

            if (/Content-Length: (\d+)/) {
                $backend->content_length($1);
                $backend->send_size($1);
            }
        }
        $h->setpos(0);

        $backend->stop_read;
        $browser->push_write(${ $backend->headers->string_ref });

        return(1);
    }
    elsif ($line && !$backend->headers_done) {
        print($h "$line$eol");
        $backend->push_read(line => sub { shift->get_headers(@_, $browser) });
    }
    else {
        $backend->wtf_buffer($backend->wtf_buffer ."$line$eol");
    }

    return(0);
}

sub pipe_body {
    my ($backend, $browser, $cb) = @_;

    if ($backend->wtf_buffer) {
        $browser->push_write($backend->wtf_buffer);
        $backend->send_size($backend->send_size - length($backend->wtf_buffer));
        say(">>> " . $backend->content_length() . " " . $backend->send_size() . " " . length($backend->wtf_buffer)) if $ENV{HTTP_PROXY_LOG};
        $backend->wtf_buffer(undef);
    }

    my $msg = $backend->rbuf;
    substr($backend->rbuf, 0) = "";

    $backend->send_size($backend->send_size - length($msg));
    say(">>> " . $backend->content_length() . " " . $backend->send_size() . " " . length($msg)) if $ENV{HTTP_PROXY_LOG};

    if (0 == $backend->send_size) {
        $browser->on_drain( sub { shutdown($$browser{fh}, 2); shutdown($$backend{fh}, 2); undef($backend); } );
        $browser->push_write($msg);
    }
    else {
        $browser->push_write($msg);
    }
}

package Browser;

use strict;
use warnings;

use feature qw(:5.16);

use Mojo::Base 'AnyEvent::Handle';

use AnyEvent::Socket;
use IO::String;

has qw(headers);

sub DESTROY {
    say("DESTROY: Browser");
}

sub new {
    my ($self, $fh, $host, $port) = @_;

    my $browser;
    $browser = shift->SUPER::new(
        fh => $fh,
        timeout => 4,
        on_error => sub {
            AE::log error => $_[2];
            $_[0]->destroy;
        },
        on_eof => sub {
            $browser->destroy; # destroy handle
            undef($browser);
            AE::log info => "Done.";
        }, 
    );
    
    $browser->init;

    return($browser);
}

sub init {
    my ($browser) = @_;

    $browser->headers(IO::String->new);
}

sub get_headers {
    my ($browser, $line, $eol, $backend) = @_;

    my $h = $browser->headers;

    if (!$line) {
        print($h "\015\012");

        $h->setpos(0);
        while (<$h>) {
            print("<<< $_") if ($ENV{HTTP_PROXY_LOG});
            # $backend->push_write($_);
        }
        $h->setpos(0);

        $backend->push_write(${ $browser->headers->string_ref });

        # $cb->();
        # warn(length(${ $browser->headers->string_ref }));

        return(1);
    }
    elsif ($line && !$backend->headers_done) {
        print($h "$line$eol");
        $browser->push_read(line => sub { shift->get_headers(@_, $backend) });
    }
    else {
        die;
    }

    return(0);
}

package main;

use strict;
use warnings;

use feature qw(:5.16);

use AnyEvent;
use AnyEvent::Socket;

my $server = tcp_server("127.0.0.1", "3152", \&proxy_accept);

sub proxy_accept {
    my ($fh, $host, $port) = @_;

    my $browser = Browser->new($fh, $host, $port);
    tcp_connect(localhost => 8080, sub {
        my $fh = shift or die "unable to connect: $!";
        my $backend = Backend->new(fh => $fh);
        transaction($browser, $backend);
    });
}

sub transaction {
    my ($browser, $backend) = @_;
    
    # Send body
    $browser->on_drain(sub { $backend->on_read(sub { shift->pipe_body($browser) }) });

    # Read response headers after sending request headers
    $backend->on_drain(sub { $backend->push_read(line => sub { shift->get_headers(@_, $browser) }) });
    
    # Read headers
    $browser->push_read(line => sub { shift->get_headers(@_, $backend) });
    $backend->push_read(line => sub { shift->get_headers(@_, $browser) });
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
