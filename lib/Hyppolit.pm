package Hyppolit;
use Moses;
use warnings FATAL => 'all';
use 5.008005;

#
# TODO
#
# welcome message to any new user
# logging
# daemonize
# svn commit messages (via svn db)
# pastebot integration
# keep history? (comment by Getty: what you mean?)
# "adult"word check
#

#
# DONE
#
# karma nick (nick++ / nick--)
# add trusted users (trust nick)
#     only allow trusting nick that is currently logged in?
#     allow setting trust for anyone with +o ? (or as it is now only already trusted nicks?)
# svn commit messages (via file)
# trac changes messages
# reacting on public ticket number or changeset (r1 or #1)
# calcbot functionality (word is / word is also / word?)
# logging irc (via POE::Component::IRC::Plugin::Logger)
#

# When it gets OP bit it should go over all the current nicks and add ops to the trusted people
# oh actually I think it can just rty to add ops to every trusted person and it will give only to those who
# have no OP yet
# Also check that it can give op when someone changs alias to a trusted one

our $VERSION = '0.06';

use MooseX::Storage;

use POE::Component::IRC::Plugin::Logger;
use POE::Component::IRC::Plugin::FollowTail;
use DBI;

use Data::Dumper;

with Storage(
	format => 'YAML',
	io => 'AtomicFile',
);

#####################################################################

has svnlook => ( is => 'rw', isa => 'Maybe[Str]', default => sub { '/usr/bin/svnlook' } );
has logdir => ( is => 'rw', isa => 'Maybe[Str]' );
has svninputfile => ( is => 'rw', isa => 'Maybe[Str]' );
has tracdb => ( is => 'rw', isa => 'Maybe[Str]' );
has tracurl => ( is => 'rw', isa => 'Maybe[Str]', default => sub { 'http://padre.perlide.org/trac/' } );
has repo => ( is => 'rw', isa => 'Maybe[Str]' );

#####################################################################

has last_trac_check => ( is => 'rw', isa => 'Int', default => sub { 0 } );
has trusted => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has karma => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has calc => ( is => 'rw', isa => 'HashRef', default => sub { {} } );

#####################################################################

has tracdbh => (
	is => 'rw', isa => 'DBI::db', lazy => 1,
	traits => ['DoNotSerialize'],
	default => sub {
		my $self = shift;
		if ($self->tracdb) {
			DBI->connect("dbi:SQLite:dbname=".$self->tracdb,"","");
		}
	},
);

# dont store specific MooseX Role attributes
has [ '+_irc', '+configfile', '+logger', '+plugins', '+ARGV', '+extra_argv', '+use_logger_singleton' ] => (
	traits => ['DoNotSerialize'],
);

around 'pack' => sub {
	my ($next, $self) = @_;
	my $hash = $self->$next(@_);
	delete $hash->{__CLASS__};
	return $hash;
};

####################################################################

sub custom_plugins {
	my $self = shift;
	my %custom_plugins;
	if ($self->logdir) {
		$custom_plugins{'Logger'} = POE::Component::IRC::Plugin::Logger->new(
			Path         => $self->logdir,
			Private      => 0,
			Public       => 1,
# Restricted => 0,   #did not help
			Sort_by_date => 1,
		);
		system "chmod -R 755 ".$self->logdir; # TODO move to a better place
	}
	if ($self->svninputfile) {
		$custom_plugins{'FollowTail'} = POE::Component::IRC::Plugin::FollowTail->new( 
			filename => $self->svninputfile,
		);
	}
	return \%custom_plugins;
}

sub save {
	my ($self) = @_;
	$self->store( $self->configfile->stringify );
}

sub BUILD {
	my $self = shift;

	if ($self->tracdb) {
		POE::Kernel->delay(trac_check => 5);
	}
}

