
=head1 NAME

HuGTFS::FeedManager::BKV - HuGTFS feed manager for download + merging existing GTFS data with OSM

=head1 SYNOPSIS

	use HuGTFS::FeedManager::BKV;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::BKV;

use 5.14.0;
use utf8;
use strict;
use warnings;

use YAML qw//;

use HuGTFS::Cal;
use HuGTFS::Util qw(:utils);
use HuGTFS::Crawler;
use HuGTFS::OSMMerger;
use HuGTFS::ShapeFinder;
use HuGTFS::Dumper;

use File::Temp qw/tempfile/;
use File::Spec::Functions qw/catfile tmpdir/;

use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

use Digest::SHA qw(sha256_hex);

use DateTime;

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
	return 'budapest_gtfs.zip';
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
	my ( $trip_merge_map, $shape_merge_map ) = ( {}, {} );

	$log->info("Copying/Loading GTFS data...");
	my $ZIP = Archive::Zip->new();

	unless ( $ZIP->read( catfile( $self->data_directory, 'budapest_gtfs.zip' ) ) == AZ_OK ) {
		$log->diefatal("ZIP read error");
	}

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	# agencies
	my $io_agency = IO::String->new( $ZIP->contents('agency.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_agency) );
	while ( my $cols = $CSV->getline_hr($io_agency) ) {
		fixup_agency($cols);
		$dumper->dump_agency($cols);
	}

	# stops
	my $io_stops = IO::String->new( $ZIP->contents('stops.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_stops) );
	while ( my $cols = $CSV->getline_hr($io_stops) ) {
		next if $cols->{location_type};
		$STOPS->{ $cols->{stop_id} } = $cols;
		fixup_stop($cols);
	}

	# routes
	my $io_routes = IO::String->new( $ZIP->contents('routes.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_routes) );
	while ( my $cols = $CSV->getline_hr($io_routes) ) {
		$ROUTES->{ $cols->{route_id} } = $cols;
		fixup_route($cols);
	}
	add_routes($ROUTES);

	# trips
	my $io_trips = IO::String->new( $ZIP->contents('trips.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_trips) );
	while ( my $cols = $CSV->getline_hr($io_trips) ) {
		$TRIPS->{ $cols->{trip_id} } = $cols;
		fixup_trip($cols);
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
				&& $entity->tag("operator") =~ m/\bBKV\b/
				&& $entity->tag("ref:bkv");
		my $ref = $entity->tag("ref:bkv");

		next if $stop_code_map->{$ref};

		$available_stop_codes->{$ref}
			= HuGTFS::OSMMerger::create_stop( $entity, "BKV", $osm_data->{nodes},
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

	$log->info("Merging trips...");
	unless(0 && $options{selective}) {
		my $count = 0;

		# Index the first & last stop of each trip => combine trips
		# key: $service_id-$route_id-$block_id-$direction_id-$stop_id-$arrival_time => []

		# first/last stop for each trip
		my ( $first_stops, $last_stops, $trips ) = ( {}, {}, {} );
		while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
			$cols->{stop_sequence} = int( $cols->{stop_sequence} );

			unless ( $trips->{ $cols->{trip_id} } ) {
				$trips->{ $cols->{trip_id} } = [ $cols, $cols ];
			}
			elsif (
				$trips->{ $cols->{trip_id} }->[0]->{stop_sequence} > $cols->{stop_sequence} )
			{
				$trips->{ $cols->{trip_id} }->[0] = $cols;
			}
			elsif (
				$trips->{ $cols->{trip_id} }->[1]->{stop_sequence} < $cols->{stop_sequence} )
			{
				$trips->{ $cols->{trip_id} }->[1] = $cols;
			}
		}

		my $hash;
		$hash = sub {
			my ( $trip, $depart ) = @_;

			my $key = join '>',
				map { $trip->{$_} } qw/service_id route_id block_id direction_id/;

			$key .= '>' . $trips->{ $trip->{trip_id} }->[$depart]->{stop_id};
			#$key .= '>' . $trips->{ $trip->{trip_id} }->[$depart]->{arrival_time};

			return $key;
		};

		# create actual keys
		foreach my $trip ( values %$TRIPS ) {
			next unless $trips->{ $trip->{trip_id} };

			my $key = $hash->( $trip, 0 );

			push @{ $first_stops->{$key} }, $trip;
		}

		my $forward_map = {};

		my $merge;
		$merge = sub {
			my $trip = shift;

			my $key = $hash->( $trip, 1 );

			if ( $first_stops->{$key} ) {
				my @poss = @{ $first_stops->{$key} };
				my ( $j, $rtrip, $min );
				for ( my $i = 0; $i <= $#poss; ++$i ) {
					my $t = $poss[$i];
					my $a = _S( $trips->{ $trip->{trip_id} }->[1]->{departure_time} );
					my $b = _S( $trips->{ $t->{trip_id} }->[0]->{arrival_time} );

					if ( !$rtrip && $a >= $b && $a - $b < 60 * 5 ) {
						$j     = $i;
						$min   = $a - $b;
						$rtrip = $t;
					}
					elsif ( $rtrip && $a >= $b && $a - $b < $min ) {
						$j     = $i;
						$min   = $a - $b;
						$rtrip = $t;
					}
				}

				return unless $rtrip;
				return if $rtrip->{trip_id} eq $trip->{trip_id};

				splice( @{ $first_stops->{$key} }, $j, 1 );

				$rtrip->{merge_dependancies} = {};

				$merge->($rtrip);

				my $new_merged = {
					trip     => $trip,
					rtrip    => $rtrip,
					skip     => $trips->{ $rtrip->{trip_id} }->[0]->{stop_sequence},
					sequence => $trips->{ $trip->{trip_id} }->[1]->{stop_sequence},
					shape    => $trips->{ $trip->{trip_id} }->[1]->{shape_dist_traveled},
				};

				$trip_merge_map->{ $rtrip->{trip_id} } = $new_merged;

				my $merged = $forward_map->{ $rtrip->{trip_id} };
				while ($merged) {
					my $merged_offsets = $trip_merge_map->{ $merged->{trip_id} };

					$merged_offsets->{trip} = $trip;
					$merged_offsets->{sequence} += $new_merged->{sequence};
					$merged_offsets->{shape}    += $new_merged->{shape};

					$TRIPS->{ $merged->{trip_id} } = $trip;

					$log->debug("Squashing $merged->{trip_id} into $trip->{trip_id}");

					$merged = $forward_map->{ $merged->{trip_id} };
				}

				$trip->{merge_dependancies} = {
					$trip->{trip_id}  => 1,
					$rtrip->{trip_id} => 1,
					%{ $rtrip->{merge_dependancies} }
				};

				$trip->{trip_headsign} = $rtrip->{trip_headsign};

				$TRIPS->{ $rtrip->{trip_id} } = $trip;

				$forward_map->{ $trip->{trip_id} } = $rtrip;

				$log->debug( "Merge $rtrip->{trip_id} "
						. "[$trips->{ $rtrip->{trip_id} }->[0]->{stop_id}, $trips->{ $rtrip->{trip_id} }->[0]->{departure_time}] "
						. "into $trip->{trip_id} "
						. "[$trips->{ $trip->{trip_id} }->[1]->{stop_id}, $trips->{ $trip->{trip_id} }->[1]->{departure_time}]"
				);

				delete $first_stops->{$key};

				$count++;
			}
		};

		foreach my $trip ( ( values %$TRIPS ) ) {
			next unless ref $trip;
			next unless $trips->{ $trip->{trip_id} };
			next if $trip_merge_map->{ $trip->{trip_id} };

			$merge->($trip);
		}

		foreach my $trip_id ( keys %$forward_map ) {
			next if $trip_merge_map->{$trip_id};

			my $trip          = $TRIPS->{$trip_id};
			my $shape_offsets = [
				{
					trip_id     => $trip->{trip_id},
					shape_id    => $trip->{shape_id},
					seq_offset  => 0,
					dist_offset => 0,
				}
			];

			my $rtrip = $forward_map->{ $trip->{trip_id} };
			while ($rtrip) {
				my $merge_map = $trip_merge_map->{ $rtrip->{trip_id} };

				push @$shape_offsets,
					{
					trip_id     => $rtrip->{trip_id},
					shape_id    => $rtrip->{shape_id},
					seq_offset  => 10000000 * ( scalar @$shape_offsets ),
					dist_offset => $merge_map->{shape},
					};

				$rtrip = $forward_map->{ $rtrip->{trip_id} };
			}

			my $shape_id = join '-',
				map {"$_->{shape_id}>$_->{seq_offset}>$_->{dist_offset}"} @$shape_offsets;

			for (@$shape_offsets) {
				$_->{id} = $shape_id;
				$shape_merge_map->{ $_->{shape_id} }->{$shape_id} = $_;
			}

			$trip->{shape_id} = $shape_id;
		}

		$log->info("Merged $count trips.");
	}

	$io_stop_times = IO::String->new( $ZIP->contents('stop_times.txt') );
	$CSV->column_names( remove_bom $CSV->getline($io_stop_times) );

	$log->info("Reading trips...");

=pod

	Duplicate ID A83994789 in column trip_id
	Duplicate ID A844826 in column trip_id
	Duplicate ID A846249 in column trip_id

=cut

OUTER:
	while (1) {
		my ( $trips, $prev );
		while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
			next if $options{selective} && $options{selective} ne $cols->{trip_id};

			my $trip = $TRIPS->{ $cols->{trip_id} };
			next unless $trip;

			$cols->{stop_sequence} = int( $cols->{stop_sequence} );

			# seen trip - uses real trip id
			if ( $trip->{merge_dependancies} ) {
				delete $trip->{merge_dependancies}->{ $cols->{trip_id} };
			}

			# Increase stop_sequence for merged trips + change trip id
			if ( $trip_merge_map->{ $cols->{trip_id} } ) {
				my $merge_offsets = $trip_merge_map->{ $cols->{trip_id} };

				unless ( $cols->{stop_sequence} eq $merge_offsets->{skip} ) {
					$cols->{stop_sequence}       += $merge_offsets->{sequence};
					$cols->{shape_dist_traveled} += $merge_offsets->{shape};
					$cols->{trip_id} = $trip->{trip_id};

					push @{ $trip->{stop_times} }, $cols;
				}
			}
			else {
				push @{ $trip->{stop_times} }, $cols;
			}

			# Assumes ordered data
			last if $prev && $prev->{service_id} ne $trip->{service_id};

			$prev = $trip;
			$trips->{ $trip->{trip_id} } = $trip;
		}
		last unless $prev;

		next unless scalar keys %$trips;

		foreach my $trip ( values %$trips ) {
			next
				if $trip->{merge_dependancies}
					&& scalar keys %{ $trip->{merge_dependancies} };

			delete $trip->{merge_dependancies};

			my $otrip = {%$trip};
			$otrip->{stop_times} = [
				map {
					{%$_}
					}
					sort { $a->{stop_sequence} <=> $b->{stop_sequence} }
					@{ $otrip->{stop_times} }
			];
			$osmify_stop_time->($_) for @{ $otrip->{stop_times} };

			if( $ROUTES->{ $trip->{route_id} }->{route_type} eq 'ferry' )
			{
				$data->merge(
					{
						routes => [ $ROUTES->{ $trip->{route_id} } ],
						trips  => { $trip->{trip_id} => $trip },
						stops  => $STOPS
					}
				);
			}
			elsif ( $shapefinder->create_shape($otrip) ) {

				$TRIPS->{ $otrip->{trip_id} } = $otrip;
				$finalize_trip->( $otrip, undef, undef );

				delete $trip->{stop_times};
			}
			else {
				$skipped_trip->( $trip, $ROUTES->{ $trip->{route_id} }, undef, undef );

=pod
				$data->merge(
					{
						routes => [ $ROUTES->{ $trip->{route_id} } ],
						trips  => { $trip->{trip_id} => $trip },
						stops  => $STOPS
					}
				);
=cut

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
			my $merge_offsets = $trip_merge_map->{ $cols->{trip_id} };

			next
				unless $skipped_trips->{ $cols->{trip_id} }
					|| ( $merge_offsets
						&& $skipped_trips->{ $trip_merge_map->{ $cols->{trip_id} }->{trip}
								->{trip_id} } );

			$cols->{stop_sequence} = int( $cols->{stop_sequence} );

			# Increase stop_sequence for merged trips + change trip id
			if ($merge_offsets) {
				next if $cols->{stop_sequence} eq $merge_offsets->{skip};

				my $merged_trip = $trip_merge_map->{ $cols->{trip_id} }->{trip};

				$cols->{stop_sequence}       += $merge_offsets->{sequence};
				$cols->{shape_dist_traveled} += $merge_offsets->{shape};
				$cols->{trip_id} = $merged_trip->{trip_id};
			}

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
			if ( $shape_merge_map->{ $cols->{shape_id} } ) {
				foreach my $m ( values %{ $shape_merge_map->{ $cols->{shape_id} } } ) {
					next unless $used_shapes->{ $m->{id} };

					my $ncols = {%$cols};
					delete $ncols->{shape_bkk_ref};
					$ncols->{shape_id} = $m->{id};
					$ncols->{shape_pt_sequence}   += $m->{seq_offset};
					$ncols->{shape_dist_traveled} += $m->{dist_offset};

					$dumper->dump_shape($ncols);
				}
			}

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

sub fixup_agency
{
	my $agency = shift;
	$agency->{agency_id} = "BKV" if $agency->{agency_id} eq "BKK";
}

sub fixup_route
{
	my $route = shift;

	$route->{agency_id} = "BKV" if $route->{agency_id} eq "BKK";

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
	}

	if ( $route->{route_id} =~ m/^6\d{3}$/) {
		$route->{route_type} = 'light_rail';
	}
	if ( $route->{route_id} =~ m/^\d{3}7$/ && $route->{route_short_name} =~ m/^\d+$/) {
		$route->{route_short_name} .= 'N';
	}
	if ( $route->{route_id} =~ m/^\d{3}8$/ && $route->{route_short_name} =~ m/^\d+$/) {
		$route->{route_short_name} .= 'G';
	}

	if ( $route->{route_short_name} =~ m/^(70|72|73|74|74A|75|76|77|78|79|80|80A|81|82|83)$/ ) {
		$route->{route_type} = 'trolleybus';
	}
}

sub fixup_trip
{
	my $trip = shift;

=pod
	given ( $trip->{route_id} ) {
		when (m/^61[03]/) {
			$trip->{route_id} = 6008;
		}
		when (m/^615/) {
			$trip->{route_id} = 6009;
		}
		when (m/^62/) {
			$trip->{route_id} = 6006;
		}
		when (m/^63/) {
			$trip->{route_id} = 6007;
		}
		when (m/^64/) {
			$trip->{route_id} = 6005;
		}
	}
=cut

	if ( $trip->{route_id} eq '3600' || $trip->{route_id} =~ m/^6\d{3}$/ ) {
		$trip->{trip_bikes_allowed} = 2;
	}
	else {
		$trip->{trip_bikes_allowed} = 1;
	}

	delete $trip->{trips_bkk_ref};
}

sub fixup_stop
{
	my $stop = shift;

	state $default_zone = 'BUDAPEST';
	state $zones        = {
		(
			map { $_ => 'BUDAKESZI' }
				qw/009438 009439 009440 009441 009442 009443 F00115 F00116 F04682 F04683/,
			qw/F04684 F04685 F04708 F04709 F04733 F04734 F04788 F04789 F04790/,
		),
		(
			map { $_ => 'BUDAORS' }
				qw/008339 008462 008598 009085 009589 011327 F01910 F01911 F04710 F04711/,
			qw/F04712 F04713 F04714 F04715 F04716 F04717 F04719 F04720 F04721 F04722/,
			qw/F04724 F04725 F04726 F04727 F04728 F04729 F04730 F04731 F04732 F04735/,
			qw/F04736 F04737 F04738 F04739 F04740 F04791 F04792 F04795 F04796 F04801/,
			qw/F04802 F04803 F04804 F04805 F04806 F04807 F04808 F04809 F04810 F04811/,
			qw/F04829 F04830 F04833 F04834 F04835 F04836 F04837 F04838/,
		),
		(
			map { $_ => 'BUDAORS,BUDAPEST' }
				qw/F01880 F01881 F01882 F01883 F01884 F01886 F01887 F01906 F01907 F02069/,
			qw/F02070/,
		),
		( map { $_ => 'BUDAORS,TOROKBALINT' } qw/008846 008847 F04741 F04742/, ),
		(
			map { $_ => 'DIOSD' }
				qw/008479 008480 009094 009095 009096 009097 009098 009099 009100 009101/,
			qw/009102 009103 009104 009105 009301 F04767 F04768 F04769 F04770 F04771/,
			qw/F04772 F04773 F04816/,
		),
		(
			map { $_ => 'GYAL' }
				qw/008548 008549 008550 008551 008552 008553 009192 009193 009194 009195/,
			qw/009196 009197 009198 009199 009200 009201 009202 009203 009204 009205/,
			qw/009206 009207 F04600 F04601 F04602 F04603 F04604 F04605 F04606 F04647/,
			qw/F04648 F04649 F04650 F04651 F04652/,
		),
		(
			map { $_ => 'NAGYKOVACSI' }
				qw/031884 F00387 F04777 F04778 F04779 F04780 F04781 F04782 F04783 F04784/,
			qw/F04785 F04786 F04821 F04822 F04823 F04824 F04825 F04826 F04827 F04828/,
		),
		(
			map { $_ => 'PECEL' }
				qw/F04578 F04579 F04580 F04581 F04582 F04583 F04585 F04586 F04587 F04588/,
			qw/F04589 F04590 F04591 F04592 F04593 F04594 F04595 F04643 F04644 F04645/,
			qw/F04646/,
		),
		(
			map { $_ => 'PILISBOROSJENO' }
				qw/009065 009066 009067 F00433 F00434 F04774 F04775 F04776 F04817 F04818/,
			qw/F04819 F04820/,
		),
		(
			map { $_ => 'SOLYMAR' }
				qw/F00117 F00118 F04696 F04697 F04698 F04699 F04700 F04701 F04702 F04703/,
			qw/F04704 F04705 F04706 F04707 F04797 F04798 F04799 F04800 F04831 F04832/,
		),
		(
			map { $_ => 'TOROKBALINT' }
				qw/008317 008318 008319 008320 008322 008323 008324 008325 008326 008328/,
			qw/008329 008330 008331 008332 008333 008345 F04743 F04744 F04745 F04746/,
			qw/F04747 F04748 F04749 F04750 F04751 F04752 F04753 F04754 F04755 F04756/,
			qw/F04757 F04758 F04759 F04761 F04762 F04763 F04764 F04765 F04812 F04813/,
			qw/F04814 F04815/,
		),
		(
			map { $_ => 'HEV' }
				qw/009272 009273 009276 F04607 F04608 F04609 F04610 F04611 F04612 F04613/,
			qw/F04614 F04615 F04616 F04617 F04618 F04619 F04620 F04621 F04622 F04623/,
			qw/F04624 F04625 F04626 F04627 F04628 F04629 F04630 F04631 F04632 F04633/,
			qw/F04634 F04635 F04636 F04638 F04655 F04656 F04657 F04658 F04659 F04660/,
			qw/F04661 F04662 F04663 F04664 F04665 F04668 F04669 F04670 F04671 F04672/,
			qw/F04673 F04674 F04675 F04676 F04677 F04679 F04688 F04689 F04690 F04691/,
			qw/F04692 F04693 F04694 F04695 F04793 F04794/,
		),
		(
			map { $_ => 'BUDAPEST,HEV' }
				qw/F00471 F00472 F03411 F03412 F03421 F03422 F04548 F04549/,
		),
	};

	$stop->{stop_code}      = $stop->{stop_id};
	$stop->{zone_id}        = $zones->{ $stop->{stop_code} } || $default_zone;
	$stop->{parent_station} = undef;
}

sub add_routes
{
	my $routes = shift;

=pod
	$routes->{6005} = {
		route_id         => 6005,
		agency_id        => 'BKV',
		route_short_name => 'H5',
		route_long_name  => 'Szentendrei HÉV',
		route_desc       => 'Batthyány tér M+H / Szentendre',
		route_type       => 'light_rail',
		route_color      => 'A03472',
		route_text_color => 'FFFFFF',
	};

	$routes->{6007} = {
		route_id         => 6007,
		agency_id        => 'BKV',
		route_short_name => 'H7',
		route_long_name  => 'Csepeli HÉV',
		route_desc       => 'Boráros tér H / Csepel',
		route_type       => 'light_rail',
		route_color      => 'EC7C26',
		route_text_color => 'FFFFFF',
	};

	$routes->{6008} = {
		route_id         => 6008,
		agency_id        => 'BKV',
		route_short_name => 'H8',
		route_long_name  => 'Gödöllői HÉV',
		route_desc       => 'Örs vezér tere M+H / Gödöllő',
		route_type       => 'light_rail',
		route_color      => 'D36E70',
		route_text_color => 'FFFFFF',
	};

	$routes->{6009} = {
		route_id         => 6009,
		agency_id        => 'BKV',
		route_short_name => 'H9',
		route_long_name  => 'Csömöri HÉV',
		route_desc       => 'Örs vezér tere M+H / Csömör',
		route_type       => 'light_rail',
		route_color      => 'D36E70',
		route_text_color => 'FFFFFF',
	};
=cut
}

# Add Sikló & Libegő
sub augment
{
	my $dumper = shift;

	$dumper->dump_route($_)
		for (
		{
			route_id         => 7001,
			agency_id        => 'BKV',
			route_short_name => undef,
			route_long_name  => 'Budavári Sikló',
			route_desc       => undef,
			route_type       => 'funicular',
			route_color      => undef,
			route_text_color => undef,
		},

		{
			route_id         => 7002,
			agency_id        => 'BKV',
			route_short_name => undef,
			route_long_name  => 'Zugligeti Libegő',
			route_desc       => undef,
			route_type       => 'gondola',
			route_color      => undef,
			route_text_color => undef,
		}
		);

	$dumper->dump_calendar( HuGTFS::Cal->find('NAPONTA')->dump() );

	$dumper->dump_trip($_)
		for (
		{
			trip_id               => 'SIKLO-1',
			route_id              => '7001',
			service_id            => 'NAPONTA',
			direction_id          => 'outbound',
			trip_headsign         => 'Szent György tér',
			wheelchair_accessible => 1,
			stop_times    => [
				{
					stop_id        => 'SIKLO-ALSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'SIKLO-FELSO',
					arrival_time   => '00:02:30',
					departure_time => '00:02:30',
				},
			],
			frequencies => [
				{
					start_time   => '07:30:00',
					end_time     => '22:00:00',
					headway_secs => '450',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-SIKLO-1',
				shape_points => [
					{ shape_pt_lat => 47.497890, shape_pt_lon => 19.039816, },
					{ shape_pt_lat => 47.497631, shape_pt_lon => 19.038432, },
				],
			},
		},
		{
			trip_id               => 'SIKLO-2',
			route_id              => '7001',
			service_id            => 'NAPONTA',
			direction_id          => 'inbound',
			trip_headsign         => 'Clark Ádám tér',
			wheelchair_accessible => 1,
			stop_times    => [
				{
					stop_id        => 'SIKLO-FELSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'SIKLO-ALSO',
					arrival_time   => '00:02:30',
					departure_time => '00:02:30',
				},
			],
			frequencies => [
				{
					start_time   => '07:30:00',
					end_time     => '22:00:00',
					headway_secs => '450',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-SIKLO-2',
				shape_points => [
					{ shape_pt_lat => 47.497631, shape_pt_lon => 19.038432, },
					{ shape_pt_lat => 47.497890, shape_pt_lon => 19.039816, },
				],
			},
		},
		{
			trip_id       => 'LIBEGO-1',
			route_id      => '7002',
			service_id    => 'NAPONTA',
			direction_id  => 'outbound',
			trip_headsign => 'János-hegy',
			wheelchair_accessible => 2,
			stop_times    => [
				{
					stop_id        => 'LIBEGO-ALSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'LIBEGO-FELSO',
					arrival_time   => '00:12:00',
					departure_time => '00:12:00',
				},
			],
			frequencies => [
				{
					start_time   => '09:30:00',
					end_time     => '16:00:00',
					headway_secs => '60',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-LIBEGO-1',
				shape_points => [
					{ shape_pt_lat => 47.516646, shape_pt_lon => 18.974521 },
					{ shape_pt_lat => 47.515849, shape_pt_lon => 18.960519 },
				],
			},
		},
		{
			trip_id       => 'LIBEGO-2',
			route_id      => '7002',
			service_id    => 'NAPONTA',
			direction_id  => 'inbound',
			trip_headsign => 'Zugliget',
			wheelchair_accessible => 2,
			stop_times    => [
				{
					stop_id        => 'LIBEGO-FELSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'LIBEGO-ALSO',
					arrival_time   => '00:12:00',
					departure_time => '00:12:00',
				},
			],
			frequencies => [
				{
					start_time   => '09:30:00',
					end_time     => '16:00:00',
					headway_secs => '60',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-LIBEGO-2',
				shape_points => [
					{ shape_pt_lat => 47.515849, shape_pt_lon => 18.960519 },
					{ shape_pt_lat => 47.516646, shape_pt_lon => 18.974521 },
				],
			},
		},
		);

	$dumper->dump_stop($_)
		for (
		{
			stop_id             => 'SIKLO-ALSO',
			stop_name           => 'Clark Ádám tér',
			stop_code           => undef,
			stop_lat            => 47.49789,
			stop_lon            => 19.039816,
			zone_id             => 'SIKLO',
			wheelchair_boarding => 1,
		},
		{
			stop_id             => 'SIKLO-FELSO',
			stop_name           => 'Szent György tér',
			stop_code           => undef,
			stop_lat            => 47.497631,
			stop_lon            => 19.038432,
			zone_id             => 'SIKLO',
			wheelchair_boarding => 1,
		},

		{
			stop_id             => 'LIBEGO-ALSO',
			stop_name           => 'Zugliget',
			stop_code           => undef,
			stop_lat            => 47.516646,
			stop_lon            => 18.974521,
			zone_id             => 'LIBEGO',
			wheelchair_boarding => 2,
		},
		{
			stop_id             => 'LIBEGO-FELSO',
			stop_name           => 'János-hegy',
			stop_code           => undef,
			stop_lat            => 47.515849,
			stop_lon            => 18.960519,
			zone_id             => 'LIBEGO',
			wheelchair_boarding => 2,
		}
		);
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
