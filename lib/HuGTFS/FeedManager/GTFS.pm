
=head1 NAME

HuGTFS::FeedManager::GTFS - HuGTFS feed manager for download + merging existing GTFS data with OSM

=head1 SYNOPSIS

	use HuGTFS::FeedManager::GTFS;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::GTFS;

use 5.14.0;
use utf8;
use strict;
use warnings;

use HuGTFS::Util qw(:utils);
use HuGTFS::Crawler;
use HuGTFS::OSMMerger;
use HuGTFS::ShapeFinder;
use HuGTFS::Dumper;

use File::Spec::Functions qw/catfile/;

use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

use Mouse;

with 'HuGTFS::FeedManager';
__PACKAGE__->meta->make_immutable;

no Mouse;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

=cut

sub download
{
	my $self = shift;

	return HuGTFS::Crawler->crawl( [ $self->options->{gtfs_url} ],
		$self->data_directory, undef, undef, { name_file => \&name_file } );
}

=head2 name_file

=cut

sub name_file
{
	my ( $url, $file ) = @_;
	return 'gtfs.zip';
}

=head2 parse

=cut

sub parse
{
	my ($self, %options) = @_;

	my $CSV = Text::CSV::Encoded->new(
		{
			encoding_in  => 'utf8',
			encoding_out => 'utf8',
			sep_char     => ',',
			quote_char   => '"',
			escape_char  => '"',
			eol          => "\r\n",
		}
	);

	my ( $STOPS,       $ROUTES,      $TRIPS,         @AGENCIES )   = ( {}, {}, {}, {} );
	my ( $used_shapes, $used_routes, $used_services, $used_stops ) = ( {}, {}, {}, {} );

	$log->info("Copying/Loading GTFS data...");
	my $ZIP = Archive::Zip->new();

	unless ( $ZIP->read( catfile( $self->data_directory, 'gtfs.zip' ) ) == AZ_OK ) {
		$log->diefatal("ZIP read error");
	}

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	# agencies
	my $io_agency = IO::String->new( $ZIP->contents('agency.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_agency) );
	while ( my $cols = $CSV->getline_hr($io_agency) ) {
		$self->fixup_agency($cols);
		$dumper->dump_agency($cols);
	}

	# stops
	my $io_stops = IO::String->new( $ZIP->contents('stops.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_stops) );
	while ( my $cols = $CSV->getline_hr($io_stops) ) {
		next if $cols->{location_type};
		$STOPS->{ $cols->{stop_id} } = $cols;
		$self->fixup_stop($cols);
	}

	# routes
	my $io_routes = IO::String->new( $ZIP->contents('routes.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_routes) );
	while ( my $cols = $CSV->getline_hr($io_routes) ) {
		$ROUTES->{ $cols->{route_id} } = $cols;
		$self->fixup_route($cols);
	}

	# trips
	my $io_trips = IO::String->new( $ZIP->contents('trips.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_trips) );
	while ( my $cols = $CSV->getline_hr($io_trips) ) {
		$TRIPS->{ $cols->{trip_id} } = $cols;
		$self->fixup_trip($cols);
	}

	my ( $skipped_trips, $data );

	my $skipped_trip = sub {
		return unless ( $self->options->{keep_existing} );

		my ( $trip, $route, $data, $gtfs ) = @_;

		$skipped_trips->{ $trip->{trip_id} } = 1;

		$used_shapes->{ $trip->{shape_id} } = 1
			if $trip->{shape_id};
		$used_services->{ $trip->{service_id} } = 1;
		$used_routes->{ $trip->{route_id} }     = 1;

		delete $trip->{stop_times};

		$dumper->dump_trip( {%$trip} );
	};

	my $finalize_trip = sub {
		my ( $trip, $route, $data ) = @_;

		$used_services->{ $trip->{service_id} } = 1;
		$used_routes->{ $trip->{route_id} }     = 1;

		$dumper->dump_trip( {%$trip} );

		delete $trip->{stop_times};
	};

	my $osm_data
		= HuGTFS::OSMMerger->parse_osm( $self->options->{osm_agency_id}, $self->osm_file );

	$data = HuGTFS::OSMMerger->new(
		{
			skipped_trip        => $skipped_trip,
			skipped_route       => sub { },
			finalize_trip       => $finalize_trip,
			remove_geometryless => 1,
		},
		$osm_data
	);

	my $stop_code_map = {
		map {
			$data->{stops}->{$_}->{stop_code}
				? ( $data->{stops}->{$_}->{stop_code} => $_ )
				: ()
			} keys %{ $data->{stops} }
	};

	my $available_stop_codes = {};
	foreach my $entity ( values %{ $osm_data->{nodes} }, values %{ $osm_data->{relations} } ) {
		next
			unless $entity->tag("operator")
				&& $entity->tag("operator") =~ $self->options->{osm_agency_id}
				&& $entity->tag($self->options->{osm_stop_code});
		my $ref = $entity->tag($self->options->{osm_stop_code});

		next if $stop_code_map->{$ref};

		$available_stop_codes->{$ref}
			= HuGTFS::OSMMerger::create_stop( $entity, $self->options->{osm_agency_id}, $osm_data->{nodes},
			$osm_data->{ways}, $osm_data->{relations} );

		if ( $available_stop_codes->{$ref} ) {
			for ( split /;/, $ref ) {
				$available_stop_codes->{$_} = $available_stop_codes->{$ref};
			}
			$available_stop_codes->{$ref}->{stop_id} = entity_id($entity);
		}
		else {
			delete $available_stop_codes->{$ref};
		}
	}

	my $shapefinder = HuGTFS::ShapeFinder->new(
		gtfs => {
			routes => $ROUTES,
			stops  => $STOPS,
		},
		data => $data,
	);

	my $osmify_stop_time = sub {
		my $st = shift;

		if ( $stop_code_map->{ $st->{stop_id} } ) {
			$st->{stop_id} = $stop_code_map->{ $st->{stop_id} };
		}
		elsif ( $available_stop_codes->{ $st->{stop_id} } ) {
			$stop_code_map->{ $st->{stop_id} } = HuGTFS::OSMMerger::default_create_stop(
				$available_stop_codes->{ $st->{stop_id} },
				{ %{ $STOPS->{ $st->{stop_id} } } },
				undef, undef, $data
			);

			$st->{stop_id} = $stop_code_map->{ $st->{stop_id} };
		}
		else {
			$used_stops->{ $st->{stop_id} } = 1;
		}
	};

	# Read stop_times in a streamed manner
	my $io_stop_times = IO::String->new( $ZIP->contents('stop_times.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_stop_times) );

	$log->info("Reading trips...");

OUTER:
	while (1) {
		my ( $trips, $prev );
		while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
			next if $options{selective} && $options{selective} ne $cols->{trip_id};

			my $trip = $TRIPS->{ $cols->{trip_id} };
			next unless $trip;

			$cols->{stop_sequence} = int( $cols->{stop_sequence} );

			push @{ $trip->{stop_times} }, $cols;

			# Assumes ordered data
			last if $prev && $prev->{service_id} ne $trip->{service_id};

			$prev = $trip;
			$trips->{ $trip->{trip_id} } = $trip;
		}
		last unless $prev;

		next unless scalar keys %$trips;

		foreach my $trip ( values %$trips ) {
			my $otrip = {%$trip};
			$otrip->{stop_times} = [
				map {
					{%$_}
					}
					sort { $a->{stop_sequence} <=> $b->{stop_sequence} }
					@{ $otrip->{stop_times} }
			];
			$osmify_stop_time->($_) for @{ $otrip->{stop_times} };

			my $route = $ROUTES->{ $trip->{route_id} };
			given($self->trip_shape_strategy($route, $trip)) {
				when("relations") {
					$data->merge(
						{
							routes => [ $route ],
							trips  => { $trip->{trip_id} => $trip },
							stops  => $STOPS
						}
					);
				}
				when("shapefinder") {
					if ( $shapefinder->create_shape($otrip) ) {
						$TRIPS->{ $otrip->{trip_id} } = $otrip;
						$finalize_trip->( $otrip, undef, undef );

						delete $trip->{stop_times};
					} else {
						continue;
					}
				}
				default {
					$skipped_trip->( $trip, $ROUTES->{ $trip->{route_id} }, undef, undef );
				}
			}
		}
	}

	$data->finalize_statistics;

	if ( scalar( keys %$skipped_trips ) ) {

		# Read stop_times in a streamed manner
		$log->info("Copying skipped trips' stop_times...");
		$io_stop_times = IO::String->new( $ZIP->contents('stop_times.txt') );
		$CSV->column_names( remove_bom $CSV->getline($io_stop_times) );

		while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
			next
				unless $skipped_trips->{ $cols->{trip_id} };

			$cols->{stop_sequence} = int( $cols->{stop_sequence} );

			$osmify_stop_time->($cols);

			$dumper->dump_stop_time($cols);
		}
	}

	# existing shapes
	if ( $self->options->{keep_existing} ) {
		$log->debug("Copying shapes...");
		my $io_shapes = IO::String->new( $ZIP->contents('shapes.txt') );
		$CSV->column_names( remove_bom $CSV->getline($io_shapes) );
		while ( my $cols = $CSV->getline_hr($io_shapes) ) {
			next unless $used_shapes->{ $cols->{shape_id} };
			delete $cols->{shape_bkk_ref};
			$dumper->dump_shape($cols);
		}
	}

	# calendar
	$log->debug("Copying calendar...");
	my $io_calendar = IO::String->new( $ZIP->contents('calendar.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_calendar) );
	while ( my $cols = $CSV->getline_hr($io_calendar) ) {
		$dumper->dump_calendar($cols) if $used_services->{ $cols->{service_id} };
	}

	# calendar_dates
	my $io_calendar_dates = IO::String->new( $ZIP->contents('calendar_dates.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_calendar_dates) );
	while ( my $cols = $CSV->getline_hr($io_calendar_dates) ) {
		$dumper->dump_calendar_date($cols) if $used_services->{ $cols->{service_id} };
	}

	$log->debug("Dumping routes & stops...");

	$dumper->dump_route($_)
		for (
		map {
			delete $_->{trips};
			$_;
		}
		sort { $a->{route_id} cmp $b->{route_id} }
		grep { $used_routes->{ $_->{route_id} } } values %$ROUTES
		);

	$dumper->dump_stop($_) for ( map { $data->{stops}->{$_} } sort keys %{ $data->{stops} } );
	$dumper->dump_stop($_) for ( map { $STOPS->{$_} } sort keys %$used_stops );

	augment($dumper);

	$dumper->dump_statistics( $data->{statistics} );

	$dumper->deinit_dumper();
}

sub trip_shape_strategy {
	my ($self, $route, $trip) = @_;

	return $self->options->{shape_strategy};
}

sub augment
{
	my ($self, $dumper) = @_;
}

sub fixup_agency
{
	my ($self, $agency) = @_;
}

sub fixup_route
{
	my ($self, $route) = @_;

	given ( $route->{route_type} ) {
		when ("0") {
			$route->{route_type} = 'tram';
		}
		when ("1") {
			$route->{route_type} = 'subway';
		}
		when ("2") {
			$route->{route_type} = 'rail';
		}
		when ("3") {
			$route->{route_type} = 'bus';
		}
		when ("4") {
			$route->{route_type} = 'ferry';
		}
		when ("5") {
			$route->{route_type} = 'cable_car';
		}
		when ("6") {
			$route->{route_type} = 'gondola';
		}
		when ("7") {
			$route->{route_type} = 'funicular';
		}
		when ("800") {
			$route->{route_type} = 'trolleybus';
		}
	}
}

sub fixup_trip
{
	my ($self, $trip) = @_;
}

sub fixup_stop
{
	my ($self, $stop) = @_;

	$stop->{stop_name} =~ s/^\s*(.*?)\s*$/$1/;

	if ( $self->options->{gtfs_stop_code} ) {
		$stop->{stop_code} = $stop->{ $self->options->{gtfs_stop_code} };
	}
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