event irc_public => sub {
	my $self = $_[OBJECT];
	my $nick = (split /!/, $_[ARG0])[0];
	my $channel = $_[ARG1];

	my $text = $_[ARG2];
	
	$self->debug("Nick $nick on channel @$channel said the following: '$text'");

	my $nickname = $self->irc->nick_name;

	# check for trust
	if ($text =~ /^\s*  $nickname \s* [,:]? \s* trust  \s+  (.*)/x ) {
		$self->debug("trust '$1'");
		if ( $self->trusted->{$nick} ) {
			foreach my $n (split /\s*[ ,]\s*/, $1) {
				if ( $self->trusted->{$n} ) {
					$self->privmsg( $channel => "$n was already trusted");
				} else {
					$self->trusted->{$n} = 1;
					$self->privmsg( $channel => "Consider $n trusted");
				}
				$self->set_op($channel, $n);
			}
			$self->save;
		}
	}
	
	# calcbot functionality
	if ($text =~ /^\s*  $nickname \s* [,:]? \s* (\S+)  \s+ is \s+ also \s+ (.*)/x ) {
		my $word = $1;
		$self->calc->{$word} .= " and also $2";
		$self->privmsg( $channel => "$word is now ".$self->calc->{$word} );
		$self->save;
	} elsif ($text =~ /^\s*  $nickname \s* [,:]? \s* (\S+)  \s+ is \s+ (.*)/x ) {
		my $word = $1;
		my $was = $self->calc->{$word} || 'unknown';
		$self->calc->{$word} = $2;
		$self->save;
		$self->privmsg( $channel => "$word was $was" );
		$self->privmsg( $channel => "$word is now $self->calc->{$word}" );
	} elsif ($text =~ /^\s*  (\S+)\?  \s*$/x ) {
		if ($1 eq $nickname ) {
			$self->privmsg( $channel => "$nickname is a bot currently running version $VERSION. My master is szabgab." );
		} elsif ($self->calc->{$1}) {
			$self->privmsg( $channel => "$1 is $self->calc->{$1}" );
		} else {
			#$self->privmsg( $channel => "I don't know what $1 is" );
		}
	}

	# regexp need adjusting, i'm bad at it ;)...
	if ($text =~ /\#(\d+)/x) {
		if ($1+0 > 0) {
			my $text = $self->trac_ticket_text($1);
			$self->privmsg( $channel => $text ) if $text;
		}
	}

	# regexp need adjusting, i'm bad at it ;)...
	if ($text =~ /r(\d+)/x) {
		# no check at all... TODO
		$self->privmsg( $channel => $self->trac_changeset_text($1)) if $1+0 > 0;
	}

	# TODO karma only users who are around ?
	# record karma
	if ($text =~ /(\S+)(\+\+|--)/) {
		my ($nick, $karma) = ($1, $2);
		if ($karma eq '++') {
			$self->karma->{$nick}++;
		} else {
			$self->karma->{$nick}--;
		}
		$self->save;
	}

	if ($text =~ /^\s* karma \s+ (\S+) \s*$/x) {
		my $karma = $self->karma->{$1} || 0;
		$self->privmsg( $channel => "Karma of $1 is $karma");
	}
};

event irc_msg => sub {
	my $self = $_[OBJECT];
	my $nick = (split /!/, $_[ARG0])[0];
	my $text = $_[ARG2];

	$self->debug("Nick $nick said to me '$text'");
};

event irc_join => sub {
	my $self = $_[OBJECT];
	my $nick = (split /!/, $_[ARG0])[0];
	my $channel = $_[ARG1];

	# only send the message if we were the one joining
	if ($nick eq $self->nickname) {
		#$self->privmsg( $channel => "Hi everybody! I am $self->nickname, your bot butler ($VERSION)" );
	}

	# TODO for now it is on every channel
	# but it should work with some database
	
	if ( $self->trusted->{$nick} ) {
		$self->set_op($channel, $nick);
	}
};

sub set_op {
	my ($self, $channel, $nick) = @_;
	if (ref $channel and ref($channel) eq 'ARRAY') {
		($channel) = @$channel;
	}
	$self->debug("Giving op to '$nick' on '$channel'");
	$self->mode( $channel => "+o $nick" );
}

