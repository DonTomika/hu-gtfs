
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

use YAML::Syck qw//;
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

	$self->check_data_times;

	HuGTFS::Cal->empty;

	unless($self->options->{no_generic_services}) {
		HuGTFS::Cal->generic_services;
	}

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

# Warn if the newest downloaded data file is newer than the newest timetable
sub check_data_times
{
	my $self = shift;

	my ($newest_data, $newest_timetable) = (0, 0);
	for(glob catfile($self->data_directory, '*')) {
		my $thistime = (stat)[9];
		$newest_data = $thistime if $thistime > $newest_data;
	}

	for(glob catfile($self->timetable_directory, '*')) {
		my $thistime = (stat)[9];
		$newest_timetable = $thistime if $thistime > $newest_timetable;
	}

	if($newest_data > $newest_timetable) {
		$log->warn("A file newer than the newest timetable exists in the data directory.");
	}
}

sub load_data
{
	my $self = shift;

	if ( -f catfile( $self->timetable_directory, 'agency.yml' ) ) {
		$log->debug("Loading agency.yml");
		$self->data->{agencies} = { map { $_->{agency_id} => $_ }
				YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'agency.yml' ) ) };
	}

	if ( -f catfile( $self->timetable_directory, 'agencies.yml' ) ) {
		$log->debug("Loading agencies.yml");
		$self->data->{agencies} = { map { $_->{agency_id} => $_ }
				YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'agencies.yml' ) ) };
	}

	{
		$log->debug("Loading agencies:");
		foreach
			my $agency_file ( glob( catfile( $self->timetable_directory, 'agency_*.yml' ) ) )
		{
			$log->debug("\t$agency_file");
			my (@yaml) = YAML::Syck::Load( slurp $agency_file);
			$self->data->{agencies}->{ $_->{agency_id} } = $_ for @yaml;
		}
	}

	if ( -f catfile( $self->timetable_directory, 'calendar.yml' ) ) {
		$log->debug("Loading calendar.yml...");
		HuGTFS::Cal->load($_)
			for YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'calendar.yml' ) );

	}

	if ( -f catfile( $self->timetable_directory, 'stops.yml' ) ) {
		$log->debug("Loading stops.yml...");
		$self->data->{stops} = { map { $_->{stop_id} => $_ }
				YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'stops.yml' ) ) };
	}

	if ( -f catfile( $self->timetable_directory, 'routes.yml' ) ) {
		$log->debug("Loading routes.yml...");
		$self->data->{routes} = { map { $_->{route_id} => $_ }
				YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'routes.yml' ) ) };
	}

	{
		$log->debug("Loading routes:");
		foreach my $route_file ( glob( catfile( $self->timetable_directory, 'route_*.yml' ) ) )
		{
			$log->debug("\t$route_file");
			my (@yaml) = YAML::Syck::Load( slurp $route_file);
			$self->data->{routes}->{ $_->{route_id} } = $_ for @yaml;
		}
	}

	if ( -f catfile( $self->timetable_directory, 'trips.yml' ) ) {
		$log->debug("Loading trips.yml...");
		foreach my $route_file ( glob( catfile( $self->timetable_directory, 'route_*.yml' ) ) )
		{
			$self->data->{trips} = { map { $_->{trip_id} => $_ }
					YAML::Syck::Load( slurp catfile( $self->timetable_directory, 'trips.yml' ) ) };
		}
	}

	{
		$log->debug("Loading trips:");
		foreach my $trip_file ( glob( catfile( $self->timetable_directory, 'trip_*.yml' ) ) ) {
			$log->debug("\t$trip_file");
			my (@yaml) = YAML::Syck::Load( slurp $trip_file);
			$self->data->{trips}->{ $_->{trip_id} } = $_ for @yaml;
		}
	}
}

