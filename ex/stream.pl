#!/usr/bin/env perl
use strict;
use warnings;

use AnyEvent;
use AnyEvent::MtGox::Stream;
use Carp qw(croak);
use Data::Dump;

my $timeout = shift || 0;

binmode STDOUT, ':encoding(utf-8)';

my $cv = AE::cv;

my $client = AnyEvent::MtGox::Stream->new(
    # secure        => 1,
    on_error      => sub { croak(@_) },
    on_disconnect => sub { croak("Disconnected") },
    on_message    => sub { dd(shift) },
);

my $timer = AE::timer $timeout, 0, sub { undef $client; $cv->send }
    if $timeout;

$cv->recv;
