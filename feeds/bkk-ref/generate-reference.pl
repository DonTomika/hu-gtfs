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
use HuGTFS::Util qw/burp slurp _S _T/;
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

my $route_skip = { map { $_ => 1 } qw/0337 1407 1738 6130 6210 6230 6470/ };
my $route_with_multiple_patterns = { map { $_ => 1 } qw/0405 1600 2170 2335 2545 2600 9940/ };
my $route_trip_map = {
	#'0000-1' => [qw/          /],
	'0660-0' => [qw/A894037466/],
	'0660-1' => [qw/A894037462/],
	'0920-0' => [qw/A9036969  /],
	'0920-1' => [qw/A9036939  /],
	'0930-0' => [qw/A8830740  /],
	'0930-1' => [qw/A8830732  /],
	'0975-0' => [[qw/A95405148 A91400209  /]],
	'0975-1' => [[qw/A94932207 A95405117  /]],
	'1160-0' => [qw/A89048656  /],
	'1160-1' => [[qw/A89048658 A89048659  /]],
	'1640-0' => [qw/A9523271  /],
	'1640-1' => [qw/A9523253  /],
	'1820-0' => [qw/A915366758/],
	'1820-1' => [qw/A94667986 /],
	'2015-0' => [qw/A94975353 /],
	'2015-1' => [qw/A89355199 /],
	'2500-0' => [[qw/A949121317 A957401294/]],
	'2500-1' => [[qw/A90413305  A94912787 /]],
	'2620-0' => [[qw/A94261538  A94261327 /]],
	'2620-1' => [[qw/A913936287 A951407826/]],
	'2765-0' => [[qw/A93192325  A93196482 /]],
	'2765-1' => [],
	'2810-0' => [qw/A9176076  /],
	'2810-1' => [],
	'2945-0' => [qw/A913338628/],
	'2945-1' => [qw/A93887228 /],
	'9180-0' => [qw/A8939691  /],
	'9180-1' => [qw/A8939618  /],
	'9310-0' => [qw/A885723   /],
	'9310-1' => [qw/A9531716  /],
	'9370-0' => [[qw/A9426335    A8794636  A8794637/]],
	'9500-0' => [[qw/A94977461  A8982629  /]],
	'9500-1' => [[qw/A9511765   A8977998  /]],
	'9980-0' => [[qw/A8880419   A888042   /]],
	'9980-1' => [[qw/A8880427   A8880428  /]],

	# temp
	'3020-0' => [qw/A9164262  /],
	'3020-1' => [qw/A91642103 /],
	'3240-0' => [qw/A94094162 /],
	'3240-1' => [qw/A9096250  /],
};

my $route_types = [qw/tram subway light_rail bus ferry/];

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
	$cols->{route_type} = $route_types->[$cols->{route_type}];
	$routes->{ $cols->{route_id} } = {%$cols};
}
close($file);

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $route, $id ) = ( $cols->{route_id}, $cols->{trip_id} );

	$trips->{$id} = {%$cols};
	push @{ $routes->{$route}->{trips} }, $trips->{$id};
}
close($file);

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my $trip = $trips->{ $cols->{trip_id} };

	push @{ $trip->{stop_times} }, {%$cols};
}
close($file);

open( $file, "$DIR/stops.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	next if $cols->{location_type};
	delete $cols->{parent_station};
	delete $cols->{location_type};
	delete $cols->{wheelchair_boarding};
	$stops->{ $cols->{stop_id} } = {%$cols};
}
close($file);

open( $file, "$DIR/shapes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	push @{ $shapes->{ $cols->{shape_id} } }, {%$cols};
}
close($file);

say STDERR "Creating patterns...";

foreach my $trip ( values %$trips ) { my $route = $routes->{ $trip->{route_id} };
	my $pattern = join '-', map { $_->{stop_id} } @{ $trip->{stop_times} };

	push @{ $route->{patterns}->{ $trip->{direction_id} }->{$pattern} }, $trip;
}

say STDERR "Comparing patterns...";

chdir($FindBin::Bin);

sub merge_trips {
	my ($id, $trip_a, $trip_b, $trip_c) = @_;
	$trip_a = $trips->{$trip_a} unless ref $trip_a;
	$trip_b = $trips->{$trip_b} unless ref $trip_b;
	$trip_c = $trips->{$trip_c} unless !$trip_c || ref $trip_c;

	cleanup_trip($trip_a, $id);
	cleanup_trip($trip_b, $id);

	my $time_offset = _S($trip_a->{stop_times}->[-1]->{arrival_time});
	$trip_a->{stop_times}->[-1]->{departure_time} = _T( $time_offset + _S( $trip_b->{stop_times}->[0]->{departure_time} ) );
	shift $trip_b->{stop_times};

	foreach my $st (@{ $trip_b->{stop_times} }) {
		$st->{arrival_time}   = _T( $time_offset + _S( $st->{arrival_time} ) );
		$st->{departure_time} = _T( $time_offset + _S( $st->{departure_time} ) );
		push $trip_a->{stop_times}, $st;
	}

	if($trip_a->{shape} && $trip_b->{shape}) {
		my $shape_dist_offset = $trip_a->{shape}->{shape_points}->[-1]->{shape_dist_traveled};

		foreach my $pt (@{ $trip_b->{shape}->{shape_points} } ) {
			$pt->{shape_dist_traveled} += $shape_dist_offset;
			push $trip_a->{shape}->{shape_points}, $pt;
		}
	}

	$trip_a->{trip_headsign} = $trip_b->{trip_headsign};

	if($trip_c) {
		return merge_trips( $id, $trip_a, $trip_c );
	}

	return $trip_a;
}

