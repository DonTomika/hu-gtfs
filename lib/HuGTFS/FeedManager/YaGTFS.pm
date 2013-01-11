
=head1 NAME

HuGTFS::FeedManager::YaGTFS - HuGTFS feed manager utilising YAML GTFS files

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Kompok;

=head1 DESCRIPTION

Merges existing YAML gtfs data with OpenStreetMap routes.

Loads YAML data from $dir/timetables

=head1 METHODS

=cut

package HuGTFS::FeedManager::YaGTFS;

use 5.14.0;
use utf8;
use strict;
use warnings;

use YAML qw//;
use File::Spec::Functions qw/catfile/;

use HuGTFS::Cal;
use HuGTFS::Util qw(slurp entity_id _T _S);
use HuGTFS::Dumper;
use HuGTFS::OSMMerger;

use Mouse;

with 'HuGTFS::FeedManager';

has 'data' => (
	is      => 'rw',
	isa     => 'HashRef',
	default => sub { { agencies => {}, routes => {}, trips => {}, stops => {}, } }
);

__PACKAGE__->meta->make_immutable;

no Mouse;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

No Op.

=cut

sub download
{
	my $self = shift;

	# XXX: See if YaML file changed since last invocation

	return 1;
}

=head2 parse

Loads cached data and merges it with openstreetmap data as needed.

* stop_time:stop_time may be specified instead of arrival_time/departure_time
* trip:departures may be used instead-of/in-addition-to frequencies

=cut

sub parse
{
	my ( $self, %params ) = @_;

	HuGTFS::Cal->generic_services;

	# Load YAML files
	$log->info("Loading data...");
	$self->load_data;

	$log->info("Sanyfing data...");
	$self->sanify;

	$log->info("Creating geometries...");
	$self->create_geometries;

	# Dump
	$log->info("Dumping data...");
	$self->dump;
}

sub load_data
{
	my $self = shift;

	if ( -f catfile( $self->timetable_directory, 'agency.yml' ) ) {
		$log->debug("Loading agency.yml");
		$self->data->{agencies} = { map { $_->{agency_id} => $_ }
				YAML::Load( slurp catfile( $self->timetable_directory, 'agency.yml' ) ) };
	}

	if ( -f catfile( $self->timetable_directory, 'agencies.yml' ) ) {
		$log->debug("Loading agencies.yml");
		$self->data->{agencies} = { map { $_->{agency_id} => $_ }
				YAML::Load( slurp catfile( $self->timetable_directory, 'agencies.yml' ) ) };
	}

	{
		$log->debug("Loading agencies:");
		foreach
			my $agency_file ( glob( catfile( $self->timetable_directory, 'agency_*.yml' ) ) )
		{
			my ($yaml) = YAML::Load( slurp $agency_file);
			$self->data->{agencies}->{ $yaml->{agency_id} } = $yaml;
		}
	}

	if ( -f catfile( $self->timetable_directory, 'calendar.yml' ) ) {
		$log->debug("Loading calendar.yml...");
		HuGTFS::Cal->load($_)
			for YAML::Load( slurp catfile( $self->timetable_directory, 'calendar.yml' ) );

	}

	if ( -f catfile( $self->timetable_directory, 'routes.yml' ) ) {
		$log->debug("Loading routes.yml...");
		$self->data->{routes} = { map { $_->{route_id} => $_ }
				YAML::Load( slurp catfile( $self->timetable_directory, 'routes.yml' ) ) };
	}

	{
		$log->debug("Loading routes:");
		foreach my $route_file ( glob( catfile( $self->timetable_directory, 'route_*.yml' ) ) )
		{
			my ($yaml) = YAML::Load( slurp $route_file);
			$self->data->{routes}->{ $yaml->{route_id} } = $yaml;
		}
	}

	if ( -f catfile( $self->timetable_directory, 'trips.yml' ) ) {
		$log->debug("Loading trips.yml...");
		foreach my $route_file ( glob( catfile( $self->timetable_directory, 'route_*.yml' ) ) )
		{
			$self->data->{trips} = { map { $_->{trip_id} => $_ }
					YAML::Load( slurp catfile( $self->timetable_directory, 'trips.yml' ) ) };
		}

	}

	{
		$log->debug("Loading trips:");
		foreach my $trip_file ( glob( catfile( $self->timetable_directory, 'trip_*.yml' ) ) ) {
			my ($yaml) = YAML::Load( slurp $trip_file);
			$self->data->{trips}->{ $yaml->{trip_id} } = $yaml;
		}
	}
}

