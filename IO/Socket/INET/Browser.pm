package IO::Socket::INET::Browser;

use strict;
use warnings;

use parent qw(IO::Socket::INET IO::Socket::Util);

use IO::Socket::INET::Backend;
use Event::Lib;
use IO::String;
use Socket qw();

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
            event_new($self, EV_TIMEOUT, \&main::cull_session)->add(0.1);
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

        my $peerhost = $backend->peerhost();
        my $peerport = $backend->peerport();
        $self->log("[Connected to Backend with : $peerhost, $peerport]\n");
        print("[Connected to Backend with : $peerhost, $peerport]\n");
        $backend->log("[Connected to Backend with : $peerhost, $peerport]\n");

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

1;
