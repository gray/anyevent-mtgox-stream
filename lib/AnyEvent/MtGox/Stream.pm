package AnyEvent::MtGox::Stream;

use strict;
use warnings;

use AnyEvent;
use AnyEvent::HTTP qw(http_post);
use AnyEvent::Util qw(guard);
use Carp qw(croak);
use Errno qw(EPIPE);
use JSON ();
use Protocol::WebSocket::Frame;
use Protocol::WebSocket::Handshake::Client;
use URI;

our $VERSION = '0.02';
$VERSION = eval $VERSION;

sub new {
    my ($class, %params) = @_;

    my $secure        = $params{secure}        || 0;
    my $on_disconnect = $params{on_disconnect} || sub { croak 'Disconnected' };
    my $on_error      = $params{on_error}      || sub { croak @_ };
    my $on_message    = $params{on_message}    || sub { };

    my $server = 'socketio.mtgox.com';
    my $handle;

    # Socket.IO handshake.
    my $uri = URI->new("http://$server/socket.io/1");
    $uri->scheme('https') if $secure;
    AE::log debug => "Making Socket.IO handshake to $uri";
    http_post $uri, undef, sub {
        my ($body, $headers) = @_;
        return $on_error->('Socket.IO handshake failed')
            unless '200' eq $headers->{Status} and defined $body;
        my ($sid, $heartbeat) = split ':', $body, 3;
        AE::log debug => "Socket.IO handshake succeeded: $sid";

        my $timer;
        $handle = AnyEvent::Handle->new(
            connect  => [ $uri->host, $uri->port ],
            tls      => $secure ? 'connect' : undef,
            on_error => sub {
                my ($handle, $fatal, $msg) = @_;
                $handle->destroy;
                undef $timer;
                $!{EPIPE} == $! ? $on_disconnect->() : $on_error->($msg);
            },
        );

        # WebSocket handshake.
        $uri->path("/socket.io/1/websocket/$sid");
        $uri->scheme($secure ? 'wss' : 'ws');
        AE::log debug => "Making WebSocket handshake to $uri";
        my $wsh = Protocol::WebSocket::Handshake::Client->new(url => "$uri");
        $handle->push_write($wsh->to_string);

        $handle->push_read(sub {
            $wsh->parse($handle->rbuf)
                or return 1, $on_error->($wsh->error);
            if ($wsh->is_done) {
                AE::log debug => 'WebSocket handshake succeeded';
                return 1;
            }
        });

        my $frame = Protocol::WebSocket::Frame->new;
        my $send_message = sub {
            $handle->push_write($frame->new(@_)->to_bytes);
        };
        my $send_heartbeat = sub {
            AE::log debug => 'Sending heartbeat';
            $send_message->('2::');
        };

        $timer = AE::timer $heartbeat - 2, $heartbeat - 2, $send_heartbeat
            if $heartbeat;

        my $json = JSON->new;

        $handle->push_read(sub {
            $frame->append($handle->rbuf);
            while (defined(my $msg = $frame->next)) {
                my ($type, $id, $endpoint, $data) = split ':', $msg, 4;
                if ('4' eq $type and '/mtgox' eq $endpoint) {
                    if (my $scalar = eval { $json->decode($data) }) {
                        $on_message->($scalar);
                    }
                }
                # Respond to heartbeats only if a heartbeat timeout wasn't
                # given in the handshake.
                elsif ('2' eq $type and not $heartbeat) {
                    $send_heartbeat->();
                }
                elsif ('1::' eq $msg) { $send_message->('1::/mtgox') }
                elsif ('0' eq $type)  { return 1, $on_disconnect->() }
                elsif ('7' eq $type)  { return 1, $on_error->($data) }

                # Unhandled message types:
                #   3: message
                #   5: event
                #   6: ack
                #   8: noop
            }
        });
    };

    return unless defined wantarray;
    return guard { $handle->destroy };
}

1;

__END__

=head1 NAME

AnyEvent::MtGox::Stream - AnyEvent client for the MtGox streaming API

=head1 SYNOPSIS

    use AnyEvent::MtGox::Stream;

    my $client = AnyEvent::MtGox::Stream->new(
        on_message    => sub { },
        on_error      => sub { },
        on_disconnect => sub { },
    );

=head1 DESCRIPTION

The C<AnyEvent::MtGox::Stream> module is an C<AnyEvent> client for the MtGox
streaming API.

=head1 METHODS

=head2 new

    $client = AnyEvent::MtGox::Stream->new(%args)

Creates a new client and returns a guard object if called in non-void context.
When it is destroyed, it closes the stream.

The following named arguments are accepted:

=over

=item B<secure>

Use HTTPS for securing network traffic. (default: 0)

=item B<on_message>

Callback to execute for each message.

=item B<on_error>

Callback to execute on error.

=item B<on_disconnect>

Callback to execute on disconnect.

=back

=head1 SEE ALSO

L<AnyEvent>

L<https://en.bitcoin.it/wiki/MtGox/API#Streaming_API>

L<https://github.com/LearnBoost/socket.io-spec>

=head1 REQUESTS AND BUGS

Please report any bugs or feature requests to
L<http://rt.cpan.org/Public/Bug/Report.html?Queue=AnyEvent-MtGox-Stream>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc AnyEvent::MtGox::Stream

You can also look for information at:

=over

=item * GitHub Source Repository

L<http://github.com/gray/anyevent-mtgox-stream>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/AnyEvent-MtGox-Stream>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/AnyEvent-MtGox-Stream>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/Public/Dist/Display.html?Name=AnyEvent-MtGox-Stream>

=item * Search CPAN

L<http://search.cpan.org/dist/AnyEvent-MtGox-Stream/>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 gray <gray at cpan.org>, all rights reserved.

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 AUTHOR

gray, <gray at cpan.org>

=cut
