package Mojo::Reactor::POE;
use Mojo::Base 'Mojo::Reactor::Poll';

use POE;
use Mojo::Util 'steady_time';
use Scalar::Util 'weaken';

use constant { POE_IO_READ => 0, POE_IO_WRITE => 1 };
use constant DEBUG => $ENV{MOJO_REACTOR_POE_DEBUG} || 0;

our $VERSION = '0.001';

my $POE;

sub DESTROY { shift->_send_shutdown; undef $POE; }

sub again {
	my ($self, $id) = @_;
	my $timer = $self->{timers}{$id};
	$timer->{time} = steady_time + $timer->{after};
	$self->_send_adjust_timer($id);
}

sub is_running {
	my $session = POE::Kernel->get_active_session;
	return !!($session->ID ne POE::Kernel->ID);
}

sub new {
	my $class = shift;
	if ($POE++) {
		return Mojo::Reactor::Poll->new;
	}
	my $self = $class->SUPER::new;
	$self->_init_session;
	return $self;
}

sub one_tick { shift->_init_session; POE::Kernel->run_one_timeslice; }

sub recurring { shift->_timer(1, @_) }

sub remove {
	my ($self, $remove) = @_;
	return unless defined $remove;
	if (ref $remove) {
		if (exists $self->{io}{fileno $remove}) {
			$self->_send_clear_io(fileno $remove);
		}
		return !!delete $self->{io}{fileno $remove};
	} else {
		if (exists $self->{timers}{$remove}) {
			$self->_send_clear_timer($remove);
		}
		return !!delete $self->{timers}{$remove};
	}
}

sub reset {
	my $self = shift;
	$self->remove($_) for keys %{$self->{timers}};
	$self->remove($self->{io}{$_}{handle}) for keys %{$self->{io}};
}

sub start { shift->_init_session; POE::Kernel->run; }

sub stop { POE::Kernel->stop }

sub timer { shift->_timer(0, @_) }

sub watch {
	my ($self, $handle, $read, $write) = @_;
	
	my $io = $self->{io}{fileno $handle};
	$io->{handle} = $handle;
	$io->{read} = $read;
	$io->{write} = $write;
	$self->_send_set_io(fileno $handle);
	
	warn "-- Set IO watcher for ".fileno($handle)."\n" if DEBUG;
	
	return $self;
}

sub _timer {
	my ($self, $recurring, $after, $cb) = @_;
	$after ||= 0.0001 if $recurring;
	
	my $id = $self->SUPER::_timer($recurring, $after, $cb);
	my $timer = $self->{timers}{$id};
	$self->_send_set_timer($id);
	
	warn "-- Set timer $id after $after seconds\n" if DEBUG;
	
	return $id;
}

sub _session_exists {
	my $self = shift;
	return undef unless defined $self->{session_id};
	if (my $session = POE::Kernel->ID_id_to_session($self->{session_id})) {
		return $session;
	}
	return undef;
}

sub _init_session {
	my $self = shift;
	my $session;
	unless ($session = $self->_session_exists) {
		$session = POE::Session->create(
			package_states => [
				__PACKAGE__, {
					_start				=> '_event_start',
					_stop				=> '_event_stop',
					mojo_set_timer 		=> '_event_set_timer',
					mojo_clear_timer	=> '_event_clear_timer',
					mojo_adjust_timer	=> '_event_adjust_timer',
					mojo_set_io			=> '_event_set_io',
					mojo_clear_io		=> '_event_clear_io',
					mojo_timer			=> '_event_timer',
					mojo_io				=> '_event_io',
					mojo_shutdown		=> '_event_shutdown',
				},
			],
			heap => { mojo_reactor => $self },
		);
		$self->{session_id} = $session->ID;
		weaken $session->get_heap()->{mojo_reactor};
	}
	return $self;
}

sub _send_adjust_timer {
	my ($self, $id) = @_;
	# If session doesn't exist, the time will be set when it starts
	return unless $self->_session_exists;
	POE::Kernel->call($self->{session_id}, mojo_adjust_timer => $id);
}

sub _send_set_timer {
	my ($self, $id) = @_;
	# We need a session to set a timer
	$self->_init_session;
	POE::Kernel->call($self->{session_id}, mojo_set_timer => $id);
}

sub _send_clear_timer {
	my ($self, $id) = @_;
	# If session doesn't exist, the timer won't be re-added
	return unless $self->_session_exists;
	POE::Kernel->call($self->{session_id}, mojo_clear_timer => $id);
}