sub sanify
{
	my $self = shift;

	for my $agency ( values %{ $self->data->{agencies} } ) {
		next unless $agency->{routes};
		for ( @{ $agency->{routes} } ) {
			$_->{agency_id} = $agency->{agency_id};
			$self->data->{routes}->{ $_->{route_id} } = $_;
		}
		delete $agency->{routes};
	}

	for my $trip ( values %{ $self->data->{trips} } ) {
		push @{ $self->data->{routes}->{ $trip->{route_id} }->{trips} }, $trip;
	}
	$self->data->{trips} = {};

	# expand frequencies
	foreach my $route ( values %{ $self->data->{routes} } ) {
		my @new_trips = ();

		foreach my $trip ( @{ $route->{trips} } ) {
			if ( $trip->{frequencies} ) {
				my @keep_freq = ();
				foreach my $frequency ( @{ $trip->{frequencies} } ) {
					unless ( $frequency->{service} || $frequency->{service_id} ) {
						push @keep_freq, $frequency;
						next;
					}

					my $new_trip = {
						%$trip,
						frequencies => [$frequency],
						trip_id     => $trip->{trip_id} . "_$frequency->{start_time}",
					};

					$new_trip->{service}    = $frequency->{service};
					$new_trip->{service_id} = $frequency->{service_id};

					$new_trip->{stop_times} = [
						map {
							ref $_ eq 'ARRAY' ? [@$_] : {%$_};
						} @{ $trip->{stop_times} }
					];

					delete $frequency->{service};
					delete $frequency->{service_id};

					push @new_trips, $new_trip;
				}

				if ( scalar @keep_freq ) {
					$trip->{frequencies} = \@keep_freq;
					push @new_trips, $trip;
				}
			}
		}
	}

	foreach my $route ( values %{ $self->data->{routes} } ) {
		my @new_trips = ();

		foreach my $trip ( @{ $route->{trips} } ) {

			# Route
			unless ( $trip->{route_id} ) {
				$trip->{route_id} = $route->{route_id};
			}

			# Service periods
			if ( ref $trip->{service} eq 'ARRAY' ) {
				$trip->{service_id} = HuGTFS::Cal->descriptor( $trip->{service} )->service_id;
				delete $trip->{service};
			}
			elsif ( ref $trip->{service} eq 'HASH' ) {
				HuGTFS::Cal->load( %{ $trip->{service} } );
				$trip->{service_id} = $trip->{service}->{service_id};
				delete $trip->{service};
			}
			elsif ( $trip->{service} ) {
				$log->warn("Unknown service specified for trip $trip->{trip_id}");
			}

			# Stop times
			for ( my $i = 0; $i <= $#{ $trip->{stop_times} }; $i++ ) {
				my $st = $trip->{stop_times}->[$i];
				if(ref $st eq 'ARRAY') {
					$st = $trip->{stop_times}->[$i] = { stop_time => $st->[0], stop_name => $st->[1], };
				}

				$st->{shape_dist_traveled} = $i unless $st->{shape_dist_traveled};

				if ( $st->{stop_time} ) {
					$st->{departure_time} = $st->{arrival_time} = $st->{stop_time};
					delete $st->{stop_time};
				}
			}

			# Headsign
			unless ( $trip->{trip_headsign} ) {
				$trip->{trip_headsign} = $trip->{stop_times}->[-1]->{stop_name};
			}

			# Departures
			if ( $trip->{departures} ) {
				foreach my $departure ( @{ $trip->{departures} } ) {
					my $wheelchair = ( $departure =~ m/A$/ );
					$departure =~ s/A$//;

					my ( $offset, $start )
						= ( _S( $trip->{stop_times}->[0]->{departure_time} ), _S($departure) );

					my $new_trip = {
						%$trip,
						trip_id               => $trip->{trip_id} . "_$start",
						wheelchair_accessible => $wheelchair || $trip->{wheelchair_accessible},
					};
					$new_trip->{stop_times} = [
						map {
							{%$_};
						} @{ $trip->{stop_times} }
					];

					for ( @{ $new_trip->{stop_times} } ) {
						$_->{arrival_time} = _T( $start + _S( $_->{arrival_time} ) - $offset );
						$_->{departure_time}
							= _T( $start + _S( $_->{departure_time} ) - $offset );
					}
					push @new_trips, $new_trip;

					delete $new_trip->{departures};
					delete $new_trip->{frequencies};
				}
				delete $trip->{departures};

				push @new_trips, $trip
					if $trip->{frequencies};

			}
			else {
				push @new_trips, $trip;
			}

		}

		$route->{trips} = \@new_trips;
	}
}

sub create_geometries
{
	my $self = shift;

	my $osm_data
		= HuGTFS::OSMMerger->parse_osm( $self->options->{osm_operator_id}, $self->osm_file );

	my $merger = HuGTFS::OSMMerger->new( { remove_geometryless => 1, },
		$osm_data, { routes => $self->data->{routes} } );

	$self->data->{routes}     = { map { ($_->{route_id} => $_) } @{ $merger->{routes} } };
	$self->data->{stops}      = $merger->{stops};
	$self->data->{statistics} = $merger->{statistics};
}

sub dump
{
	my $self = shift;

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_agency($_)
		for ( sort { $a->{agency_id} cmp $b->{agency_id} }
		values %{ $self->data->{agencies} } );
	$dumper->dump_route($_)
		for ( sort { $a->{route_id} cmp $b->{route_id} } values %{ $self->data->{routes} } );
	$dumper->dump_trip($_)
		for ( sort { $a->{trip_id} cmp $b->{trip_id} } values %{ $self->data->{trips} } );
	$dumper->dump_stop($_)
		for ( map { $self->data->{stops}->{$_} } sort keys %{ $self->data->{stops} } );
	$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump() );

	if ( $self->data->{statistics} ) {
		$dumper->dump_statistics( $self->data->{statistics} );
	}

	$dumper->deinit_dumper();
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
