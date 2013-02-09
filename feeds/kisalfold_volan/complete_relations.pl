#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  complete_relations.pl
#
#        USAGE:  ./complete_relations.pl stops.osm route_*.xml ...
#
#  DESCRIPTION:  Fills out stops using ref:kisalfold in route relations...
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (), 
#      COMPANY:  
#      VERSION:  1.0
#      CREATED:  02/09/2013 08:07:00 AM
#     REVISION:  ---
#===============================================================================

use 5.14.0;
use utf8;
use strict;
use warnings;
use Data::Dumper;

my $osmfile     = shift;
my $route_files = shift;

my ($STOPS, $RELATIONS);
my $NAMES = {
};

{
	open(my $OSM_READ, '<', $osmfile);

	my ($node_id, $rm, $rels);
	while(defined(my $line = <$OSM_READ>)) {
		if($line =~ m/<node id='(-?\d+)'/) {
			$node_id = $1;
			next;
		}
		if($node_id && $line =~ m/k='ref:kisalfold' v='([A-Z0-9;]+)'/) {
			for(split /;/, $1) {
				$STOPS->{$_} = $node_id;
			}
			next;
		}
		if($node_id && $line =~ m/k='name' v='(.*?)'/) {
			$NAMES->{$node_id} = $1;
			next;
		}
		if($node_id && $line =~ m/<\/node/) {
			undef $node_id;
			next;
		}

		if($line =~ m/<relation/) {
			$rm = 1;
			next;
		}
		if($rm && $line =~ m/<member type='relation' ref='(\d+)' role='(inbound|outbound)'/) {
			$rels->{$2} = $1;
			next;
		}
		if($rm && $rels && $line =~ m/k='ref' v='(\w+)'/) {
			for (keys %$rels) {
				$RELATIONS->{"$1-$_"} = { id => $rels->{$_}, stops => [], };
			}
		}
		if($line =~ m/<\/relation/) {
			undef $rm;
			undef $rels;
		}
	}

	close $OSM_READ;
}

for( glob( $route_files ) ) {
	open(my $ROUTE_READ, '<', $_);

	my ($line_id, $dir);
	while(defined(my $line = <$ROUTE_READ>)) {
		if(!$line_id && $line =~ m/<line id="(\w+)"/) {
			$line_id = $1;
			next;
		}
		if($line =~ m/<to>/) {
			$dir = 'outbound';
			next;
		}
		if($line =~ m/<back>/) {
			$dir = 'inbound';
			next;
		}
		if($line =~ m/<stop id="(\w+)"/) {
			push @{ $RELATIONS->{"$line_id-$dir"}->{stops} }, $STOPS->{$1};
			next;
		}
	}

	close($ROUTE_READ);
}

foreach my $k (keys %$RELATIONS) {
	$RELATIONS->{ $RELATIONS->{$k}->{id}} = $RELATIONS->{$k}->{stops};
	delete $RELATIONS->{$k};
}

{
	open(my $OSM_READ, '<', $osmfile);

	my ($route_rel);
	while(defined(my $line = <$OSM_READ>)) {
		if($line =~ m/<relation id='(\d+)'/) {
			if($RELATIONS->{$1}) {
				$route_rel = $1;
				$line =~ s/'(\d+)'/'$1' action='modify'/;
			}
		}
		unless ($route_rel) {
			print $line;
			next;
		}

		if($line =~ m/<member type='node' ref='(\d+)'/) {
			if($NAMES->{$RELATIONS->{$route_rel}[0]} eq $NAMES->{$1}) {
				shift $RELATIONS->{$route_rel};

				print $line;
				for(@{ $RELATIONS->{$route_rel}}) {
					say "    <member type='node' ref='$_' role='stop' />"
				}
			} else {
				pop $RELATIONS->{$route_rel};

				for(@{ $RELATIONS->{$route_rel}}) {
					say "    <member type='node' ref='$_' role='stop' />"
				}
				print $line;
			}

			undef $route_rel;
			next;
		}
		elsif($line =~ m/<tag/) {
			for(@{ $RELATIONS->{$route_rel}}) {
				say "    <member type='node' ref='$_' role='stop' />"
			}

			print $line;
			undef $route_rel;
			next;
		}

		print $line;
	}

	close($OSM_READ);
}

