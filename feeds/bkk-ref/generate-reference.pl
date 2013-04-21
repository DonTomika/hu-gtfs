#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  generate-reference.pl
#
#        USAGE:  ./generate-reference.pl [gtfs dir]
#
#  DESCRIPTION:
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (),
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  03/15/2013 06:46:07 PM
#     REVISION:  ---
#===============================================================================

use 5.10.0;
use utf8;
use strict;
use warnings;

use autodie;

use FindBin;
use lib "$FindBin::Bin/../../lib";

my ($DIR) = (shift);

binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

use Data::Dumper;
use Text::CSV::Encoded;

use YAML qw//;
use HuGTFS::Util qw/burp/;
use List::MoreUtils qw/none/;
use XML::Twig;
use Data::Dumper;

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
	}
);

my $route_with_multiple_patterns = { map { $_ => 1 } qw/0405 1600 2170 2335 2545 2600 9940/ };
my $route_trip_map = {
	#'0405-1' => [qw//],
};

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

my ( $file, $routes, $trips, $stops, $shapes );

my $needed = { map { $_ => 1 } @ARGV };
my $skip = {};

say STDERR "Loading data...";

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$routes->{ $cols->{route_id} } = {%$cols};
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $route, $id ) = ( $cols->{route_id}, $cols->{trip_id} );

	$trips->{$id} = {%$cols};
	push @{ $routes->{$route}->{trips} }, $trips->{$id};
}

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my $trip = $trips->{ $cols->{trip_id} };

	push @{ $trip->{stop_times} }, {%$cols};
}

open( $file, "$DIR/stops.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	next if $cols->{location_type};
	delete $cols->{parent_station};
	delete $cols->{location_type};
	delete $cols->{wheelchair_boarding};
	$stops->{ $cols->{stop_id} } = {%$cols};
}

open( $file, "$DIR/shapes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	push @{ $shapes->{ $cols->{shape_id} } }, {%$cols};
}

say STDERR "Creating patterns...";

foreach my $trip ( values %$trips ) {
	my $route = $routes->{ $trip->{route_id} };
	my $pattern = join '-', map { $_->{stop_id} } @{ $trip->{stop_times} };

	push @{ $route->{patterns}->{ $trip->{direction_id} }->{$pattern} }, $trip;
}

say STDERR "Comparing patterns...";

chdir($FindBin::Bin);

sub cleanup_trip
{
	my ($trip, $id) = @_;

	$trip->{trip_id} = $id;
	$trip->{service_id} = 'REFERENCE';

	delete $trip->{trips_bkk_ref};
	delete $trip->{route_id};
	delete $trip->{block_id};
	foreach my $st ( @{ $trip->{stop_times} } ) {
		delete $st->{stop_sequence};
		delete $st->{trip_id};
	}

	$shapes->{ $trip->{shape_id} }
		= [ sort { $a->{shape_pt_sequence} <=> $b->{shape_pt_sequence} }
			@{ $shapes->{ $trip->{shape_id} } } ];

	$trip->{shape} = {
		shape_id     => $trip->{trip_id} . '-' . $trip->{shape_id},
		shape_points => [],
	};
	foreach my $p ( @{ $shapes->{ $trip->{shape_id} } } ) {
		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $p->{shape_pt_lat},
			shape_pt_lon        => $p->{shape_pt_lon},
			shape_dist_traveled => $p->{shape_dist_traveled}
			};
	}
	delete $trip->{shape_id};

	return $trip;
}

sub spad {
	my $a = shift;

	return (' ' x (6 - length $a)) . $a;
}

sub npad {
	my $a = shift;

	return $a . ('0' x (9 - length $a));
}

foreach my $route ( sort { $a->{route_id} cmp $b->{route_id} } values %$routes ) {
	next if $route->{route_id} =~ m/^(?:0337)$/;

	my @trips = ();

	foreach my $dir ( sort keys %{ $route->{patterns} } ) {
		if ( $route_trip_map->{ join "-", $route->{route_id}, $dir } ) {
			my @trips = @{ $route_trip_map->{ join "-", $route->{route_id}, $dir } };
			for ( my $i = 0; $i < @trips; ++$i ) {
				push @trips,
					cleanup_trip( $trips->{ $trips[$i] },
					join "-", "REFERENCE", $route->{route_id}, $dir, $i + 1 );
			}
		}
		elsif ( scalar values %{ $route->{patterns}->{$dir} } == 1 ) {
			push @trips, cleanup_trip( ( values %{ $route->{patterns}->{$dir} } )[0]->[0], join "-", "REFERENCE", $route->{route_id}, $dir, 1 );
		}
		elsif ( scalar values %{ $route->{patterns}->{$dir} } > 1 ) {
			my $patterns = {
				map { $_ => scalar( @{ $route->{patterns}->{$dir}->{$_} } ) }
					keys %{ $route->{patterns}->{$dir} }
			};

			my ( $master, $second )
				= ( sort { $patterns->{$b} <=> $patterns->{$a} } keys %$patterns )[ 0, 1 ];
			if ( $patterns->{$master} < 2 * $patterns->{$second} ) {
				say "$route->{route_id}-$dir: " . scalar values %{ $route->{patterns}->{$dir} };
				say "\tSMALLDIFF ("
					. ( $patterns->{$master} - $patterns->{$second} ) . ", "
					. ( $patterns->{$second} / $patterns->{$master} ) . ")";
			}

			push @trips, cleanup_trip( $route->{patterns}->{$dir}->{$master}->[0], join "-", "REFERENCE", $route->{route_id}, $dir, 1 );
			if ( $route_with_multiple_patterns->{ $route->{route_id} } ) {
				push @trips, cleanup_trip( $route->{patterns}->{$dir}->{$second}->[0], join "-", "REFERENCE", $route->{route_id}, $dir, 2 );
			}
		}
	}

	my $d_route = {
		(
			map { $_ => $route->{$_} }
				qw/route_id route_short_name route_long_name route_desc route_color route_text_color route_url agency_id route_type route_url/
		),
		trips => \@trips,
	};

	my $yaml = YAML::Dump($d_route);

	$yaml =~ s/- shape_dist_traveled: ([0-9.]+)\n\s*shape_pt_lat: ([0-9.]+)\n\s*shape_pt_lon: ([0-9.]+)(?=\n(?:\s*stop_times|\s*-))/"- [".npad($2).", ".npad($3).", ".spad($1)."]"/ge; # shapes
	$yaml =~ s/- arrival_time: ([0-9:]+)\n\s*departure_time: \1\n\s*shape_dist_traveled: ([0-9.]+)\n\s*stop_id: (\w+)(?=\n(?:\s*trip_headsign|\s*-))/"- ['$1', '$3', " . spad($2) . "] # $stops->{$3}->{stop_name}"/ge;
	$yaml =~ s/- arrival_time: ([0-9:]+)\n\s*departure_time: ([0-9:]+)\n\s*shape_dist_traveled: ([0-9.]+)\n\s*stop_id: (\w+)(?=\n(?:\s*trip_headsign|\s*-))/"- ['$1', '$2', '$4', " . spad($3) . "] # $stops->{$4}->{stop_name}"/ge;

	burp( 'timetables/route_' . $route->{route_id} . '.yml', $yaml);
}

burp( 'timetables/stops.yml', YAML::Dump( sort { $a->{stop_id} cmp $b->{stop_id} } values %$stops ) );