sub cleanup_trip
{
	my ($trip, $id) = @_;

	$trip->{trip_id} = $id;
	$trip->{service_id} = 'REFERENCE';

	delete $trip->{trips_bkk_ref};
	delete $trip->{route_id};
	delete $trip->{block_id};

	my $start = _S($trip->{stop_times}->[0]->{arrival_time});
	foreach my $st ( @{ $trip->{stop_times} } ) {
		$st->{arrival_time} = _T( _S( $st->{arrival_time} ) - $start )
			if $st->{arrival_time};
		$st->{departure_time} = _T( _S( $st->{departure_time} ) - $start )
			if $st->{departure_time};

		delete $st->{stop_sequence};
		delete $st->{trip_id};
	}

	if($trip->{shape_id}) {
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
	next if $route_skip->{$route->{route_id}};
	next if keys %$needed && !$needed->{$route->{route_id}};

	my @trips;
	my @dump_shapes;

	foreach my $dir ( sort keys %{ $route->{patterns} } ) {
		foreach my $p (keys %{ $route->{patterns}->{$dir} } ) {
			$route->{patterns}->{$dir}->{$p} = [ sort {$a->{trip_id} cmp $b->{trip_id}} @{ $route->{patterns}->{$dir}->{$p} }];
		}

		if ( $route_trip_map->{ join "-", $route->{route_id}, $dir } ) {
			my @route_trips = @{ $route_trip_map->{ join "-", $route->{route_id}, $dir } };
			for ( my $i = 0; $i < @route_trips; ++$i ) {
				if(ref $route_trips[$i] eq 'ARRAY') {
					push @trips,
						merge_trips( (join "-", "REFERENCE", $route->{route_id}, $dir, $i + 1), @{ $route_trips[$i] } );
				} else {
					push @trips,
						cleanup_trip( $trips->{ $route_trips[$i] },
						join "-", "REFERENCE", $route->{route_id}, $dir, $i + 1 );
				}
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

	foreach my $trip (@trips) {
		push @dump_shapes, $trip->{shape};
		$trip->{shape_id} = $trip->{shape}->{shape_id};
		delete $trip->{shape};
	}

	my $d_route = {
		(
			map { $_ => $route->{$_} }
				qw/route_id route_short_name route_long_name route_desc route_color route_text_color route_url agency_id route_type route_url/
		),
		trips => \@trips,
	};

	my $route_yaml = YAML::Dump($d_route);
	my $shape_yaml = YAML::Dump(sort { $a->{shape_id} cmp $b->{shape_id} } @dump_shapes);

	$route_yaml =~ s/- arrival_time: ([0-9:]+)\n\s*departure_time: \1\n\s*shape_dist_traveled: ([0-9.]+)\n\s*stop_id: (\w+)(?=\n(?:\s*trip_headsign|\s*-))/"- ['$1', '$3', " . spad($2) . "] # $stops->{$3}->{stop_name}"/ge;
	$route_yaml =~ s/- arrival_time: ([0-9:]+)\n\s*departure_time: ([0-9:]+)\n\s*shape_dist_traveled: ([0-9.]+)\n\s*stop_id: (\w+)(?=\n(?:\s*trip_headsign|\s*-))/"- ['$1', '$2', '$4', " . spad($3) . "] # $stops->{$4}->{stop_name}"/ge;

	$shape_yaml =~ s/- shape_dist_traveled: ([0-9.]+)\n\s*shape_pt_lat: ([0-9.]+)\n\s*shape_pt_lon: ([0-9.]+)/"- [".npad($2).", ".npad($3).", ".spad($1)."]"/ge;

	burp( "timetables/route_$route->{route_id}.yml", $route_yaml);
	burp( "timetables/shape_$route->{route_id}.yml", $shape_yaml);
}

if ( -f 'timetables/stops.yml' ) {
	my @stops = YAML::Load( slurp('timetables/stops.yml') );
	foreach my $stop (@stops) {
		$stops->{ $stop->{stop_id} } = $stop unless $stops->{ $stop->{stop_id} };
	}
}

my $yaml = YAML::Dump( sort { $a->{stop_id} cmp $b->{stop_id} } values %$stops );

$yaml =~ s/stop_id: (.*)/stop_id:  $1\nstop_code: $1/g;
$yaml =~ s/stop_lat:/stop_lat: /g;
$yaml =~ s/stop_lon:/stop_lon: /g;

burp( 'timetables/stops.yml', $yaml );