sub sanify
{
	my $self = shift;

	for my $route ( values %{ $self->data->{routes} } ) {
		next unless $route->{agency};
		$route->{agency_id} = $route->{agency}->{agency_id};
		$self->data->{agencies}->{ $route->{agency_id} } = $route->{agency};
		delete $route->{agency};
	}

	for my $agency ( values %{ $self->data->{agencies} } ) {
		if($agency->{routes}) {
			for ( @{ $agency->{routes} } ) {
				$_->{agency_id} = $agency->{agency_id};
				$self->data->{routes}->{ $_->{route_id} } = $_;
			}
			delete $agency->{routes};
		}

		if($agency->{services}) {
			foreach my $s (keys %{$agency->{services}}) {
				$agency->{services}->{$s} = $self->sanify_service( $agency->{services}->{$s} );
			}
		}
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

					state $counter = 1;
					my $new_trip = {
						%$trip,
						frequencies => [$frequency],
						trip_id     => $trip->{trip_id} . "_F" . $counter++,
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

					delete $new_trip->{departures};

					push @new_trips, $new_trip;
				}

				if ( scalar @keep_freq ) {
					$trip->{frequencies} = \@keep_freq;
					push @new_trips, $trip;
				} elsif( $trip->{departures}) {
					delete $trip->{frequencies};
					push @new_trips, $trip;
				}
			} else {
				push @new_trips, $trip;
			}
		}

		$route->{trips} = \@new_trips;
	}

	foreach my $route ( values %{ $self->data->{routes} } ) {
		my @new_trips = ();
		my $services = {};

		my $agency = $self->data->{agencies}->{$route->{agency_id}};
		if($agency->{services}) {
			foreach my $s (keys %{$agency->{services}}) {
				$services->{$s} = $agency->{services}->{$s};
			}
		}

		if($route->{services}) {
			foreach my $s (keys %{$route->{services}}) {
				$services->{$s} = $self->sanify_service( $route->{services}->{$s} );
			}
			delete $route->{services};
		}

		foreach my $trip ( @{ $route->{trips} } ) {

			# Route
			unless ( $trip->{route_id} ) {
				$trip->{route_id} = $route->{route_id};
			}

			# Service periods
			if ( $trip->{service} ) {
				$trip->{service_id} = $self->sanify_service( $trip->{service} );
				delete $trip->{service};
			}

			if($trip->{shape}) {
				$trip->{shape}->{shape_points} = [
					map {
						ref $_ eq 'ARRAY'
							? {
							shape_pt_lat        => $_->[0],
							shape_pt_lon        => $_->[1],
							shape_dist_traveled => $_->[2],
							}
							: $_
					} @{ $trip->{shape}->{shape_points} }
				];
			}

			# Stop times
			for ( my $i = 0; $i <= $#{ $trip->{stop_times} }; $i++ ) {
				my $st = $trip->{stop_times}->[$i];
				if ( ref $st eq 'ARRAY' ) {
					my $nst = {};

					if ( $st->[1] =~ m/^\d\d?:\d\d(?::\d\d)?$/ ) {
						$nst->{arrival_time}   = shift @$st;
						$nst->{departure_time} = shift @$st;
					}
					else {
						$nst->{arrival_time} = $nst->{departure_time} = shift @$st;
					}

					if ( $self->data->{stops}->{ $st->[0] } ) {
						$nst->{stop_id} = shift @$st;
					}
					else {
						$nst->{stop_name} = shift @$st;
					}

					if ($#$st) {
						$nst->{shape_dist_traveled} = shift @$st;
					}
					$st = $trip->{stop_times}->[$i] = $nst;
				}

				$st->{shape_dist_traveled} = $i unless $st->{shape_dist_traveled};

				if ( $st->{stop_time} ) {
					$st->{departure_time} = $st->{arrival_time} = $st->{stop_time};
					delete $st->{stop_time};
				}
			}

			# Headsign
			unless ( $trip->{trip_headsign} ) {
				$trip->{trip_headsign}
					= $trip->{stop_times}->[-1]->{stop_id}
					? $self->data->{stops}->{ $trip->{stop_times}->[-1]->{stop_id} }
					->{stop_name}
					: $trip->{stop_times}->[-1]->{stop_name};
			}

			# Departures
			if ( $trip->{departures} ) {
				my $handle_departure = sub {
					my ($departure, $default_service) = @_;
					my $wheelchair = ( $departure =~ m/A$/ );
					$departure =~ s/A$//;

					my ($service) = ( $departure =~ m/^(.*(?=-\d+:\d+)|[^0-9]+)/);
					$departure =~ s/^(?:.*(?=-\d+:\d+)|[^0-9]+)//;
					$service ||= $default_service;

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

					if($service) {
						$new_trip->{trip_id} .= '_' . $service;
						$new_trip->{service_id} = $services->{$service};

						unless($new_trip->{service_id}) {
							$log->warn("Unknown service shorthand <$service> for route <$route->{route_id}> in trip <$new_trip->{trip_id}> at <$departure>");
							$new_trip->{service_id} = 'NEVER';
						}
					}

					for ( @{ $new_trip->{stop_times} } ) {
						$_->{arrival_time} = _T( $start + _S( $_->{arrival_time} ) - $offset );
						$_->{departure_time}
							= _T( $start + _S( $_->{departure_time} ) - $offset );
					}

					delete $new_trip->{departures};
					delete $new_trip->{frequencies};

					return $new_trip;
				};

				if(ref $trip->{departures} eq 'HASH' ) {
					foreach my $default_service ( keys %{ $trip->{departures} } ) {
						foreach my $departure ( @{ $trip->{departures}->{$default_service} } ) {
							push @new_trips, $handle_departure->($departure, $default_service);
						}
					}
				} else {
					foreach my $departure ( @{ $trip->{departures} } ) {
						push @new_trips, $handle_departure->($departure);
					}
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

	for my $agency ( values %{ $self->data->{agencies} } ) {
		delete $agency->{services};
	}
}

sub sanify_service
{
	my ($self, $service) = @_;
	if(ref $service eq 'ARRAY') {
		return HuGTFS::Cal->descriptor($service)->service_id;
	}
	elsif(ref $service eq 'HASH') {
		return HuGTFS::Cal->load($service)->service_id;
	}

	return $service;
}

sub create_geometries
{
	my $self = shift;

	unless($self->options->{osm_operator_id}) {
		return;
	}

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