sub _send_set_io {
	my ($self, $fd) = @_;
	# We need a session to set a watcher
	$self->_init_session;
	POE::Kernel->call($self->{session_id}, mojo_set_io => $fd);
}

sub _send_clear_io {
	my ($self, $fd) = @_;
	# If session doesn't exist, the watcher won't be re-added
	return unless $self->_session_exists;
	POE::Kernel->call($self->{session_id}, mojo_clear_io => $fd);
}

sub _send_shutdown {
	my $self = shift;
	return unless $self->_session_exists;
	POE::Kernel->call($self->{session_id}, 'mojo_shutdown');
}

sub _event_start {
	my $self = $_[HEAP]->{mojo_reactor};
	my $session = $_[SESSION];
	
	warn "-- POE session started\n" if DEBUG;
	
	# Start timers and watchers that were queued up
	if ($self->{queue}{timers}) {
		foreach my $id (@{$self->{queue}{timers}}) {
			POE::Kernel->call($session, mojo_set_timer => $id);
		}
	}
	if ($self->{queue}{io}) {
		foreach my $fd (@{$self->{queue}{io}}) {
			POE::Kernel->call($session, mojo_set_io => $fd);
		}
	}
	undef $self->{queue};
}

sub _event_stop {
	my $self = $_[HEAP]->{mojo_reactor};
	
	warn "-- POE session stopped\n" if DEBUG;
	
	return unless $self;
	
	# POE is killing this session, and we can't make a new one here.
	# Queue up the current timers and IO watchers to be started later.
	$self->{queue} = {
		timers => [keys %{$self->{timers}}],
		io => [keys %{$self->{io}}]
	};
	
	undef $self->{session_id};
}

sub _event_set_timer {
	my ($heap, $id) = @_[HEAP, ARG0];
	my $self = $heap->{mojo_reactor};
	return unless exists $self->{timers}{$id}
		and defined $self->{timers}{$id}{time};
	my $timer = $self->{timers}{$id};
	my $delay_time = $timer->{time} - steady_time;
	my $poe_id = POE::Kernel->delay_set(mojo_timer => $delay_time, $id);
	$timer->{poe_id} = $poe_id;
	
	warn "-- Set POE timer $poe_id in $delay_time seconds\n" if DEBUG;
}

sub _event_clear_timer {
	my ($heap, $id) = @_[HEAP, ARG0];
	my $self = $heap->{mojo_reactor};
	return unless exists $self->{timers}{$id}
		and defined $self->{timers}{$id}{poe_id};
	my $timer = $self->{timers}{$id};
	POE::Kernel->alarm_remove($timer->{poe_id});
	
	warn "-- Cleared POE timer $timer->{poe_id}\n" if DEBUG;
}

sub _event_adjust_timer {
	my ($heap, $id) = @_[HEAP, ARG0];
	my $self = $heap->{mojo_reactor};
	return unless exists $self->{timers}{$id}
		and defined $self->{timers}{$id}{time}
		and defined $self->{timers}{$id}{poe_id};
	my $timer = $self->{timers}{$id};
	my $new_delay = $timer->{time} - steady_time;
	POE::Kernel->delay_adjust($timer->{poe_id}, $new_delay);
	
	warn "-- Adjusted POE timer $timer->{poe_id} to $new_delay seconds\n"
		if DEBUG;
}

sub _event_set_io {
	my ($heap, $fd) = @_[HEAP, ARG0];
	my $self = $heap->{mojo_reactor};
	return unless exists $self->{io}{$fd}
		and defined $self->{io}{$fd}{handle};
	my $io = $self->{io}{$fd};
	if ($io->{read}) {
		POE::Kernel->select_read($io->{handle}, 'mojo_io');
	} else {
		POE::Kernel->select_read($io->{handle});
	}
	if ($io->{write}) {
		POE::Kernel->select_write($io->{handle}, 'mojo_io');
	} else {
		POE::Kernel->select_write($io->{handle});
	}
	
	warn "-- Set POE IO watcher for $fd " .
		"with read: $io->{read}, write: $io->{write}\n" if DEBUG;
}

sub _event_clear_io {
	my ($heap, $fd) = @_[HEAP, ARG0];
	my $self = $heap->{mojo_reactor};
	return unless exists $self->{io}{$fd}
		and defined $self->{io}{$fd}{handle};
	my $io = $self->{io}{$fd};
	POE::Kernel->select_read($io->{handle});
	POE::Kernel->select_write($io->{handle});
	
	warn "-- Cleared POE IO watcher for $fd\n" if DEBUG;
}

