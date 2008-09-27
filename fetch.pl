#! /usr/bin/perl

# Fetch daemon.

use strict;
use warnings;

use Fcntl qw/LOCK_EX/;
use IO::Socket::INET;
use IO::Handle;

use CSplat::Config qw/$FETCH_PORT/;
use CSplat::Ttyrec qw/update_fetched_games clear_cached_urls fetch_ttyrecs
                      record_game/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Select qw/interesting_game/;
use CSplat::DB qw/open_db/;
use CSplat::Xlog qw/xlog_line xlog_str desc_game/;

use POSIX;

my $LOCK_FILE = '.fetch.lock';
my $LOG_FILE = '.fetch.log';
my $LOCK_HANDLE;

my $lastsync;

local $| = 1;

acquire_lock();
daemonize();
run_fetch();

sub daemonize {
  print "Starting fetch server\n";

  my $pid = fork;
  exit if $pid;
  die "Failed to fork: $!\n" unless defined $pid;

  setsid;
  open my $logf, '>', $LOG_FILE or die "Can't write $LOG_FILE: $!\n";
  $logf->autoflush;
  open STDOUT, '>&', $logf or die "Couldn't redirect stdout\n";
  open STDERR, '>&', $logf or die "Couldn't redirect stderr\n";
  STDOUT->autoflush;
  STDERR->autoflush;
}

sub acquire_lock {
  my $failmsg =
    "Failed to lock $LOCK_FILE: another fetch daemon may be running\n";
  eval {
    local $SIG{ALRM} =
      sub {
        die "alarm\n";
      };
    alarm 3;

    open $LOCK_HANDLE, '>', $LOCK_FILE or die "Couldn't open $LOCK_FILE: $!\n";
    flock $LOCK_HANDLE, LOCK_EX or die $failmsg;
  };
  die $failmsg if $@ eq "alarm\n";
}

sub sync_games {
  my $now = time();
  if (!$lastsync || $now - $lastsync > 5) {
    update_fetched_games();
    $lastsync = $now;
  }
}

sub run_fetch {
  open_db();
  sync_games();

  my $server = IO::Socket::INET->new(LocalPort => $FETCH_PORT,
                                     Type => SOCK_STREAM,
                                     Reuse => 1,
                                     Listen => 5)
    or die "Couldn't open server socket on $FETCH_PORT: $@\n";

  while (my $client = $server->accept()) {
    sync_games();
    eval {
      process_command($client);
    };
    warn "$@" if $@;
  }
}

sub process_command {
  my $client = shift;
  my $command = <$client>;
  chomp $command;
  my ($cmd) = $command =~ /^(\w+)/;
  return unless $cmd;

  if ($cmd eq 'G') {
    my ($game) = $command =~ /^\w+ (.*)/;
    fetch_game($client, $game)
  }
  elsif ($cmd eq 'CLEAR') {
    clear_cached_urls();
    print $client "OK\n";
  }
}

sub fetch_game {
  my ($client, $g) = @_;

  print "Requested download: $g\n";

  $g = xlog_line($g);

  my $start = $g->{start};
  my $nocheck = $g->{nocheck};
  delete $g->{nocheck};
  delete @$g{qw/start nostart/} if $g->{nostart};
  my $result = fetch_ttyrecs($g, $nocheck);
  $g->{start} = $start;
  if ($result) {
    print "Downloaded ttyrecs for ", desc_game($g), "\n";
    record_game($g, interesting_game($g) || 0);
    tty_frame_offset($g, 1);
    print $client "OK " . xlog_str($g, 1) . "\n";
  } else {
    print $client "FAIL\n";
  }
}