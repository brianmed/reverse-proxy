#!/opt/perl

use strict;
use warnings;

use feature qw(:5.16);

use IO::Socket::INET;
use IO::Socket::INET::Proxy;
use IO::Socket::INET::Browser;
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

# my $timer = timer_new(\&inprocess);
# $timer->add(0.04);

# event_mainloop();

while (1) {
    event_one_loop();
    
    inprocess();
}

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

    $h->process;
}

sub inprocess {
    my $e = shift;

    my @inprocess = ();

    while (1) {
        @inprocess = keys %inprocess;
        my $once = 0;
        foreach my $key (@inprocess) {
            my $fh = $session{$key}{obj};
            my $event = $session{$key}{event};

            next if "iowait" eq $fh->state;

            if ($fh->websocket) {
                $event->remove;
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

            my $old_state = $fh->state;
            $fh->process;
            my $new_state = $fh->state;

            if ($old_state ne $new_state) {
                $once = 1;
            }
        }

        last if 0 == $once;
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