# dont get sense ;) help
#sub _default {
#	my $nick = (split /!/, $_[ARG0])[0];
#	$self->debug("Default: $nick ", scalar(@_), "\n");
#}

event irc_all => sub {
	my $nick = (split /!/, $_[ARG0])[0];
	print "All: $nick ", scalar(@_), "\n";
};

event irc_tail_input => sub {
	my ($self, $kernel, $sender, $filename, $input) = @_[OBJECT, KERNEL, SENDER, ARG0, ARG1];
	return if not $self->repo;
	if ($input =~ /^SVN (\d+)$/) {
		my $id = $1;
		my $author = qx{$self->svnlook author $self->repo -r $id};
		chomp $author;
		$self->karma->{$author}++;
		my $log    = qx{$self->svnlook log $self->repo -r $id};
		my @dirs   = qx{$self->svnlook dirs-changed $self->repo -r $id};
		chomp @dirs;
		my $msg    = "svn: r$id | $author++ | ".$self->tracurl."changeset/$id\n";
		$self->privmsg( $_ => $msg ) for @{ $self->channels };
		foreach my $line (split /\n/, $log) {
			$self->privmsg( $_ => "     $line" ) for @{ $self->get_channels };
		}
		my $dirs = join " ", @dirs;
		$self->privmsg( $_, "     $dirs" ) for @{ $self->get_channels };
	}
	# TODO report error ?
	# $kernel->post( $sender, 'privmsg', $_, "$config->{inputfile} $input" ) for @{ $config->{channels} };
	return;
};

# TODO - maybe unnecessary if switched to SVN::Client
#sub irc_tail_error {
#	my ($kernel, $sender, $filename, $errnum, $errstring)
#		= @_[KERNEL, SENDER, ARG0 .. ARG2];
#	$kernel->post( $sender, 'privmsg', $_, "SVN ERROR: $errnum $errstring" ) for @{ $config->{channels} };
#	$irc->plugin_del( 'FollowTail' );
#	return;
#}

# TODO - maybe unnecessary if switched to SVN::Client
#sub irc_tail_reset {
#	my ($kernel, $sender, $filename) = @_[KERNEL, SENDER, ARG0];
#	$kernel->post( $sender, 'privmsg', $_, "$config->{inputfile} RESET EVENT" ) for @{ $config->{channels} };
#	return;
#}

sub trac_changeset_text {
	my $self = shift;
	return if !$self->tracurl;
	my $changeset_id = shift;
	return "Changeset #".$changeset_id." ".$self->tracurl."changeset/".$changeset_id;
}

sub trac_ticket_text {
	my $self = shift;
	return if !$self->tracurl;
	return if !$self->tracdb;
	my $ticket_id = shift;
	my $ticket = $self->tracdbh->selectrow_hashref("
		select * from ticket
			where id = ?
	", {}, $ticket_id);
	return if !$ticket;
	my $ticket_comment = $self->tracdbh->selectrow_hashref("
		select oldvalue from ticket_change
			where ticket = ? and field = 'comment'
			order by time desc
	", {}, $ticket_id);
	my $url = $self->tracurl."ticket/".$ticket_id;
	$url .= "#comment:".$ticket_comment->{oldvalue} if $ticket_comment and $ticket_comment->{oldvalue};
	return "#".$ticket_id.": ".$ticket->{summary}." (".$ticket->{status}." ".$ticket->{type}.") [ ".$url." ]";
}

event trac_check => sub {
	my $self = $_[OBJECT];
	my $trac_check_time = time;
	my $last_trac_check = $self->last_trac_check;

	my $tickets = $self->tracdbh->selectall_hashref("
		select id from ticket
			where changetime > ? and changetime <= ?
			order by changetime asc
	", "id", {}, $last_trac_check, $trac_check_time);

	for my $ticket_id (keys %{$tickets}) {
		my $text = $self->trac_ticket_text($ticket_id);
		if ($text) {
			$self->privmsg( $_ => $text ) for @{ $self->channels };
		}
	}

	$self->last_trac_check($trac_check_time);
	$self->save;
	POE::Kernel->delay(trac_check => 15);
	return;
};

1;


