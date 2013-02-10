=head1 NAME

HuGTFS::Cal - Calendar helper functions used within HuGTFS

=head1 SYNOPSIS

	use HuGTFS::Cal;

=head1 REQUIRES

	perl 5.14.0

=head1 DESCRIPTION

Class for handling services. Currently only a single period for each service_id is supported.

=head1 METHODS

=cut

package HuGTFS::Cal;
use Carp qw/cluck carp/;
use DateTime;
use Digest::JHash qw(jhash);
use Calendar::Simple;

use 5.14.0;
use utf8;
use strict;
use warnings;

use HuGTFS::Util qw/ _0 _D from_ymd /;

use base qw(Class::Accessor);
HuGTFS::Cal->mk_accessors(
	qw(start_date end_date monday tuesday wednesday thursday friday saturday sunday exceptions service_id service_desc)
);

# General service periods
use constant {
	CAL_START            => 20121209,
	CAL_END              => 20131214,
	CAL_TANEV            => '20121209-20130614,20130902-20131214',
	CAL_TANSZUNET_TEL    => '20121221-20130102',
	CAL_TANSZUNET_TAVASZ => '20130328-20130402',
	CAL_TANSZUNET_NYAR   => '20130615-20130901',
	CAL_TANSZUNET_OSZ    => '20131023-20131023',                     # DATEMOD
	CAL_TANSZUNET        => '20121222-20130102,20130328-20130402,20130615-20130901,20131023-20131023',
	CAL_A_TANSZUNET      => '-20121221,20130103-20130327,20130403-20130614,20130902-20131022,20131024-',
};


our @DAYS = (qw/monday tuesday wednesday thursday friday saturday sunday/);

our $COUNTER = 0;

# service cache
my $services = {};
__PACKAGE__->generic_services();

=head2 load

Loads the service cache (after a C<dump>).

=cut

sub load
{
	my ( $class, @services ) = @_;

	my @nservice;
	foreach my $service (@services) {

		#end_date / start_date => new Date(..) ...;
		$service->{start_date} = from_ymd( $service->{start_date} );
		$service->{end_date}   = from_ymd( $service->{end_date} );

		my $cache = {};
		foreach my $exception ( @{ $service->{exceptions} } ) {
			my @date = ( $exception->{date} =~ m/^(\d{4})(\d{2})(\d{2})$/ );
			$cache->{ int( $date[0] ) }->{ int( $date[1] ) }->{ int( $date[2] ) }
				= $exception->{exception_type};
		}
		$service->{exceptions} = $cache;

		bless $service, $class;

		$services->{$service->{service_id}} = $service;
		push @nservice, $service;
	}

	return wantarray ? @nservice : $nservice[0];
}

=head2 dump

Dumps the service cache.

=cut

sub dump
{
	my ($class) = @_;

	if(ref $class) {
		my $service = $class;

		$service->{start_date}
			= $service->{start_date}->year
			. _0( $service->{start_date}->month )
			. _0( $service->{start_date}->day );
		$service->{end_date}
			= $service->{end_date}->year
			. _0( $service->{end_date}->month )
			. _0( $service->{end_date}->day );

		my $real = [];
		foreach my $year ( keys %{ $service->{exceptions} } ) {
			foreach my $month ( keys %{ $service->{exceptions}->{$year} } ) {
				foreach my $day ( keys %{ $service->{exceptions}->{$year}->{$month} } ) {
					push @$real,
						{
						date           => $year . _0($month) . _0($day),
						exception_type => $service->{exceptions}->{$year}->{$month}->{$day}
						};
				}
			}
		}
		$service->{exceptions} = $real;

		return $service;
	} else {
		foreach my $service ( values %$services ) {
			$service->dump();
		}

		return sort { $a->{service_id} cmp $b->{service_id} } values %$services;
	}
}

=head2 empty

Clear the service cache.

=cut

sub empty
{
	$services = {};
   	__PACKAGE__->new( service_id => 'NEVER' );
}

=head2 generic_services

=cut

