package IO::Socket::INET::Proxy;

use strict;
use warnings;

use parent qw(IO::Socket::INET IO::Socket::Util);

sub accept {
    my $self = shift;

    my $browser = $self->SUPER::accept(@_);

    if ($browser) {
        # warn("$browser");
        my $peerhost = $browser->peerhost();
        my $peerport = $browser->peerport();
        $self->log("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
        print("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
        $browser->log("[Accepted New Browser Connection From : $peerhost, $peerport]\n");
    }

    return($browser);
}

1;
