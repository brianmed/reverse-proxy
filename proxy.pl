#!/opt/perl

use strict;
use warnings;

use feature qw(:5.16);

package IO::Socket::INET::Proxy;

use parent qw(IO::Socket::INET IO::Socket::Util);

sub accept {
    my $self = shift;

    my $browser = $self->SUPER::accept(@_);

    if ($browser) {
        # warn("$browser");
        my $peerhost = $browser->peerhost();
        my $peerport = $browser->peerport();
        $self->log("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
        # print("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
        $browser->log("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
    }

    return($browser);
}

package IO::Socket::INET::Backend;

use parent qw(IO::Socket::INET IO::Socket::Util);

use Event::Lib;
use IO::String;

sub DESTROY {
    my $self = shift;
    # warn("[DESTROY: $self]\n");
}

sub headers {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{headers} = $_[0];
    }

    return($session->{headers});
}

sub websocket {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{websocket} = $_[0];
    }

    return(exists $session->{websocket} ? $session->{websocket} : 0);
}

sub keep_alive {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{keep_alive} = $_[0];
    }

    return(exists $session->{keep_alive} ? $session->{keep_alive} : 0);
}

sub browser {
    my $self = shift;
    
    my $session = $main::session{$self};

    if (@_) {
        $session->{browser} = $_[0];
    }

    return($session->{browser});
}

sub state {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{state} = $_[0];

        if ("headers_from_backend" eq $_[0]) {
            $self->headers(IO::String->new);
        }

        if ("delete" eq $_[0]) {
            # event_new($self, EV_TIMEOUT, \&main::cull_session)->add(0.1);
        }

        $self->inprocess(1);
    }

    $self->logf("[State: $self: $$session{state}: %s\n", join("|", caller())) if @_;

    return($session->{state});
}

sub inprocess {
    my $self = shift;

    if ("delete" eq $_[0]) {
        delete $main::inprocess{$self};
    }
    else {
        $main::inprocess{$self} = $_[0];
    }
}

sub content_length {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{content_length} = $_[0];
    }

    return(exists $session->{content_length} ? $session->{content_length} : 0);
}

sub process {
    my $self = shift;

    my $browserhost = $self->browser->peerhost();
    my $browserport = $self->browser->peerport();

    my $peerhost = $self->peerhost();
    my $peerport = $self->peerport();

    if ("headers_to_backend" eq $self->state) {
        $self->log("[Sending browser headers: ${browserhost}::$browserport -> ${peerhost}::$peerport]\n");

        my $io = $self->browser->headers;
        my $post = 0;
        $self->keep_alive(0);
        while(<$io>) {
            my $chop = $_;
            chop($chop);
            chop($chop);
            $self->log("[${browserhost}::$browserport -> ${peerhost}::$peerport -> $chop]\n");
            $self->send($_);

            $post = 1 if m#^POST \S+ HTTP/1.1#;
            $self->keep_alive(1) if m#Connection: keep-alive#;
        }
        $io->setpos(0);

        if ($post) {
            $self->browser->state("post_to_backend");
            $self->state("iowait");
        }
        else {
            $self->browser->state("iowait");
            $self->state("headers_from_backend");
        }
    }

    if ("headers_from_backend" eq $self->state) {
        $self->recv_headers;

        # $self->log("[Receiving backend response: $peerhost::$peerport -> ${browserhost}::$browserport]\n");

        my $io = $self->headers;
        my $ref = $io->string_ref;

        return(undef) if $$ref !~ m#\015\012\015\012#;

        $io->setpos(0);

        $self->state("iowait");
        $self->browser->state("headers_to_browser");
    }

    if ("pipe" eq $self->state) {
        my $bytes = 0;
        if ($self->content_length) {
            my $buf;
            my $log = 1;
            while(defined $self->recv($buf, $self->content_length > 1024 ? 1024 : $self->content_length)) {
                last if 0 == length($buf);

                $self->logf("[Sending backend packet (%d): ${peerhost}::$peerport -> ${browserhost}::$browserport]\n", length($buf)) if $log;
                $log = 0;

                $bytes += length($buf);

                my $cnt = $self->browser->send($buf);
                if ($cnt != length($buf)) {
                    die;
                }

                last if length($buf) == $self->content_length;
                last if $bytes == $self->content_length;
            }
        }

        $self->logf("[No more packets ($bytes - %d): ${peerhost}::$peerport -> ${browserhost}::$browserport]\n", $self->content_length);

        if ($self->keep_alive) {
            $self->browser->state("headers_from_browser");
            $self->state("iowait");
        }
        else {
            $self->state("delete");
            $self->browser->state("delete");
            $self->inprocess("delete");
            $self->browser->inprocess("delete");
        }
    }

    if ("websocket" eq $self->state) {
        my $bytes = 0;

        my $buf;

        $self->recv($buf, 128, Socket::MSG_DONTWAIT);
        if ($buf) {
            $self->logf("[Sending browser websocket (%d :: %d): ${peerhost}::$peerport -> ${browserhost}::$browserport]\n", $bytes, length($buf));

            $bytes += length($buf);

            $self->browser->send($buf);
        }

        $self->logf("[No more websocket packets ($bytes): ${peerhost}::$peerport -> ${browserhost}::$browserport]\n");
    }

    return(undef);
}

