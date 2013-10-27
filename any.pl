package Backend;

use strict;
use warnings;

use feature qw(:5.16);

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

sub DESTROY {
    # say("DESTROY: Backend");
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
 
   # called each time we receive data but the read queue is empty
   # simply start read the request
 
   $backend->push_read(line => \&get_headers);
}

sub init {
    my ($backend) = @_;

    $backend->headers(IO::String->new);
    $backend->headers_done(0);
    $backend->send_size(0);
    $backend->content_length(undef);
    $backend->wtf_buffer("");
    $backend->keep_alive(1);
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
        }
        $h->setpos(0);

        # "pipe" content if avail, if not, then restart
        if ($backend->content_length) {
            # Send the response header, then "pipe" the content
            $backend->browser->push_write(${ $backend->headers->string_ref });
            $backend->browser->on_drain(sub { $backend->unshift_read(sub { shift->pipe_body($backend->browser) }) });  # Who sells see shores?
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

    return(1);
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

        # $browser->on_drain(sub { $backend->push_read(sub { shift->pipe_body($browser) }) });
    }

    return 0;
}

package Browser;

use strict;
use warnings;

use feature qw(:5.16);

use Mojo::Base 'AnyEvent::Handle';

use AnyEvent::Socket;
use IO::String;

has qw(backend);
has qw(headers);
has qw(headers_done);
has qw(content_length);
has qw(send_size);
has qw(keep_alive);

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
        timeout => 4,
        on_error => sub {
            AE::log error => $_[2];
            $_[0]->destroy;
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
    $browser->content_length(undef);
    $browser->send_size(0);
    $browser->keep_alive(1);
}

sub restart {
    my ($browser, $backend) = @_;

    say("===") if $ENV{HTTP_PROXY_LOG};

    $backend->init;
    $browser->init;

    $browser->on_drain(undef);
    $backend->on_drain(undef);
    # $browser->on_read(\&Browser::default_read);
    # $backend->on_read(\&Backend::default_read);

    $browser->start_read;
    $backend->start_read;
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
   my ($backend) = @_;
 
   # called each time we receive data but the read queue is empty
   # simply start read the request
 
   $backend->push_read(line => \&get_headers);
}


sub get_headers {
    my ($browser, $line, $eol) = @_;

    my $h = $browser->headers;

    if (!$line) {
        print($h "\015\012");
        $browser->headers_done(1);

        $h->setpos(0);
        while (<$h>) {
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

    tcp_connect(localhost => 8080, sub {
        my $fh = shift or die "unable to connect: $!";
        my $backend = Backend->new(fh => $fh, browser => $browser);

        $backend->browser->parse_header;
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

use feature qw(:5.16);

use AnyEvent;
use AnyEvent::Socket;

my $server = tcp_server("127.0.0.1", "3152", \&proxy_accept);

sub proxy_accept {
    my ($fh, $host, $port) = @_;

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
