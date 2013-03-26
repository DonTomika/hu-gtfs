#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  gtfs-shapes.pl
#
#        USAGE:  ./gtfs-shapes.pl [gtfs-dir]
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
#      CREATED:  07/02/2011 08:12:02 PM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;
use 5.12.0;

use Data::Dumper;
use Text::CSV::Encoded;

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
	}
);

my $shapes = {};
my $ways   = [];
my $way_l  = {};
my $nodes  = {};
my $node   = -100000;

my $DIR = $ARGV[0] || 'feeds/bkv/gtfs';

my ( $file, $routes, $lines );

sub remove_bom(@);

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$routes->{ $cols->{route_id} } = $cols->{route_short_name} || $cols->{route_long_name};
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$lines->{ $cols->{shape_id} }->{ $routes->{ $cols->{route_id} } } = 1;
}

open( $file, "$DIR/shapes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $id, $lat, $lon, $seq, $dist )
		= ( map { $cols->{$_} }
			qw/shape_id shape_pt_lat shape_pt_lon shape_pt_sequence shape_dist_traveled/ );
	push @{ $shapes->{$id} }, [ $seq, $lat, $lon ];
}

print <<EOF;
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<osm version='0.6'>
EOF

for ( keys %$shapes ) {
	my @way = ($_);
	for ( sort { $a->[0] <=> $b->[0] } @{ $shapes->{$_} } ) {
		my $nkey = $_->[1] . "-" . $_->[2];
		if ( $nodes->{$nkey} ) {
			push @way, $nodes->{$nkey};
		}
		else {
			push @way, $node;
			print <<EOF;
	<node id="$node" lat="$_->[1]" lon="$_->[2]" />
EOF
			$nodes->{$nkey} = $node;
			$node--;
		}
	}

	my $w = join ",", @way[ 1 ... $#way ];
	if ( $way_l->{$w} ) {
		$way_l->{$w}->[0] .= ', ' . $way[0];
		$lines->{ $way_l->{$w}[0] }->{$_} = 1 for ( keys %{ $lines->{ $way[0] } } );
	}
	else {
		$way_l->{$w} = \@way;
		push @$ways, \@way;
	}
}

for (@$ways) {
	my $id = shift @$_;
	print <<EOF;
	<way id="$node">
EOF

	for (@$_) {
		print <<EOF;
		<nd ref='$_' />
EOF
	}

	my $l = join ", ", sort { $a <=> $b || $a cmp $b } keys %{ $lines->{$id} };
	print <<EOF;
		<tag k="name" v="$id" />
		<tag k="lines" v="$l" />
	</way>
EOF

	$node--;
}

print <<EOF;
</osm>
EOF

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