package IO::Socket::INET::Browser;

use parent qw(IO::Socket::INET IO::Socket::Util);

use Event::Lib;
use IO::String;

sub DESTROY {
    my $self = shift;
    # warn("[DESTROY: $self]\n");
}

sub backend {
    my $self = shift;
    
    my $session = $main::session{$self};

    if (@_) {
        $session->{backend} = $_[0];
    }

    return($session->{backend});
}

sub content_length {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{content_length} = $_[0];
    }

    return(exists $session->{content_length} ? $session->{content_length} : 0);
}

sub state {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{state} = $_[0];

        if ("headers_from_browser" eq $_[0]) {
            $self->headers(IO::String->new);
        }

        if ("delete" eq $_[0]) {
            # event_new($self, EV_TIMEOUT, \&main::cull_session)->add(0.1);
        }

        $self->inprocess(1);
    }

    $self->logf("[State: $self: $$session{state}: %s\n", join("|", caller())) if @_;

    return($session->{state});
}

sub inprocess {
    my $self = shift;

    if ("delete" eq $_[0]) {
        delete $main::inprocess{$self};
    }
    else {
        $main::inprocess{$self} = $_[0];
    }
}

sub headers {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{headers} = $_[0];
    }

    return($session->{headers});
}

sub websocket {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{websocket} = $_[0];
    }

    return(exists $session->{websocket} ? $session->{websocket} : 0);
}

sub keep_alive {
    my $self = shift;

    my $session = $main::session{$self};
    
    if (@_) {
        $session->{keep_alive} = $_[0];
    }

    return(exists $session->{keep_alive} ? $session->{keep_alive} : 0);
}

sub process {
    my $self = shift;

    if ("headers_from_browser" eq $self->state) {
        $self->recv_headers;

        my $io = $self->headers;
        my $ref = $io->string_ref;

        return(undef) if $$ref !~ m#\015\012\015\012#;
        return(undef) if 0 == length($$ref);

        $self->state("iowait");
        
        my $backend = IO::Socket::INET::Backend->new(
            PeerAddr => 'localhost',
            PeerPort => 8080,
            Proto => 'tcp',
            Blocking => 0,
        );
        die "Could not create backend socket: $!\n" unless $backend;

        my $event = event_new($backend, EV_READ|EV_PERSIST, \&main::event);
        $main::session{$backend}->{event} = $event;
        $event->add;

        $main::session{$backend}->{obj} = $backend;
        $backend->state("headers_to_backend");
        $backend->browser($self);
        $self->backend($backend);

        return(undef);
    }

    my $browserhost = $self->peerhost();
    my $browserport = $self->peerport();

    my $backendhost = $self->backend->peerhost();
    my $backendport = $self->backend->peerport();

    if ("headers_to_browser" eq $self->state) {
        $self->log("[Sending backend headers: ${backendhost}::$backendport -> ${browserhost}::$browserport]\n");

        my $code = 0;
        my $io = $self->backend->headers;
        my $ws = 0;
        $self->keep_alive(0);
        while(<$io>) {
            my $chop = $_;
            chop($chop);
            chop($chop);
            $self->log("[${backendhost}::$backendport -> ${browserhost}::$browserport -> $chop]\n");
            $self->send($_);

            $code = $1 if m#^HTTP/1.1 (\d+)#;
            $self->keep_alive(1) if m#Connection: keep-alive#;
            $ws = 1 if m#Sec-WebSocket-Accept#;
        }
        $io->setpos(0);

        my $ref = $io->string_ref;

        if (304 == $code) {
            $self->state("headers_from_backend");
            $self->backend->state("iowait");
        }
        elsif (302 == $code) {
            if ($self->keep_alive) {
                $self->state("headers_from_browser");
                $self->backend->state("iowait");
            }
            else {
                $self->state("delete");
                $self->backend->state("delete");
                $self->inprocess("delete");
                $self->backend->inprocess("delete");
            }
        }
        elsif (206 == $code) {
            $self->state("iowait");
            $self->backend->state("pipe");
        }
        elsif (500 == $code) {
            $self->state("iowait");
            $self->backend->state("pipe");
        }
        elsif (404 == $code) {
            $self->state("iowait");
            $self->backend->state("pipe");
        }
        elsif (200 == $code) {
            $self->state("iowait");
            $self->backend->state("pipe");
        }
        elsif ($ws) {
            $self->websocket(1);
            $self->backend->websocket(1);
            $self->state("websocket");
            $self->backend->state("websocket");
        }
        elsif (0 != length($$ref)) {
            while(<$io>) {
                warn($_);
            }
            die;
        }
    }

    if ("post_to_backend" eq $self->state) {
        my $buf;

        if ($self->content_length) {
            my $log = 1;
            my $bytes = 0;
            while(defined $self->recv($buf, $self->content_length > 1024 ? 1024 : $self->content_length)) {
                last if 0 == length($buf);

                $self->logf("[Sending backend post (%d): ${browserhost}::$browserport -> ${backendhost}::$backendport]\n", length($buf)) if $log;
                $log = 0;

                $bytes += length($buf);

                $self->backend->send($buf);

                last if length($buf) == $self->content_length;
                last if $bytes == $self->content_length;
            }
        }

        $self->logf("[No more post: ${browserhost}::$browserport -> ${backendhost}::$backendport]\n", length($buf));

        $self->state("iowait");
        $self->backend->state("headers_from_backend");
    }

    if ("websocket" eq $self->state) {
        my $bytes = 0;

        my $buf;

        $self->recv($buf, 128, Socket::MSG_DONTWAIT);
        if ($buf) {
            $self->logf("[Sending browser websocket (%d :: %d): ${browserhost}::$browserport -> ${backendhost}::$backendport]\n", $bytes, length($buf));

            $bytes += length($buf);

            $self->backend->send($buf);
        }

        $self->logf("[No more websocekt packets ($bytes): ${browserhost}::$browserport -> ${backendhost}::$backendport]\n");
    }

    return(undef);
}

