#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  gtfs-shapes.pl
#
#        USAGE:  ./shape-gpx.pl
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

my $shapes = {};
my $ways   = [];
my $way_l  = {};
my $nodes  = {};
my $node   = -100000;

my $dir = 'bkv/gtfs';

my ( $file, $routes, $lines );

open( $file, "$dir/routes.txt" );
binmode( $file, ':utf8' );
<$file>;
for (<$file>) {
	my ( $id, $route, $name, $type ) = ( $_ =~ m/^(.*?),.*?,(.*?),.*?,"(.*?)",(\d)/ );
	$routes->{$id} = $route || $name;
}

open( $file, "$dir/trips.txt" );
binmode( $file, ':utf8' );
<$file>;
for (<$file>) {
	chomp;
	my ( $route, $shape ) = ( $_ =~ m/^([^,]*),.*?,([^,]*)$/ );
	$lines->{$shape}->{ $routes->{$route} } = 1;
}

open( $file, "$dir/shapes.txt" );
binmode( $file, ':utf8' );
<$file>;
while (<$file>) {
	my ( $id, $lat, $lon, $seq, $dist ) = ( split ',', $_ );
	push @{ $shapes->{$id} }, [ $seq, $lat, $lon ];
}

print <<EOF;
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<osm version='0.6'>
EOF

for ( keys %$shapes ) {
	my @way = ($_);
	for ( sort { $a->[0] <=> $b->[0] } @{ $shapes->{$_} } ) {
		if ( $nodes->{ $_->[1] . "-" . $_->[2] } ) {
			push @way, $nodes->{ $_->[1] . "-" . $_->[2] };
		}
		else {
			push @way, $node;
			print <<EOF;
	<node id="$node" lat="$_->[1]" lon="$_->[2]" />
EOF
			$nodes->{ $_->[1] . "-" . $_->[2] } = $node;
			$node--;
		}
	}

	my $w = join ",", @way[1...$#way];
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
