package Mojo::Reactor::POE;
use Mojo::Base 'Mojo::Reactor::Poll';

use POE;
use Mojo::Util 'steady_time';
use Scalar::Util 'weaken';

use constant { POE_IO_READ => 0, POE_IO_WRITE => 1 };
use constant DEBUG => $ENV{MOJO_REACTOR_POE_DEBUG} || 0;

my $POE;
my $session_id;

sub DESTROY { undef $POE; }

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

sub _session_exists {
	my $self = shift;
	if ($session_id and my $session = POE::Kernel->ID_id_to_session($session_id)) {
		return $session;
	}
	return undef;
}

sub _init_session {
	my $self = shift;
	my $session;
	if ($session = $self->_session_exists) {
		$session->get_heap()->{mojo_reactor} = $self;
	} else {
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
				},
			],
			heap => { mojo_reactor => $self },
		);
		$session_id = $session->ID;
	}
	weaken $session->get_heap()->{mojo_reactor};
	return $session_id;
}

sub _send_adjust_timer {
	my ($self, $id) = @_;
	# If session doesn't exist, the time will be set when it starts
	return unless $self->_session_exists;
	POE::Kernel->call($session_id, mojo_adjust_timer => $id);
}

sub _send_set_timer {
	my ($self, $id) = @_;
	# We need a session to set a timer
	$self->_init_session;
	POE::Kernel->call($session_id, mojo_set_timer => $id);
}

sub _send_clear_timer {
	my ($self, $id) = @_;
	# If session doesn't exist, the timer will be deleted anyway
	return unless $self->_session_exists;
	my $timer = $self->{timers}{$id};
	POE::Kernel->call($session_id, mojo_clear_timer => $timer->{poe_id});
}

sub _send_set_io {
	my ($self, $fd) = @_;
	# We need a session to set a watcher
	$self->_init_session;
	POE::Kernel->call($session_id, mojo_set_io => $fd);
}

sub _send_clear_io {
	my ($self, $fd) = @_;
	# If session doesn't exist, the watcher will be deleted anyway
	return unless $self->_session_exists;
	my $io = $self->{io}{$fd};
	POE::Kernel->call($session_id, mojo_clear_io => $io->{handle});
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
	
	# POE is killing this session, and we can't make a new one here.
	# Queue up the current timers and IO watchers to be started later.
	$self->{queue} = {
		timers => [keys %{$self->{timers}}],
		io => [keys %{$self->{io}}]
	};
	
	undef $session_id;
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
	my $id = $_[ARG0];
	POE::Kernel->alarm_remove($id);
	
	warn "-- Cleared POE timer $id\n" if DEBUG;
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
	
	warn "-- Adjusted POE timer $timer->{poe_id} to $new_delay seconds\n" if DEBUG;
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
	
	warn "-- Set POE IO watcher for $fd with read: $io->{read}, write: $io->{write}\n" if DEBUG;
}

sub _event_clear_io {
	my $handle = $_[ARG0];
	POE::Kernel->select_read($handle);
	POE::Kernel->select_write($handle);
	
	warn "-- Cleared POE IO watcher for ".fileno($handle)."\n" if DEBUG;
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

1;