package main;

use IO::Socket::INET;
use IO::String;
use Socket qw();

my $proxy = IO::Socket::INET::Proxy->new(
    LocalAddr => 'localhost',
    LocalPort => 3152,
    Listen    => 1,
    Reuse => 1,
    Proto => 'tcp',
    Blocking => 0,
);

die "Could not create socket: $!\n" unless $proxy;

my $app = { host => "localhost", port => 3000 };

our %session = ();
$session{$proxy} = {};

our %inprocess = ();

use Event::Lib;

my $main = event_new($proxy, EV_READ|EV_PERSIST, \&proxy);
$main->add;

event_mainloop();

sub proxy {
   my $proxy = shift->fh;

    my $browser = $proxy->accept("IO::Socket::INET::Browser");
    if ($browser) {
        $session{$browser}->{obj} = $browser;
        $browser->state("headers_from_browser");
        $browser->blocking(0);

        my $event = event_new($browser, EV_READ|EV_PERSIST, \&event);
        $session{$browser}->{event} = $event;
        $event->add;
    }
}

sub websocket {
   my $event = shift;
   my $fh = $event->fh;

   $fh->process;
}

sub event {
    my $e = shift;
    my $type = shift;
    my $h = $e->fh;

    while (my $state = $h->state) {
        if ("iowait" eq $state) {
            my $browser = $h->can("browser");

            if ($browser) {
                $h->browser->process;
                # event_new($h->browser, EV_TIMEOUT, \&main::event)->add(0.01);
            }
            else {
                $h->backend->process;
                # event_new($h->backend, EV_TIMEOUT, \&main::event)->add(0.01);
            }

            last;
        } elsif ("delete" eq $state) {
            event_new($h, EV_TIMEOUT, \&main::cull_session)->add(0.1);
            last;
        }
        else {
            $Devel::Trace::TRACE = 0;
            $h->process;
            $Devel::Trace::TRACE = 1;
        }
    }
}

sub inprocess {
    my @inprocess = keys %inprocess;
    foreach my $key (@inprocess) {
        my $fh = $session{$key}{obj};
        # my $event = $session{$key}{event};
        
        next if "iowait" eq $fh->state;

        if ($fh->websocket) {
            # $event->remove;
            my $browser = $fh->can("browser");
            my $backend = $fh->can("backend");

            if ($browser) {
                $fh->inprocess(0);
                $fh->browser->inprocess(0);
            }
            elsif ($backend) {
                $fh->inprocess(0);
                $fh->backend->inprocess(0);
            }
            my $ws = event_new($fh, EV_READ|EV_PERSIST, \&websocket);
            $ws->add;

            return;
        }

        $fh->process;
    }
    return(scalar(@inprocess));
}

sub cull_session {
    my %delete = ();

    foreach my $key (keys %session) {
        next unless $session{$key}{state};

        if ("delete" eq $session{$key}{state}) {
            $session{$key}{event}->remove;
            $delete{$key} = 1;
        }
    } 

    foreach my $key (keys %delete) {
        $session{$key}{obj}->shutdown(Socket::SHUT_RDWR);
        # $session{$key}{obj}->flush();
        # $session{$key}{obj}->close();
        delete $session{$key};
    }

    if (keys %delete) {
        foreach my $key (keys %session) {
            foreach my $type (qw(browser backend)) {
                if ($session{$key}{$type}) {
                    if ($delete{$session{$key}{$type}}) {
                        $session{$key}{$type} = undef;
                        delete $session{$key}{$type};
                    }
                }
            }
        }
    }
}

sub dumper {
    require Data::Dumper;
    $Data::Dumper::Useqq = 1;
    $Data::Dumper::Useqq = 1;

    print Data::Dumper::Dumper(\@_);
}

1;
