#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  util/gtfs-stops.pl
#
#        USAGE:  ./gtfs-stops.pl $gtfs_dir
#                cat stops.txt | ./gtfs-stops.pl $gtfs_dir -
#
#  DESCRIPTION:  Converts a GTFS stops.txt to an OpenStreetMap file, with the
#                appropriate tags.
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  07/04/2011 06:07:45 AM
#     REVISION:  ---
#===============================================================================

use 5.10.0;
use utf8;
use strict;
use warnings;
no warnings qw(numeric);
use autodie;

binmode( STDOUT, ':utf8' );

use Data::Dumper;
use Text::CSV::Encoded;

my $DIR = shift || 'tmp';

my (
	$file,      $agencies, $routes,      $route_types, $route_agency, $trips,
	$trips_all, $stops,    $stop_agency, $types,       $trip_num
);

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
	}
);

sub remove_bom(@);

open( $file, "$DIR/agency.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $id, $name ) = ( $cols->{agency_id}, $cols->{agency_name} );
	$agencies->{$id} = $name;

}

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $id, $name, $agency ) = (
		$cols->{route_id},
		$cols->{route_short_name} || $cols->{route_long_name},
		$agencies->{ $cols->{agency_id} }
	);
	$route_agency->{$id} = $agency;
	$routes->{$id} = $name if $agency !~ m/^BK[KV]$/ || $id =~ m/^[012345689]/;

	if ( $route_agency->{$id} =~ m/^BK[KV]$/ ) {
		given ($id) {
			when (m/^[01249]/) {
				$route_types->{$id} = 'bus';
			}
			when (m/^[4]/) {
				$route_types->{$id} = 'trolleybus';
			}
			when (m/^3/) {
				$route_types->{$id} = 'tram';
			}
			when (m/^5/) {
				$route_types->{$id} = 'subway';
			}
			when (m/^6/) {
				$route_types->{$id} = 'light_rail';
			}
			when (m/^8/) {
				$route_types->{$id} = 'ferry';
			}
		}
	}
	else {
		given ( $cols->{route_type} ) {
			when ('0') {
				$route_types->{$id} = 'tram';
			}
			when ('1') {
				$route_types->{$id} = 'light_rail';
			}
			when ('3') {
				if($route_agency->{$id} eq 'SZKT') {
					$route_types->{$id} = 'trolleybus';
				} else {
					$route_types->{$id} = 'bus';
				}
			}
			when ('4') {
				$route_types->{$id} = 'ferry';
			}
			when ('800') {
				$route_types->{$id} = 'trolleybus';
			}
		}
	}
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $route, $id ) = ( $cols->{route_id}, $cols->{trip_id} );
	next unless $routes->{$route};

	$trip_num->{ $routes->{$route} }++;
	$trips->{$id} = $route;
}

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $trip, $stop ) = ( $cols->{trip_id}, $cols->{stop_id} );

	if ( $trips->{$trip} ) {
		$stops->{$stop}->{ $routes->{ $trips->{$trip} } }++;
		$types->{$stop}->{ $route_types->{ $trips->{$trip} } } = 1;
		$stop_agency->{$stop}->{ $route_agency->{ $trips->{$trip} } } = 1;
	}
}

foreach my $s ( keys %$stops ) {
	next unless $stop_agency->{$s}->{BKV} || $stop_agency->{$s}->{BKK};

	foreach my $r ( keys %{ $stops->{$s} } ) {
		delete $stops->{$s}->{$r} if $stops->{$s}->{$r} < $trip_num->{$r} * 0.05;
	}
}

print <<EOF;
<?xml version='1.0' encoding='UTF-8'?>
<osm version='0.6' generator='JOSM'>
EOF

if($ARGV[0] && $ARGV[0] eq '-') {
	*$file = *STDIN;
} else {
	open( $file, "$DIR/stops.txt" );
}
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $stop, $code, $name, $lat, $lon, $type, $zone ) = (
		$cols->{stop_id},  $cols->{stop_code}, $cols->{stop_name},
		$cols->{stop_lat}, $cols->{stop_lon},  $cols->{location_type},
		$cols->{zone_id},
	);

	next if $type;
	next unless ( $types->{$stop} );

	state $i = -1;

	print <<EOF;
	<node id='$i' lat='$lat' lon='$lon'>
		<tag k='ref:bkv' v='$code' />
		<tag k='name' v='$name' />
		<tag k='verified' v='no' />
		<tag k='deduplicated' v='no' />
EOF

	if ( $zone ) {
		print "\t\t<tag k='gtfs:zone_id' v='$zone' />\n";
	}

	print "\t\t<tag k='operator' v='"
		. ( join ';', sort keys %{ $stop_agency->{$stop} } )
		. "' />\n";

	print "\t\t<tag k='lines' v='"
		. ( join ', ', sort { $a <=> $b || $a cmp $b } keys %{ $stops->{$stop} } )
		. "' />\n"
		if scalar keys %{ $stops->{$stop} };

	if ( $types->{$stop}->{trolleybus} ) {
		print "\t\t<tag k='trolleybus' v='yes' />\n";
	}
	if ( $types->{$stop}->{bus} || $types->{$stop}->{trolleybus}) {
		print "\t\t<tag k='highway' v='bus_stop' />\n";
	}
	if ( $types->{$stop}->{tram} ) {
		print "\t\t<tag k='railway' v='tram_stop' />\n";
	}
	elsif ( $types->{$stop}->{light_rail} || $types->{$stop}->{subway}) {
		if($types->{$stop}->{light_rail}) {
			print "\t\t<tag k='light_rail' v='yes' />\n";
		}
		if($types->{$stop}->{subway}) {
			print "\t\t<tag k='subway' v='yes' />\n";
		}
		print "\t\t<tag k='railway' v='halt' />\n";
	}
	if ( $types->{$stop}->{ferry} ) {
		print "\t\t<tag k='amenity' v='ferry_terminal' />\n";
	}

	print <<EOF;
	</node>
EOF

	$i--;
}

print <<EOF;
</osm>
EOF

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