sub _event_timer {
	my ($heap, $id) = @_[HEAP,ARG0];
	my $self = $heap->{mojo_reactor};
	
	my $timer = $self->{timers}{$id};
	warn "-- Event fired for timer $id\n" if DEBUG;
	if ($timer->{recurring}) {
		$timer->{time} = steady_time + $timer->{after};
		$self->_send_set_timer($id);
	} else {
		delete $self->{timers}{$id};
	}
	
	$self->_sandbox("Timer $id", $timer->{cb});
}

sub _event_io {
	my ($heap, $handle, $mode) = @_[HEAP, ARG0, ARG1];
	my $self = $heap->{mojo_reactor};
	
	my $io = $self->{io}{fileno $handle};
	#warn "-- Event fired for IO watcher ".fileno($handle)."\n" if DEBUG;
	if ($mode == POE_IO_READ) {
		$self->_sandbox('Read', $io->{cb}, 0);
	} elsif ($mode == POE_IO_WRITE) {
		$self->_sandbox('Write', $io->{cb}, 1);
	} else {
		die "Unknown POE I/O mode $mode";
	}
}

sub _event_shutdown {
	my $self = $_[HEAP]->{mojo_reactor};
	# TODO: remove all I/O watchers at once?
	# we may not have the filehandles here during global destruction
	foreach my $fd (keys %{$self->{io}}) {
		my $handle = $self->{io}{$fd}{handle} // next;
		POE::Kernel->select_read($handle);
		POE::Kernel->select_write($handle);
	}
	POE::Kernel->alarm_remove_all();
}

=head1 NAME

Mojo::Reactor::POE - POE backend for Mojo::Reactor

=head1 SYNOPSIS

  use Mojo::Reactor::POE;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::POE->new;
  $reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

  # Change to watching only if handle becomes writable
  $reactor->watch($handle, 0, 1);

  # Add a timer
  $reactor->timer(15 => sub {
    my $reactor = shift;
    $reactor->remove($handle);
    say 'Timeout!';
  });

  # Start reactor if necessary
  $reactor->start unless $reactor->is_running;

  # Or in an application using Mojo::IOLoop
  BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::POE' }
  use Mojo::IOLoop;

=head1 DESCRIPTION

L<Mojo::Reactor::POE> is an event reactor for L<Mojo::IOLoop> that uses L<POE>.
The usage is exactly the same as other L<Mojo::Reactor> backends such as
L<Mojo::Reactor::Poll>. To set it as the default backend for L<Mojo::Reactor>,
set the C<MOJO_REACTOR> environment variable to C<Mojo::Reactor::POE>. This
must be set before L<Mojo::IOLoop> is loaded.

=head1 EVENTS

L<Mojo::Reactor::POE> inherits all events from L<Mojo::Reactor::Poll>.

=head1 METHODS

L<Mojo::Reactor::POE> inherits all methods from L<Mojo::Reactor::Poll> and
implements the following new ones.

=head2 again

  $reactor->again($id);

Restart active timer.

=head2 io

  $reactor = $reactor->io($handle => sub {...});

Watch handle for I/O events, invoking the callback whenever handle becomes
readable or writable.

=head2 is_running

  my $bool = $reactor->is_running;

Check if reactor is running.

=head2 new

  my $reactor = Mojo::Reactor::POE->new;

Construct a new L<Mojo::Reactor::POE> object.

=head2 one_tick

  $reactor->one_tick;

Run reactor until an event occurs or no events are being watched anymore. Note
that this method can recurse back into the reactor, so you need to be careful.

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

Create a new recurring timer, invoking the callback repeatedly after a given
amount of time in seconds.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

Remove handle or timer.

=head2 reset

  $reactor->reset;

Remove all handles and timers.

=head2 start

  $reactor->start;

Start watching for I/O and timer events, this will block until L</"stop"> is
called or no events are being watched anymore.

=head2 stop

  $reactor->stop;

Stop watching for I/O and timer events.

=head2 timer

  my $id = $reactor->timer(0.5 => sub {...});

Create a new timer, invoking the callback after a given amount of time in
seconds.

=head2 watch

  $reactor = $reactor->watch($handle, $readable, $writable);

Change I/O events to watch handle for with true and false values. Note that
this method requires an active I/O watcher.

=head1 BUGS

L<POE> has a complex session system which may lead to bugs when used in this
manner. Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::IOLoop>, L<POE>

=cut

1;
