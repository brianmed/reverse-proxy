package IO::Socket::Util;

use Time::HiRes;
use POSIX qw();

sub recv_headers {
    my $self = shift;

    my $peerhost = $self->peerhost();
    my $peerport = $self->peerport();

    $self->log("[Receiving headers: $peerhost::$peerport]\n");

    my $io = $self->headers(IO::String->new);
    my $ref = $io->string_ref;

    my $buf;
    my $eol = 0;
    # while(defined $self->recv($buf, 1, Socket::MSG_PEEK)) {
    while(defined $self->recv($buf, 1)) {
        last if 0 == length($buf);

        # $self->recv($buf, 1);

        if ($buf =~ m/[\015\012]/) {
            ++$eol;
        }
        else {
            $eol = 0;
        }

        $io->print($buf);

        last if 4 == $eol;
    }

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
    $self = shift;
    return;

    my ($seconds, $microseconds) = Time::HiRes::gettimeofday;

    mkdir $dir unless -d $dir;

    $self->log_file("$$.$seconds.$microseconds." . $self->fileno);
    my $file = $self->log_file;

    open(my $fh, ">>", "$dir/$file") or die("error: open: $dir/$file: $!");
    print($fh "$seconds.$microseconds: ");
    print($fh @_);
    close($fh);
}

sub logf {
    $self = shift;
    return;

    my ($seconds, $microseconds) = Time::HiRes::gettimeofday;

    mkdir $dir unless -d $dir;

    $self->log_file("$$.$seconds.$microseconds." . $self->fileno);
    my $file = $self->log_file;

    open(my $fh, ">>", "$dir/$file") or die("error: open: $dir/$file: $!");
    print($fh "$seconds.$microseconds: ");
    printf($fh @_);
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
