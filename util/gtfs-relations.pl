#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  util/bkv-gtfs-create-relations.pl
#
#        USAGE:  ./bkv-gtfs-create-relations.pl $DIR $route_short_name(s) ...
#
#  DESCRIPTION:  Creates route_master & route relations for the specified routes.
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  08/07/2011 11:17:43 AM
#     REVISION:  ---
#===============================================================================

use 5.10.0;
use utf8;
use strict;
use warnings;
no warnings qw(numeric);
use autodie;

my ($osm_file, $DIR, $ref_tag) = (shift, shift, shift);

binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

use Data::Dumper;
use Text::CSV::Encoded;

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

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

my ( $file, $agencies, $routes, $trips, $stops, $stop_names, $shapes );

my $needed = { map { $_ => 1 } @ARGV };
my $skip = {};

open( $file, "$DIR/agency.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $id, $name ) = ( $cols->{agency_id}, $cols->{agency_name} );
	$agencies->{$id} = $name;

}

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $id, $ref, $agency, $name )
		= ( $cols->{route_id}, $cols->{route_short_name}, $agencies->{ $cols->{agency_id} }, $cols->{route_long_name} );

	given( $cols->{route_type} ) {
		when(0) {
			$routes->{$id} = [ $id, $ref, 'tram', $agency, $name ];
		}
		when(3) {
			$routes->{$id} = [ $id, $ref, 'bus', $agency, $name ];
		}
		when(800) {
			$routes->{$id} = [ $id, $ref, 'trolleybus', $agency, $name ];
		}
		default {
			warn $id;
		}
	}
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $route, $id ) = ( $cols->{route_id}, $cols->{trip_id} );
	warn $_ unless $route;
	next unless $routes->{$route};

	$trips->{$id} = $routes->{$route};
}

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	state( $cur_id, $shape );

	my ( $trip, $stop ) = ( $cols->{trip_id}, $cols->{stop_id} );
	next unless $trips->{$trip};

	if ( !$cur_id || $cur_id ne $trip ) {
		$shapes->{ $trips->{$cur_id}->[0] }->{$shape} = 1 if $shape;
		$shape                                        = '';
		$cur_id                                       = $trip;
	}

	$shape .= ( $shape ? '-' : '' ) . $stop;
}

open( $file, "$DIR/stops.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $stop, $name ) = ( $cols->{stop_id}, $cols->{stop_name} );
	$stop_names->{$stop} = $name;
}

my $t = XML::Twig->new(
	twig_handlers => {
		node     => \&node,
		relation => \&relation
	},
);

# ./osmosis-0.39/bin/osmosis --read-xml hungary-current.osm.bz2 --bounding-box top=47.702 right=19.391 bottom=47.124 left=18.842 --write-xml hungary-pest.osm
$t->parsefile( $osm_file );
$t->purge;

sub tags
{
	my $section = shift;
	my $tag     = {};

	for ( $section->get_xpath("tag") ) {
		$tag->{ $_->att('k') } = $_->att('v');
	}

	return $tag;
}

sub node
{
	my ( $t, $section ) = @_;    # arguments for all twig_handlers
	my $tag = tags($section);

	return
		unless ( ( $tag->{highway} && $tag->{highway} eq 'bus_stop' )
		|| ( $tag->{railway} && $tag->{railway} =~ m/^(?:halt|tram_stop)$/ ) )
		&& $tag->{$ref_tag};

	for ( split ';', $tag->{$ref_tag} ) {
		$stops->{$_} = [ 'node', $section->att('id'), $tag->{railway} ? 'stop' : 'platform',
			$tag->{name} ];
	}

	$section->purge;
}

sub relation
{
	my ( $t, $section ) = @_;
	my $tag = tags($section);

	if (   $tag->{route_master}
		&& $tag->{operator}
		&& $tag->{ref} )
	{
		#$skip->{ $tag->{ref} } = 1;
		return;
	}

	return
		unless $tag->{type}
			&& $tag->{public_transport}
			&& $tag->{operator}
			&& $tag->{type}             eq 'public_transport'
			&& $tag->{public_transport} eq 'stop'
			&& $tag->{$ref_tag};

	for ( split ';', $tag->{$ref_tag} ) {
		$stops->{$_} = [ 'relation', $section->att('id'), 'stop', $tag->{name} ];
	}

	$section->purge;
}

print <<EOF;
<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="bkv-gtfs-create-relations.pl">
EOF

my $id = 1233211000;
for my $route ( keys %$shapes ) {
	next if $skip->{ $routes->{$route}->[1] };
	next if scalar @ARGV && not $needed->{ $routes->{$route}->[1] };

	print "\n\n<!-- ROUTE MASTER: $routes->{$route}->[2] $routes->{$route}->[1] -->\n";
	my ( $members, $content ) = ( '', '' );

	my $shapes = [ keys %{ $shapes->{$route} } ];
	$shapes = [
		grep {
			my $c = $_;
			none { $c ne $_ && $_ =~ m/$c/ } @$shapes
			} @$shapes
	];

	for (@$shapes) {
		my @stops = split '-', $_;

		$content .= <<EOF;
	<relation id="-$id" version="0" timestamp="2011-08-07T15:00:00Z">
		<tag k="deduplicated" v="no" />
		<tag k="type" v="route" />
		<tag k="route" v="$routes->{$route}->[2]" />
EOF
		if ( $routes->{$route}->[1] ) {
			$content .= <<EOF;
		<tag k="ref" v="$routes->{$route}->[1]" />
EOF
		}
		if ( $routes->{$route}->[4] ) {
			$content .= <<EOF;
		<tag k="name" v="$routes->{$route}->[4]" />
EOF
		}

		if ( $stops->{ $stops[0] } ) {
			$content .= <<EOF;
		<tag k="from" v="$stops->{$stops[0]}->[3]" />
EOF
		}
		if ( $stops->{ $stops[-1] } ) {
			$content .= <<EOF;
		<tag k="to" v="$stops->{$stops[-1]}->[3]" />
EOF
		}

		for (@stops) {
			if ( !$stops->{$_} ) {
				state $warned = {};
				warn "Missing stop $stop_names->{$_} ($_, $routes->{$route}->[1])\n" unless $warned->{"$_-$routes->{$route}->[1]"};
				$warned->{$_} = 1;
				next;
			}
			$content .= <<EOF;
		<member type="$stops->{$_}->[0]" ref="$stops->{$_}->[1]" role="$stops->{$_}->[2]" />
EOF
		}

		$content .= <<EOF;
	</relation>
EOF
		$members .= <<EOF;
		<member type="relation" ref="-$id" role="" />
EOF

		$id++;
	}

	print <<EOF;
	<relation id="-$id" version="0" timestamp="2011-08-07T15:00:00Z">
$members
		<tag k="type" v="route_master" />
		<tag k="route_master" v="$routes->{$route}->[2]" />
EOF

	if($routes->{$route}->[1]) {
		print <<EOF;
		<tag k="ref" v="$routes->{$route}->[1]" />
EOF
	}
	if($routes->{$route}->[4]) {
		print <<EOF;
		<tag k="name" v="$routes->{$route}->[4]" />
EOF
	}

	print <<EOF;
		<tag k="operator" v="$routes->{$route}->[3]" />
		<tag k="network" v="local" />
	</relation>

EOF

	print $content;

	$id++;
}

print <<EOF;
</osm>
EOF
