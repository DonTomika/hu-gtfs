=head1 NAME

HuGTFS::KML - GTFS->KML convert used within HuGTFS

=head1 SYNOPSIS

	use HuGTFS::KML;

	HuGTFS::KML->convert($dest_kml, @gtfs_feeds);
	
=head1 REQUIRES
					
perl 5.14.0, Text::CSV::Encoded, Archive::ZIP, IO::File, Geo::KML, YAML
					
=head1 DESCRIPTION

Simple module for creating KML files from gtfs feeds.

=head1 METHODS
					
=cut

package HuGTFS::KML;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Carp qw/ carp cluck confess croak /;

use Encode;
use IO::String;
use Text::CSV::Encoded;
use IO::File;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Geo::KML;
use Data::Dumper;
use YAML ();
use Encode;

=head2 convert $kml, @gtfs_feeds

Convert the stop (and stop hierarchy) data from the GTFs feed into kml file.

=cut

sub convert
{
	my $class = shift;
	my $kml   = shift;
	my @files = @_;

	binmode( STDOUT, ':utf8' );
	binmode( STDERR, ':utf8' );
	binmode( STDIN,  ':utf8' );
	local $| = 1;

	my %data       = ();
	my (@agencies) = ();
	my $KML        = Geo::KML->new( version => '2.2.0' );
	my $CSV        = Text::CSV::Encoded->new(
		{
			encoding_in  => 'utf8',
			encoding_out => 'utf8',
			sep_char     => ',',
			quote_char   => '"',
			escape_char  => '"',
			eol          => "\r\n",
		}
	);

	foreach my $gtfs (@files) {
		if ( $gtfs =~ /\.kml$/ ) {
			$kml = $gtfs;
			next;
		}

		my $ZIP       = Archive::Zip->new();
		my $trip_dest = {};
		my ( $stops, $routes, $trips ) = ( {}, {}, {} );

		unless ( $ZIP->read($gtfs) == AZ_OK ) {
			die 'read error';
		}

		my $io_agency     = IO::String->new( $ZIP->contents('agency.txt') );
		my $io_stops      = IO::String->new( $ZIP->contents('stops.txt') );
		my $io_routes     = IO::String->new( $ZIP->contents('routes.txt') );
		my $io_trips      = IO::String->new( $ZIP->contents('trips.txt') );
		my $io_stop_times = IO::String->new( $ZIP->contents('stop_times.txt') );
		my $stops_yml     = $ZIP->contents('stops.yml');
		my ( $stop_map, $name_map ) = ( {}, {} );

		Encode::_utf8_on($stops_yml);
		$stops_yml = YAML::Load($stops_yml);

		$CSV->column_names( $CSV->getline($io_agency) );
		while ( my $cols = $CSV->getline_hr($io_agency) ) {
			push @agencies, [ $cols->{agency_id}, $cols->{agency_name} ];
			$cols->{dest} = {};
		}

		$CSV->column_names( $CSV->getline($io_stops) );
		while ( my $cols = $CSV->getline_hr($io_stops) ) {
			next if $cols->{location_type} && $cols->{location_type} == 1;

			$stops->{ $cols->{stop_id} } = $cols;
			$cols->{dest} = {};
		}

		$CSV->column_names( $CSV->getline($io_routes) );
		while ( my $cols = $CSV->getline_hr($io_routes) ) {
			$routes->{ $cols->{route_id} } = $cols;
		}

		$CSV->column_names( $CSV->getline($io_trips) );
		while ( my $cols = $CSV->getline_hr($io_trips) ) {
			$trips->{ $cols->{trip_id} } = $cols;
		}

		{
			foreach my $stop ( values %{ $stops_yml->{stops} } ) {
				$stop_map->{$_}->[0] = $stop->{id} for @{ $stop->{gtfs_stop_ids} };
				$name_map->{ $stop->{id} } = $stop->{name};
			}

			foreach my $stop ( values %$stops ) {
				next if $stop_map->{ $stop->{stop_id} };

				$stop_map->{ $stop->{stop_id} }           = [ $stop->{stop_id} ];
				$name_map->{ $stop->{stop_id} }           = $stop->{stop_name};
				$stops_yml->{stops}->{ $stop->{stop_id} } = {
					id    => $stop->{stop_id},
					name  => $stop->{stop_name},
					names => [ $stop->{stop_name}, ],
					geom  => [ $stop->{stop_lon}, $stop->{stop_lat} ],
				};
			}

			foreach my $area ( values %{ $stops_yml->{areas} } ) {
				my @geom = ();

				$stop_map->{$_}->[1] = $area->{id} for @{ $area->{gtfs_stop_ids} };
				$name_map->{ $area->{id} } = $area->{name};

				foreach my $m ( @{ $area->{members} } ) {
					push @{ $geom[$_] }, $stops_yml->{stops}->{$m}->{geom}->[$_] for ( 0, 1 );
				}
				for my $i ( 0, 1 ) {
					my $sum = 0;
					$sum += $_ for @{ $geom[$i] };
					$sum /= scalar @{ $geom[$i] };
					$geom[$i] = $sum;
				}
				$area->{geom} = \@geom;
			}

			foreach my $interchange ( values %{ $stops_yml->{interchanges} } ) {
				my @geom = ();

				$stop_map->{$_}->[2] = $interchange->{id}
					for @{ $interchange->{gtfs_stop_ids} };
				$name_map->{ $interchange->{id} } = $interchange->{name};

				foreach my $m ( @{ $interchange->{members} } ) {
					push @{ $geom[$_] }, $stops_yml->{areas}->{$m}->{geom}->[$_] for ( 0, 1 );
				}
				for my $i ( 0, 1 ) {
					my $sum = 0;
					$sum += $_ for @{ $geom[$i] };
					$sum /= scalar @{ $geom[$i] };
					$geom[$i] = $sum;
				}
				$interchange->{geom} = \@geom;
			}

			my $last_stop = {};
			$CSV->column_names( $CSV->getline($io_stop_times) );
			while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
				my $dest_stop_id = $cols->{stop_id};

				if (  !$last_stop->{ $cols->{trip_id} }
					|| $last_stop->{ $cols->{trip_id} }->[0] < $cols->{stop_sequence} )
				{
					$last_stop->{ $cols->{trip_id} } = [
						$cols->{stop_sequence},
						$dest_stop_id,
						$routes->{ $trips->{ $cols->{trip_id} }->{route_id} }
							->{route_short_name}
							|| $routes->{ $trips->{ $cols->{trip_id} }->{route_id} }
							->{route_long_name},
						[
							(
								$last_stop->{ $cols->{trip_id} }
								? @{ $last_stop->{ $cols->{trip_id} }->[3] }
								: ()
							),
							$dest_stop_id
						],
					];
				}
			}

			foreach my $trip ( values %$last_stop ) {
				foreach my $stop ( @{ $trip->[3] }[ 0 .. $#{ $trip->[3] } - 1 ] ) {
					$trip_dest->{$stop}->{ $trip->[1] }->{ $trip->[2] } = 1;
				}
			}

			# Add routes to visited stops, even if it's not the destination
			foreach my $trip ( values %$last_stop ) {
				foreach my $stop ( @{ $trip->[3] }[ 0 .. $#{ $trip->[3] } - 1 ] ) {
					foreach my $ostop ( keys %{ $trip_dest->{$stop} } ) {
						for ( @{ $trip->[3] } ) {
							if ( $_ eq $ostop ) {
								$trip_dest->{$stop}->{$ostop}->{ $trip->[2] } = 1;
							}
						}
					}
				}
			}

			my $new_trip_dest = {};
			foreach my $from ( keys %$trip_dest ) {
				foreach my $to ( keys %{ $trip_dest->{$from} } ) {
					foreach my $f ( @{ $stop_map->{$from} } ) {
						foreach ( keys %{ $trip_dest->{$from}->{$to} } ) {
							$new_trip_dest->{$f}->{ $stop_map->{$to}->[-1] }->{$_} = 1;
						}
					}
				}
			}
			$trip_dest = $new_trip_dest;
		}

		#	#NAME
		#
		#	# ... felé
		#	#NUMBERS
		#
		#	# ... felé
		#	#NUMBERS

		foreach my $key ( keys %$trip_dest ) {
			my $stop_dest = $trip_dest->{$key};
			my ( $description, $stop_data, %descr, $style ) = ("");

			if ( $stops_yml->{stops}->{$key} ) {
				$style     = '#stopStyle';
				$stop_data = $stops_yml->{stops}->{$key};
			}
			elsif ( $stops_yml->{areas}->{$key} ) {
				$style     = '#areaStyle';
				$stop_data = $stops_yml->{areas}->{$key};
			}
			elsif ( $stops_yml->{interchanges}->{$key} ) {
				$style     = '#interchangeStyle';
				$stop_data = $stops_yml->{interchanges}->{$key};
			}

			# else can't happen :-P

			if ( scalar grep { $_ ne $stop_data->{name} } @{ $stop_data->{names} } ) {
				$description .= "Más elnevezés(ek): <b>"
					. join( "</b>; <b>",
					grep { $_ ne $stop_data->{name} } @{ $stop_data->{names} } )
					. "</b><br /><br />";
			}

			foreach my $s ( sort keys %{$stop_dest} ) {
				{
					no warnings;
					for ( sort { $a <=> $b } keys %{ $stop_dest->{$s} } ) {
						$descr{ $name_map->{$s} } .= "$_ ";
					}
				}
			}

			{
				local $ENV{LC_CTYPE} = 'hu_HU.UTF-8';
				{
					use locale;
					$description .= join "", map { ; "<b>$_->[0] felé</b><br />$_->[1]<br />" }
						sort { $a->[0] cmp $b->[0] }
						map { ; [ $_, $descr{$_} ] } keys %descr;
				}
			}

			$description
				.= "<br /><small>Map data &copy; <a title='OpenStreetMap' href='http://www.openstreetmap.org'>OpenStreetMap</a> contributors.</small>";

			$key =~ s/-/_/g;
			my $placemark = {
				Placemark => {
					id          => "object-$key",
					name        => $stop_data->{name},
					description => $description,
					styleUrl    => $style,
					Point =>
						{ coordinates => ["$stop_data->{geom}[0],$stop_data->{geom}[1],0"] },
				}
			};

			if ( $stops_yml->{stops}->{$key} ) {
				push @{ $data{stops} }, $placemark;
			}
			elsif ( $stops_yml->{areas}->{$key} ) {
				push @{ $data{areas} }, $placemark;
			}
			elsif ( $stops_yml->{interchanges}->{$key} ) {
				push @{ $data{interchanges} }, $placemark;
			}
		}
	}

	$KML->writeKML(
		{
			Document => {
				id   => "hugtfs-kml-" . join( '-', map { $_->[0] } @agencies ),
				name => "Közösségi közlekedés - "
					. join( ', ', map { $_->[1] } @agencies ),

				'author' => { cho_name => [ { name => 'Hu-GTFS', uri => 'http://flaktack.net/gtfs-adatok' } ] },
				'link'               => { href => 'http://flaktack.net/gtfs-adatok', },
				AbstractFeatureGroup => [
					{
						Folder => {
							name                 => 'Átszállóhelyek',
							AbstractFeatureGroup => $data{interchanges},
						},
					},
					{
						Folder => {
							name                 => 'Megálló környékek',
							AbstractFeatureGroup => $data{areas},
						},
					},
					{
						Folder => {
							name                 => 'Megállóhelyek',
							AbstractFeatureGroup => $data{stops},
						},
					},
				],
				AbstractStyleSelectorGroup => [
					{
						Style => {
							id        => "stopStyle",
							IconStyle => {
								hotSpot => {
									xunits => 'fraction',
									yunits => 'fraction',
									x      => '0.5',
									y      => '0,5',
								},
								Icon => {
									href =>
										'http://maps.gstatic.com/intl/en_ALL/mapfiles/ms/micons/blue.png',
								},
							},

						},
					},
					{
						Style => {
							id        => "areaStyle",
							IconStyle => {
								hotSpot => {
									xunits => 'fraction',
									yunits => 'fraction',
									x      => '0.5',
									y      => '0,0',
								},
								Icon => {
									href =>
										'http://maps.gstatic.com/intl/en_ALL/mapfiles/ms/micons/green.png',
								},
							},
						},
					},
					{
						Style => {
							id        => "interchangeStyle",
							IconStyle => {
								hotSpot => {
									xunits => 'fraction',
									yunits => 'fraction',
									x      => '0.5',
									y      => '0,0',
								},
								Icon => {
									href =>
										'http://maps.gstatic.com/intl/en_ALL/mapfiles/ms/micons/red.png',
								},
							},
						},
					},
				],
			},
		},
		$kml
	);

}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
