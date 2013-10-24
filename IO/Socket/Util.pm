package IO::Socket::Util;

use strict;
use warnings;

use Time::HiRes;
use POSIX qw();

sub recv_headers {
    my $self = shift;

    my $peerhost = $self->peerhost();
    my $peerport = $self->peerport();

    my $io = $self->headers;
    my $ref = $io->string_ref;

    # $self->log("[Receiving headers: $peerhost::$peerport]\n") unless $io->getpos;

    my $buf;
    while(defined $self->recv($buf, 128)) {
        last if 0 == length($buf);

        $io->print($buf);

        last if $$ref =~ m#\015\012\015\012#;
        # last;
    }

    return($io) if $$ref !~ m#\015\012\015\012#;

    $self->log("[Printing headers: $peerhost::$peerport]\n");

    $io->setpos(0);

    while (<$io>) {
        my $line = $_;
        my $chop = $line;
        chop($chop);
        chop($chop);
        $chop ||= "_END_";
        $self->log("[${peerhost}::$peerport -> $chop]\n");
        last if $line =~ m/^\s*$/;

        if ($line =~ m/Content-Length: (\d+)/) {
            $self->content_length($1);
        }
    }

    $io->setpos(0);

    $self->log("[** No headers **]\n") if 0 == length($$ref);
    
    return($io);
}

my $dir;

BEGIN {
    foreach (1 .. 1001) {
        die if 1001 == $_;

        my $num = sprintf("%03d", $_);
        $dir = POSIX::strftime("log/%F.$num", localtime(time));
        next if -d $dir;

        last;
    }
};

sub log {
    my $self = shift;

    my ($seconds, $microseconds) = Time::HiRes::gettimeofday;

    mkdir $dir unless -d $dir;

    $self->log_file("$$.$seconds.$microseconds." . $self->fileno);
    my $file = $self->log_file;

    open(my $fh, ">>", "$dir/$file") or die("error: open: $dir/$file: $!");
    print($fh "$seconds.$microseconds: ");
    print($fh @_);

    # print("$seconds.$microseconds: ");
    # print(@_);

    close($fh);
}

sub logf {
    my $self = shift;

    my ($seconds, $microseconds) = Time::HiRes::gettimeofday;

    mkdir $dir unless -d $dir;

    $self->log_file("$$.$seconds.$microseconds." . $self->fileno);
    my $file = $self->log_file;

    open(my $fh, ">>", "$dir/$file") or die("error: open: $dir/$file: $!");
    print($fh "$seconds.$microseconds: ");
    printf($fh @_);

    # print("$seconds.$microseconds: ");
    # printf(@_);
    close($fh);
}

sub log_file {
    my $self = shift;

    my $session = $main::session{$self} //= {};
    
    if (@_) {
        $session->{log_file} = $_[0] if !$session->{log_file};
    }

    return($$session{log_file});
}

1;
