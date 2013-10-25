package IO::Socket::INET::Backend;

use strict;
use warnings;

use parent qw(IO::Socket::INET IO::Socket::Util);

use IO::Socket::INET::Browser;
use Event::Lib;
use IO::String;
use Socket qw();

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

1;