sub generic_services
{
	my ($class) = @_;
	__PACKAGE__->empty;
	$services = { %$services, 
		map {
			my $o = $_;
			my $s = HuGTFS::Cal->new(
				service_id   => $_->[0],
				service_desc => $_->[8],
				start_date   => CAL_START,
				end_date     => CAL_END,
				map {$DAYS[$_ - 1] => $o->[$_] } (1..7)
			);
			for(@{$_->[9]}) {
				$s->add_exception($_, 'removed');
			}
			for(@{$_->[10]}) {
				$s->add_exception($_, 'added');
			}
			$s->service_id => $s;
		} (
			[qw/NAPONTA            1 1 1 1 1 1 1/,
				'naponta',
				[qw//], # remove
				[qw//], # add
			],
			[qw/MUNKANAPON         1 1 1 1 1 0 0/,
				'munkanapokon',
				[qw/20121224 20121225 20121226 20121231 20130101 20130315 20130401 20130501
					20130520 20130819 20130820 20131023 20131101 /],
				[qw/20121215 20130824 20131207/],
			],
			[qw/SZABADNAPON        0 0 0 0 0 1 0/,
				'szabadnapokon',
				[qw/20121215 20130316 20130824 20131102 20131207 /],
				[qw//],
			],
			[qw/MUNKASZUNETINAPON  0 0 0 0 0 0 1/,
				'munkaszüneti napokon',
				[qw//],
				[qw/20121224 20121225 20121226 20121231 20130101 20130315 20130316 20130401
					20130501 20130520 20130819 20130820 20131023 20131101 20131102 /],
			],
		)
	};

#<<<
	$class->descriptor(['RENAME', [qw/OR SZABADNAPON MUNKASZUNETINAPON/     ], 'HETVEGEN'             , 'szabad- és munkaszüneti napokon']);
	$class->descriptor(['RENAME', ['LIMIT', 'MUNKANAPON',    CAL_TANSZUNET()], 'TANSZUNETI_MUNKANAPON', 'tanszüneti munkanapokon'        ]);
	$class->descriptor(['RENAME', ['LIMIT', 'MUNKANAPON',  CAL_A_TANSZUNET()], 'TANITASI_MUNKANAPON'  , 'tanítási munkanapokon'          ]);
#>>>

	# remove cruft from creating services
	$services = {
		map { $_->service_id => $_ }
			@{$services}{
			qw/NEVER NAPONTA MUNKANAPON SZABADNAPON MUNKASZUNETINAPON HETVEGEN TANSZUNETI_MUNKANAPON TANITASI_MUNKANAPON/
			}
	};
}

=head2 find($service_id)

Returns the object for the specified service_id.

=cut

sub find
{
	my ( $self, $id ) = @_;
	return $services->{$id};
}

=head2 keep_only($regexp)

Removes services which don't match the provided regexp.

=cut

sub keep_only
{
	my ( $self, $regexp ) = @_;

	foreach (keys %$services) {
		delete $services->{$_} unless m/$regexp/ || $_ eq 'NEVER';
	}
}

=head2 keep_only_named

Removes services which were auto-created.

=cut

sub keep_only_named
{
	my ( $self ) = @_;

	$self->keep_only(qr/^(?!SC_COUNTER_\d+).*$/);
}

=head2 new

Create a new service.

=cut

sub new
{
	my $class = shift;
	my (%fields) = ( ( scalar @_ == 1 ) ? %{ $_[0] } : @_ );
	my $self = {
		start_date   => CAL_START,
		end_date     => CAL_END,
		monday       => 0,
		tuesday      => 0,
		wednesday    => 0,
		thursday     => 0,
		friday       => 0,
		saturday     => 0,
		sunday       => 0,
		service_desc => undef,
		exceptions   => {},
		%fields,
	};

	unless ( $self->{service_id} ) {
		$self->{service_id} = 'SC_COUNTER_' . ++$COUNTER;
	}

	if ( $self->{start_date} && !ref $self->{start_date} ) {
		$self->{start_date} = from_ymd $self->{start_date};
	}
	if ( $self->{end_date} && !ref $self->{end_date} ) {
		$self->{end_date} = from_ymd $self->{end_date};
	}

	$services->{ $self->{service_id} } = $self;

	bless $self, $class;
}

=head2 add_exception($date, $exception);

Add an exception to the service.

=cut

sub add_exception
{
	my ( $self, $date, $type ) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	unless ( ref $date ) {
		$date = from_ymd $date;
	}

	if ( ref $date eq 'ARRAY' ) {
		$self->{exceptions}->{ $date->[0] }->{ int $date->[1] }->{ int $date->[2] } = $type;
	}
	else {
		$self->{exceptions}->{ $date->year }->{ $date->month }->{ $date->day } = $type;
	}
}

=head2 get_exception($date)

Get the exception for a date from the service.

=cut

sub get_exception
{
	my ( $self, $date ) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	unless ( ref $date ) {
		$date = from_ymd $date;
	}

	if ( ref $date eq 'ARRAY' ) {
		return
			   $self->{exceptions}->{ $date->[0] }
			&& $self->{exceptions}->{ $date->[0] }->{ int $date->[1] }
			&& $self->{exceptions}->{ $date->[0] }->{ int $date->[1] }->{ int $date->[2] }
			? $self->{exceptions}->{ $date->[0] }->{ int $date->[1] }->{ int $date->[2] }
			: undef;
	}
	else {
		return
			   $self->{exceptions}->{ $date->year }
			&& $self->{exceptions}->{ $date->year }->{ $date->month }
			&& $self->{exceptions}->{ $date->year }->{ $date->month }->{ $date->day }
			? $self->{exceptions}->{ $date->year }->{ $date->month }->{ $date->day }
			: undef;
	}
}

=head2 remove_exception

Remove an exception from the service.

=cut

sub remove_exception
{
	my ( $self, $date ) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	unless ( ref $date ) {
		$date = from_ymd $date;
	}

	if ( ref $date eq 'ARRAY' ) {
		delete $self->{exceptions}->{ $date->[0] }->{ int $date->[1] }->{ int $date->[2] };
	}
	else {
		delete $self->{exceptions}->{ $date->year }->{ $date->month }->{ $date->day };
	}
}

=head2 enabled($date)

Is the service active on C<$date>.

=cut

sub enabled
{
	my ( $self, $date ) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	if ( ref $date eq 'ARRAY' ) {
		$date = DateTime->new( year => $date->[0], month => $date->[1], day => $date->[2] );
	}
	elsif ( ref $date || !$date ) {
		$date = $date ? $date->clone : DateTime->now;
	}
	else {
		$date = from_ymd $date;
	}

	if (   $self->start_date <= $date
		&& $self->end_date >= $date
		&& $self->{ $DAYS[ $date->day_of_week_0 ] } )
	{
		return !$self->get_exception($date) || $self->get_exception($date) eq 'added';
	}

	return $self->get_exception($date) && $self->get_exception($date) eq 'added';
}

=head2 active_after($date)

is the service active/enabled after the specified date?

=cut

sub active_after
{
	my ( $self, $date ) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	if ( ref $date eq 'ARRAY' ) {
		$date = DateTime->new( year => $date->[0], month => $date->[1], day => $date->[2] );
	}
	elsif ( ref $date || !$date ) {
		$date = $date ? $date->clone : DateTime->now;
	}
	else {
		$date = from_ymd $date;
	}


}


=head2 has_active_day

=cut

sub has_active_day
{
	my ($self) = @_;
	unless ( ref $self ) {
		$self = $services->{$self};
	}

	return $self->has_enabled_day || $self->has_enabled_exception;
}

=head2 has_enabled_exception

=cut

sub has_enabled_exception
{
	my ($self) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	if(scalar keys %{ $self->{exceptions} })
	{
		foreach my $year (keys %{ $self->{exceptions} }) {
			foreach my $month (keys %{ $self->{exceptions}{$year} }) {
				foreach my $day (keys %{ $self->{exceptions}{$year}{$month} }) {
					return 1 if $self->{exceptions}{$year}{$month}{$day} eq 'added';
				}
			}
		}
	}

	return 0;
}

=head2 has_enabled_day

=cut

sub has_enabled_day
{
	my ($self) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	return
		   $self->monday
		|| $self->tuesday
		|| $self->wednesday
		|| $self->thursday
		|| $self->friday
		|| $self->saturday
		|| $self->sunday;
}

=head2 min_date

=cut

sub min_date
{
	my ($self) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	my $date = $self->start_date->clone;
	my $min_date = undef;

	if(scalar keys %{ $self->{exceptions} })
	{
		my $min_year  = ( sort { $a <=> $b } keys %{ $self->{exceptions} } )[0];
		my $min_month = ( sort { $a <=> $b } keys %{ $self->{exceptions}{$min_year} } )[0];
		my $min_day
			= ( sort { $a <=> $b } keys %{ $self->{exceptions}{$min_year}{$min_month} } )[0];
		$min_date = DateTime->new( year => $min_year, month => $min_month, day => $min_day ) if $min_day;
	}

	return !$min_date || ($date < $min_date && $self->has_enabled_day) ? $date : $min_date;
}

=head2 max_date

=cut

sub max_date
{
	my ($self) = @_;

	unless ( ref $self ) {
		$self = $services->{$self};
	}

	my $date = $self->end_date->clone;
	my $max_date = undef;

	if(scalar keys %{ $self->{exceptions} })
	{
		my $max_year  = ( sort { $b <=> $a } keys %{ $self->{exceptions} } )[0];
		my $max_month = ( sort { $b <=> $a } keys %{ $self->{exceptions}{$max_year} } )[0];
		my $max_day
			= ( sort { $b <=> $a } keys %{ $self->{exceptions}{$max_year}{$max_month} } )[0];
		$max_date = DateTime->new( year => $max_year, month => $max_month, day => $max_day ) if $max_day;
	}

	return !$max_date || ($date > $max_date && $self->has_enabled_day) ? $date : $max_date;
}

sub exception_cache
{
	return (shift)->exceptions;
}

# I'm lazy => no service by default, if either has service -> exception
# Cooler magic could be used -> AND [dow-stuff], max(start_date), min(end_date),
# AND (exceptions) ADD; OR exceptions removed

=head2 subtract
=head2 subtract_service(A, B, [C]) -> C

Returns a C service active on days A is active, but B isn't.

=cut

sub subtract { return &subtract_service; }

sub subtract_service
{
	my ( $base, $subtract, $service_ret ) = @_;

	unless ( ref $base ) {
		$base = $services->{$base} if $services->{$base};
	}

	unless ( ref $subtract ) {
		$subtract = $services->{$subtract} if $services->{$subtract};
	}

	unless ( ref $base ) {
		carp "Missing service: $base";
	}

	unless ( ref $subtract ) {
		carp "Missing service: $subtract";
	}

	if ( $service_ret && !ref $service_ret ) {
		if($services->{$service_ret}) {
			$service_ret = $services->{$service_ret};
		} else {
			$service_ret = HuGTFS::Cal->new( service_id => $service_ret );
		}
	}

	my $start = $base->start_date->clone;

	my @days;
	my $exceptions = [ $base->exception_cache, $subtract->exception_cache ];
	while ( $start <= $base->end_date ) {
		if ( $base->enabled($start)
			&& !$subtract->enabled($start) )
		{
			push @days, $start->clone;
		}
		$start->add( days => 1 );
	}
	for (@$exceptions) {
		my $e = $_;

		foreach my $year ( keys %$e ) {
			foreach my $month ( keys %{ $e->{$year} } ) {
				foreach my $day ( keys %{ $e->{$year}->{$month} } ) {
					my $date = DateTime->new(
						year  => $year,
						month => $month,
						day   => $day
					);
					if ( $base->enabled($date) && !$subtract->enabled($date) ) {
						push @days, $date;
					}
				}
			}
		}
	}
	@days = sort @days;

	if ( !@days ) {
		return __PACKAGE__->find('NEVER');
	}

	unless ($service_ret) {
		$service_ret = __PACKAGE__->new;
	}

	$service_ret->service_desc(
		( $base->service_desc || '?' ) . ' SUBTRACT ' . ( $subtract->service_desc || '?' ) );
	$service_ret->start_date( $days[0]->clone );
	$service_ret->end_date( $days[-1]->clone );
	$service_ret->monday(0);
	$service_ret->tuesday(0);
	$service_ret->wednesday(0);
	$service_ret->thursday(0);
	$service_ret->friday(0);
	$service_ret->saturday(0);
	$service_ret->sunday(0);

	for (@days) {
		$service_ret->add_exception( $_, 'added' );
	}
	return $service_ret;
}

=head2 remove
=head2 remove_service(A, B) -> A

Returns service A, with service disabled on days B is active.

=cut

sub remove { return &remove_service; }

sub remove_service
{
	my ( $base, $subtract ) = @_;

	unless ( ref $base ) {
		$base = $services->{$base} if $services->{$base};
	}

	unless ( ref $subtract ) {
		$subtract = $services->{$subtract} if $services->{$subtract};
	}

	unless ( ref $base ) {
		carp "Missing service: $base";
	}

	unless ( ref $subtract ) {
		carp "Missing service: $subtract";
	}

	my $start = $base->start_date->clone;

	my $active = 0;
	while ( $start <= $base->end_date ) {
		if ( $base->enabled($start) )
		{
			if($subtract->enabled($start) ) {
				$base->add_exception($start->clone, 'removed');
			} else {
				$active = 1;
			}
		}
		$start->add( days => 1 );
	}

	unless($active) {
		return __PACKAGE__->find('NEVER');
	}

	return $base;
}

=head2 add
=head2 add_service(A, B) -> A

Returns service A, with service added on days B is active.

=cut

sub add { return &add_service; }

sub add_service
{
	my ( $base, $add ) = @_;

	unless ( ref $base ) {
		$base = $services->{$base};
	}

	unless ( ref $add ) {
		$add = $services->{$add};
	}

	my $start = $base->start_date->clone;

	while ( $start <= $base->end_date ) {
		if ( !$base->enabled($start)
			&& $add->enabled($start) )
		{
			$base->add_exception($start->clone, 'added');
		}
		$start->add( days => 1 );
	}

	return $base;
}

=head2 and
=head2 and_service(A, B, [C]) -> C

Returns a service active on days A and B are both active.

=cut

sub and { return &and_service; }

sub and_service
{
	my ( $service_a, $service_b, $service_ret ) = @_;

	unless ( ref $service_a ) {
		$service_a = $services->{$service_a} if $services->{$service_a};
	}

	unless ( ref $service_b ) {
		$service_b = $services->{$service_b} if $services->{$service_b};
	}

	unless(ref $service_a) {
		carp "Missing service: $service_a";
	}

	unless(ref $service_b) {
		carp "Missing service: $service_b";
	}

	if ( $service_ret && !ref $service_ret ) {
		if($services->{$service_ret}) {
			$service_ret = $services->{$service_ret};
		} else {
			$service_ret = HuGTFS::Cal->new( service_id => $service_ret );
		}
	}

	my ( $from, $to ) = (
		  $service_a->start_date > $service_b->start_date ? $service_a->start_date
		: $service_b->start_date,
		$service_a->end_date < $service_b->end_date ? $service_a->end_date
		: $service_b->end_date
	);

	my $start = $from->clone;

	my @days;
	my $exceptions = [ $service_a->exception_cache, $service_b->exception_cache ];
	while ( $start <= $to ) {
		if (   $service_a->enabled($start)
			&& $service_b->enabled($start) )
		{
			push @days, $start->clone;
		}
		$start->add( days => 1 );
	}

	for (@$exceptions) {
		my $e = $_;

		foreach my $year ( keys %$e ) {
			foreach my $month ( keys %{ $e->{$year} } ) {
				foreach my $day ( keys %{ $e->{$year}->{$month} } ) {
					my $date = DateTime->new(
						year  => $year,
						month => $month,
						day   => $day
					);
					if ( $service_a->enabled($date) && $service_b->enabled($date) ) {
						push @days, $date;
					}
				}
			}
		}
	}
	@days = sort @days;

	if ( !@days ) {
		return __PACKAGE__->find('NEVER');
	}

	unless ($service_ret) {
		$service_ret = __PACKAGE__->new;
	}

	$service_ret->service_desc(
		( $service_a->service_desc || '?' ) . ' AND ' . ( $service_b->service_desc || '?' ) )
		if $service_b->service_desc || $service_a->service_desc;
	$service_ret->start_date( $days[0]->clone );
	$service_ret->end_date( $days[-1]->clone );
	$service_ret->monday(0);
	$service_ret->tuesday(0);
	$service_ret->wednesday(0);
	$service_ret->thursday(0);
	$service_ret->friday(0);
	$service_ret->saturday(0);
	$service_ret->sunday(0);

	for (@days) {
		$service_ret->add_exception( $_, 'added' );
	}
	return $service_ret;
}

=head2 or
=head2 or_service(A, B, [C]) -> C

Returns a service active on days A or B is active.

=cut

sub or { return &or_service; }

sub or_service
{
	my ( $service_a, $service_b, $service_ret ) = @_;

	unless ( ref $service_a ) {
		$service_a = $services->{$service_a} if $services->{$service_a};
	}

	unless ( ref $service_b ) {
		$service_b = $services->{$service_b} if $services->{$service_b};
	}

	unless(ref $service_a) {
		carp "Missing service: $service_a";
	}

	unless(ref $service_b) {
		carp "Missing service: $service_b";
	}

	if ( $service_ret && !ref $service_ret ) {
		if($services->{$service_ret}) {
			$service_ret = $services->{$service_ret};
		} else {
			$service_ret = HuGTFS::Cal->new( service_id => $service_ret );
		}
	}

	my ( $from, $to ) = (
		  $service_a->start_date < $service_b->start_date ? $service_a->start_date
		: $service_b->start_date,
		$service_a->end_date > $service_b->end_date ? $service_a->end_date
		: $service_b->end_date
	);

	my $start = $from->clone;

	my @days;
	my $exceptions = [ $service_a->exception_cache, $service_b->exception_cache ];
	while ( $start <= $to ) {
		if (   $service_a->enabled($start)
			|| $service_b->enabled($start) )
		{
			push @days, $start->clone;
		}
		$start->add( days => 1 );
	}

	for (@$exceptions) {
		my $e = $_;

		foreach my $year ( keys %$e ) {
			foreach my $month ( keys %{ $e->{$year} } ) {
				foreach my $day ( keys %{ $e->{$year}->{$month} } ) {
					my $date = DateTime->new(
						year  => $year,
						month => $month,
						day   => $day
					);
					if ( $service_a->enabled($date) || $service_b->enabled($date) ) {
						push @days, $date;
					}
				}
			}
		}
	}
	@days = sort @days;

	if ( !@days ) {
		return __PACKAGE__->find('NEVER');
	}

	unless ($service_ret) {
		$service_ret = __PACKAGE__->new;
	}

	$service_ret->start_date( $days[0]->clone );
	$service_ret->end_date( $days[-1]->clone );
	$service_ret->service_desc(
		( $service_a->service_desc || '?' ) . ' OR ' . ( $service_b->service_desc || '?' ) )
		if $service_b->service_desc || $service_a->service_desc;
	$service_ret->monday(0);
	$service_ret->tuesday(0);
	$service_ret->wednesday(0);
	$service_ret->thursday(0);
	$service_ret->friday(0);
	$service_ret->saturday(0);
	$service_ret->sunday(0);

	delete $service_ret->{exceptions};

	for (@days) {
		$service_ret->add_exception( $_, 'added' );
	}
	return $service_ret;
}

=head2 limit
=head2 limit_service

Limit service A to between dates B -> C.

=cut

sub limit { return &limit_service; }

sub limit_service
{
	my ( $service, $from, $to ) = @_;
	unless ( ref $service ) {
		$service = $services->{$service} if $services->{$service};
	}

	unless ( ref $service ) {
		carp "Missing service: $service";
	}

	my ( $start, $end ) = ( DateTime->new( _D $from ), DateTime->new( _D $to ) );

	my $nservice = $service->clone;
	$nservice->start_date( $start->clone )
		if $nservice->start_date < $start;
	$nservice->end_date( $end->clone )
		if $nservice->end_date > $end;
	$nservice->{exceptions} = {};

	foreach my $year ( keys %{ $service->{exceptions} } ) {
		foreach my $month ( keys %{ $service->{exceptions}->{$year} } ) {
			foreach my $day ( keys %{ $service->{exceptions}->{$year}->{$month} } ) {
				my $date = DateTime->new(
					year  => $year,
					month => $month,
					day   => $day
				);
				if ( $start->ymd('') <= $date->ymd('') && $date->ymd('') <= $end->ymd('') ) {
					$nservice->add_exception( $date,
						$service->{exceptions}->{$year}->{$month}->{$day} );
				}
			}
		}
	}

	return $nservice;
}

=head2 restrict
=head2 parse_restrict

start -> start of service
end   -> end   of service

restrict -> -date | date- | date-date
	seperator -> ,

=cut

sub restrict { return &parse_restrict; }

sub parse_restrict
{
	my ( $service, $restrict, $start, $end ) = @_;

	$service = HuGTFS::Cal->find($service) unless ref $service;

	$start = $service->start_date->ymd('') unless $start;
	$end   = $service->end_date->ymd('')   unless $end;

	my @limits = split /,/, $restrict;
	map { s/^-/$start-/; s/-$/-$end/; } @limits;

	my ( $first, $last ) = ( ( join ",", @limits ) =~ m/^(\d+)\b.*\b(\d+)$/ );

	my $sid = $service->service_id . "_RP$restrict";
	my $ret_service = __PACKAGE__->new(start_date => $first, end_date => $last);

	foreach my $limit (@limits) {
		$limit =~ m/(\d+)-(\d+)/;
		my $limited = $service->limit( $1, $2 );

		$ret_service->add( $limited );
	}

	return $ret_service;
}

=head2 clone
=head2 clone_service(A [, B])

Copies service A to service B.

=cut

sub clone { &clone_service; }

sub clone_service
{
	my ( $from, $to ) = @_;

	unless ( ref $from ) {
		$from = $services->{$from};
	}

	unless ( $to ) {
		$to = HuGTFS::Cal->new;
	}

	unless ( ref $to ) {
		unless ( HuGTFS::Cal->find($to) ) {
			$to = HuGTFS::Cal->new( service_id => $to );
		}
		else {
			$to = HuGTFS::Cal->find($to);
		}
	}

	$to->monday( $from->monday );
	$to->tuesday( $from->tuesday );
	$to->wednesday( $from->wednesday );
	$to->thursday( $from->thursday );
	$to->friday( $from->friday );
	$to->saturday( $from->saturday );
	$to->sunday( $from->sunday );

	$to->start_date( $from->start_date->clone );
	$to->end_date( $from->end_date->clone );

	$to->service_desc( $from->service_desc );

	$to->exceptions( {} );

	foreach my $year ( keys %{ $from->{exceptions} } ) {
		foreach my $month ( keys %{ $from->{exceptions}->{$year} } ) {
			$to->{exceptions}->{$year}->{$month}
				= { %{ $from->{exceptions}->{$year}->{$month} } };
		}
	}

	return $to;
}

=head2 invert [$service_ret]

Inverts a service, making active on days the original service isn't.

=cut

sub invert
{
	my ( $service, $service_ret ) = @_;

	$service = HuGTFS::Cal->find($service) unless ref $service;

	my ($start, $end) = ( $service->start_date->clone,  $service->end_date->clone);

	if ( $service_ret && !ref $service_ret ) {
		if ( $services->{$service_ret} ) {
			$service_ret = $services->{$service_ret};
		}
		else {
			$service_ret = HuGTFS::Cal->new( service_id => $service_ret, );
		}
	} else {
		$service_ret = __PACKAGE__->new;
	}

	$service_ret->start_date($start);
	$service_ret->end_date($end);

#<<<
	$service_ret->monday   ( $service->monday    ? 0 : 1 );
	$service_ret->tuesday  ( $service->tuesday   ? 0 : 1 );
	$service_ret->wednesday( $service->wednesday ? 0 : 1 );
	$service_ret->thursday ( $service->thursday  ? 0 : 1 );
	$service_ret->friday   ( $service->friday    ? 0 : 1 );
	$service_ret->saturday ( $service->saturday  ? 0 : 1 );
	$service_ret->sunday   ( $service->sunday    ? 0 : 1 );
#>>>

	foreach my $year ( keys %{ $service->{exceptions} } ) {
		foreach my $month ( keys %{ $service->{exceptions}->{$year} } ) {
			foreach my $day ( keys %{ $service->{exceptions}->{$year}->{$month} } ) {
				my $date = DateTime->new(
					year  => $year,
					month => $month,
					day   => $day
				);

				$service_ret->add_exception( $date,
					$service->get_exception($date) eq 'added'
					? 'removed'
					: 'added' )

			}
		}
	}

	return $service_ret;
}

=head2 descriptor

Create a service, with various operators. Returns a service id.

=over 2

=cut

sub descriptor
{
	my ( $self, $descriptor ) = @_;
	cluck '' unless $descriptor;
	my @descriptor = @$descriptor;

	state $OPERATORS = {
		'RENAME' => sub {
			my ( $service, $name, $desc ) = @_;
			$service = resolve_descriptor_service($service);
			$service = $service->clone($name);
			$service->service_desc($desc) if $desc;
			return $service;
		},
		'DESC' => sub {
			my ( $service, $desc ) = @_;
			$service = resolve_descriptor_service($service);
			$service = $service->clone();
			$service->service_desc($desc) if $desc;
			return $service;
		},
		'ADD' => sub {
			my ( $service, @limits ) = @_;
			$service = resolve_descriptor_service($service);

			my @dates;
			for (@limits) {
				push @dates, get_days_for_descriptor($_);
			}

			$service = $service->clone;
			for (@dates) {
				$service->add_exception( $_, 'added' );
			}

			return $service;
		},
		'REMOVE' => sub {
			my ( $service, @limits ) = @_;
			$service = resolve_descriptor_service($service);

			my @dates;
			for (@limits) {
				push @dates, get_days_for_descriptor($_);
			}

			$service = $service->clone;
			for (@dates) {
				$service->add_exception( $_, 'removed' );
			}

			return $service;
		},
		'LIMIT' => sub {
			my ( $service, @limits ) = @_;
			$service = resolve_descriptor_service($service);

			my @services;
			for (@limits) {
				push @services, $service->restrict( $_, CAL_START, CAL_END );
			}

			$service = shift @services;
			while (@services) {
				$service = $service->or( shift @services );
			}

			return $service;
		},
		'INVERT' => sub {
			my $service = resolve_descriptor_service(shift);
			return $service->invert;
		},

		'SERVICE' => sub {
			return __PACKAGE__->new(@_);
		},

		'MAP' => sub {
			return resolve_descriptor_service(shift);
		},
		
		'SUBTRACT' => sub {
			my ($a, $b) = @_;
			$a = resolve_descriptor_service($a);
			$b = resolve_descriptor_service($b);

			return $a->subtract($b);
		},
		
		'AND' => sub {
			my ($a, $b) = @_;
			$a = resolve_descriptor_service($a);
			$b = resolve_descriptor_service($b);

			return $a->and($b);
		},
		
		'OR' => sub {
			my ($a, $b) = @_;
			$a = resolve_descriptor_service($a);
			$b = resolve_descriptor_service($b);

			return $a->or($b);
		},

		'PREV-DAY' => sub {
			my $orig = resolve_descriptor_service(shift);
			my $service = __PACKAGE__->new;

			my $active = 0;
			my ($start, $end) = ($orig->min_date, $orig->max_date);
			while( $start->ymd('') <= $end->ymd('')) {
				if($orig->enabled($start)) {
					unless($active) {
						$service->add_exception($start->clone->add(days => -1), 'added');
					}
					$active = 1;
				} else {
					$active = 0;
				}

				$start->add(days => 1);
			}

			$service->start_date($service->min_date);
			$service->end_date  ($service->max_date);
			return $service;
		},
		'NEXT-DAY' => sub {
			my $orig = resolve_descriptor_service(shift);
			my $service = __PACKAGE__->new;

			my $active = 0;
			my ($start, $end) = ($orig->min_date, $orig->max_date);
			while( $start->ymd('') <= $end->ymd('')) {
				if($orig->enabled($start)) {
					$active = 1;
				} else {
					if($active) {
						$service->add_exception($start, 'added');
					}
					$active = 0;
				}

				$start->add(days => 1);
			}

			$service->start_date($service->min_date);
			$service->end_date  ($service->max_date);
			return $service;
		},
		'FIRST-DAY' => sub {
			my $orig = resolve_descriptor_service(shift);
			my $service = __PACKAGE__->new;

			my $active = 0;
			my ($start, $end) = ($orig->min_date, $orig->max_date);
			while( $start->ymd('') <= $end->ymd('')) {
				if($orig->enabled($start)) {
					unless($active) {
						$service->add_exception($start, 'added');
					}
					$active = 1;
				} else {
					$active = 0;
				}

				$start->add(days => 1);
			}

			$service->start_date($service->min_date);
			$service->end_date  ($service->max_date);
			return $service;
		},
		'LAST-DAY' => sub {
			my $orig = resolve_descriptor_service(shift);
			my $service = __PACKAGE__->new;

			my $active = 0;
			my ($start, $end) = ($orig->min_date, $orig->max_date);
			while( $start->ymd('') <= $end->ymd('')) {
				if($orig->enabled($start)) {
					$active = 1;
				} else {
					if($active) {
						$service->add_exception($start->clone->add(days => -1), 'added');
					}
					$active = 0;
				}

				$start->add(days => 1);
			}

			$service->start_date($service->min_date);
			$service->end_date  ($service->max_date);
			return $service;
		},
	};

	my $operator = shift @descriptor;

	if(ref $self) {
		unshift @descriptor, $self->service_id;
	}
	my $ret = $OPERATORS->{$operator}->(@descriptor);
	unless($ret) {
		cluck Data::Dumper::Dumper( [$operator, @descriptor] );
	}

	return $ret;
}

=back

=cut

sub get_days_for_descriptor
{
	my $txt = shift;
	my @d = split ',', $txt;
	my @dates;

	foreach (@d) {
		if (m/^-(\d{4})(\d\d)(\d\d)$/) {
			$_ = CAL_START . $_;
		}
		if (m/^(\d{4})(\d\d)(\d\d)-$/) {
			$_ = $_ . CAL_END;
		}

		if (m/^(\d{4})(\d\d)(\d\d)-(\d{4})(\d\d)(\d\d)$/) {
			my ( $start, $end ) = (
				DateTime->new( year => $1, month => $2, day => $3 ),
				DateTime->new( year => $4, month => $5, day => $6 )
			);

			while ( $start->ymd('') <= $end->ymd('') ) {
				push @dates, $start->clone;

				$start->add( days => 1 );
			}
		}
		elsif (m/^(\d{4})(\d\d)(\d\d)$/) {
			push @dates, DateTime->new( year => $1, month => $2, day => $3 );
		}
		else {
			die "Failed parsing date descriptor: $txt";
			return ();
		}
	}

	return @dates;
}

sub resolve_descriptor_service
{
	my $service = shift;

	if(ref $service eq 'ARRAY') {
		return __PACKAGE__->descriptor( $service ) || cluck "Failed to utilise descriptor!";
	} elsif(ref $service) {
		return $service;
	}

	return __PACKAGE__->find($service) || cluck "Can't find service: $service";
}

sub DUMP
{
	my $self = shift;
	my $new  = {exceptions => []};
	$new->{service_id} = $self->service_id;
	for (qw/monday tuesday wednesday thursday friday saturday sunday/) {
		$new->{$_} = $self->{$_};
	}
	$new->{start_date} = $self->start_date->ymd('');
	$new->{end_date}   = $self->end_date->ymd('');

	foreach my $year ( keys %{ $self->{exceptions} } ) {
		foreach my $month ( keys %{ $self->{exceptions}->{$year} } ) {
			foreach my $day ( keys %{ $self->{exceptions}->{$year}->{$month} } ) {
				push @{ $new->{exceptions} },
					[ $year . _0($month) . _0($day), $self->{exceptions}->{$year}->{$month}->{$day} ];
			}
		}
	}
	$new->{exceptions} = [ sort { $a->[0] <=> $b->[0] } @{ $new->{exceptions} } ];

	return $new;
}

sub PRINT
{
	my $self = shift;
	unless(ref $self) {
		$self = $services->{$self};
	}

	my ($min_date, $max_date) = ($self->min_date, $self->max_date);

	print "$self->{service_id} (" . $min_date->ymd('') . " -> " . $max_date->ymd('') . ")\n";
	print "\t$self->{service_desc}\n" if $self->service_desc;

	my @month_data;

	my ( $start_year, $start_month, $end_year, $end_month )
		= ( $min_date->year, $min_date->month, $max_date->year, $max_date->month );

	while ( $start_year <= $end_year ) {
		while (( $start_year < $end_year && $start_month <= 12 )
			|| ( $start_year == $end_year && $start_month <= $end_month ) )
		{
			my $text = '';
			my $header
				= ( DateTime->new( year => $start_year, month => $start_month )->month_name )
				. " $start_year";
			my $pad = ' ' x ( 21 - 1 - length $header );
			$text .= "\n $header$pad\n";
			$text .= "Mo Tu We Th Fr Sa Su \n";

			my @month = calendar( $start_month, $start_year, 1 );
			foreach (@month) {
				foreach (@$_) {
					if ($_) {
						my $date = DateTime->new(
							year  => $start_year,
							month => $start_month,
							day   => $_
						);
						if ( $self->enabled($date) ) {
							$text .= sprintf "%2d ", $_;
						}
						elsif($min_date->ymd('') < $date->ymd('') && $date->ymd('') < $max_date->ymd('')) {
							$text .= ' _ ';
						}
						else {
							$text .= ' . ';
						}
					}
					else {
						$text .= '   ';
					}
				}
				$text .= "\n";
			}
			push @month_data, $text;

			$start_month++;
		}
		$start_month = 1;
		$start_year++;
	}

	while( scalar @month_data ) {
		my $month = shift @month_data;
		for(1, 2, 3) {
			my $merge_month = shift @month_data;
			last unless $merge_month;

			my @a = split '\n', $month;
			my @b = split '\n', $merge_month;

			$month = '';
			while(scalar @a || scalar @b ) {
				my ($a, $b) = (shift(@a), shift(@b));
				$a = ' ' x ((21*$_) + (($_ - 1) * 2)) unless $a;
				$b = ' ' x 21 unless $b;
				$month .= "$a  $b\n";
			}
		}

		print $month;
	}
	print "\n";
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
