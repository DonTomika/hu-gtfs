#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  mapnik_preprocess.pl
#
#        USAGE:  ./mapnik_preprocess.pl [osm-file]
#
#  DESCRIPTION:  Preprocess an *.osm xml file for rendering routes with mapnik.
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  08/15/2011 09:53:09 AM
#     REVISION:  ---
#===============================================================================

use 5.14.0;
use utf8;
use strict;
use warnings;

binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

BEGIN {
	use Log::Log4perl;

	my $conf = q(
    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 1
    log4perl.appender.Screen.layout  = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Screen.layout.ConversionPattern = %d{HH:mm}-%p %m{chomp}%n

    log4perl.category.HuGTFS         = INFO, Screen
);

	Log::Log4perl::init( \$conf );
}

use FindBin;
use lib "$FindBin::Bin/../lib";

use Data::Dumper;
use Geo::OSM::OsmReaderV6;
use HuGTFS::OSMMerger;

my $osmfile = $ARGV[0] || '/home/flaktack/osm/hungary-current.osm.bz2';

my ( $route_master_relations, $route_relations, $ways, $nodes );
my ( $masters, $routes, $processed_segments, $segments );

my $pr = sub {
	my $e = shift;

	$route_master_relations->{ $e->id } = $e
		if $e->isa('Geo::OSM::Relation')
			&& $e->tag('type')
			&& $e->tag('type') eq 'route_master';

	$route_relations->{ $e->id } = $e
		if $e->isa('Geo::OSM::Relation')
			&& $e->tag('type')
			&& $e->tag('type') eq 'route';

	$ways->{ $e->id } = $e
		if $e->isa('Geo::OSM::Way');
};

unless ( Geo::OSM::OsmReader->init($pr)->load($osmfile) ) {
	warn "Failed to parse osm: ...";
}

for my $rm ( values %$route_master_relations ) {
	for ( grep { $_->role ne 'depot' } $rm->members ) {
		my $r = $route_relations->{ $_->ref };
		$r->set_tag( 'operator', $rm->tag('operator') ) unless $r->tag('operator');

		$HuGTFS::OSMMerger::LS_REL = $r->id;

		$routes->{ $r->id } = {
			relation => $r,
			route    => $r->tag('route'),
			operator => $r->tag('operator'),
			ref      => $r->tag('ref'),
			nodes    => [
				HuGTFS::OSMMerger::sort_ways(
					map {
						      $_->member_type eq 'way' && !$_->role && $ways->{ $_->ref }
							? $ways->{ $_->ref }
							: ()
						} $r->members
				)
			]
		};

		my $p;
		$routes->{ $r->id }->{nodes} = [ map { my $r = $p && $p eq $_; $p = $_; $r ? () : $_ }
				@{ $routes->{ $r->id }->{nodes} } ];

		for ( @{ $routes->{ $r->id }->{nodes} } ) {
			state $prev;
			if ($prev) {
				$nodes->{$_} = 1;
				$segments->{ $_ . '-' . $prev } = {} unless $segments->{ $_ . '-' . $prev };
				$segments->{ $prev . '-' . $_ }
					->{ $r->tag('operator') . "`" . $r->tag("route") . "`" . ($r->tag("ref") || $r->tag("name")) }
					= 1;
			}
			$prev = $_;
		}
	}
}
( $route_master_relations, $route_relations, $ways ) = ( undef, undef, undef );

for ( keys %$segments ) {
	$segments->{$_} = join "´", sort keys %{ $segments->{$_} };
}

print <<EOF;
<?xml version='1.0' encoding='UTF-8'?>
<osm version="0.6" generator="">
EOF

$pr = sub {
	my $e = shift;

	print $e->xml
		if $e->isa('Geo::OSM::Node') && $nodes->{ $e->id };
};

unless ( Geo::OSM::OsmReader->init($pr)->load($osmfile) ) {
	warn "Failed to parse osm: ...";
}

for ( values %$routes ) {
	state $way_id = 1;

	# Find longest segments w/ same references
	my ( @nodes, $prev, $cur );
	for ( @{ $_->{nodes} } ) {
		$cur = $_;
		next unless ($prev);

		if (   $processed_segments->{ $prev . '-' . $cur }
			|| $processed_segments->{ $cur . '-' . $prev } )
		{
			if ( scalar @nodes ) {
				handle_nodes( \@nodes, $way_id );

				@nodes = ();
			}

			next;
		}

		unless ( scalar @nodes ) {
			@nodes = ($prev);
		}
		elsif ($segments->{ $prev . '-' . $cur } ne $segments->{ $nodes[0] . '-' . $nodes[1] }
			|| $segments->{ $cur . '-' . $prev } ne $segments->{ $nodes[1] . '-' . $nodes[0] } )
		{
			handle_nodes( \@nodes, $way_id );

			@nodes = ($prev);
		}

		push @nodes, $cur;

		$processed_segments->{ $prev . '-' . $cur }
			= $processed_segments->{ $cur . '-' . $prev } = 1;
	}
	continue {
		$prev = $cur;
	}

	if ( scalar @nodes ) {
		handle_nodes( \@nodes, $way_id );
	}

	# Create fake way for route
	my $way = Geo::OSM::Way->new(
		{
			id        => $way_id,
			timestamp => '2010-03-26T06:57:06Z',
		},
		{
			route    => $_->{route},
			operator => $_->{operator},
			ref      => $_->{ref},
		},
		$_->{nodes}
	);

	print $way->xml;

	$way_id++;
}

print <<EOF;
</osm>
EOF

sub handle_nodes
{
	my ($nodes) = @_;

	my $p_segment = $nodes->[0] . '-' . $nodes->[1];
	my $a_segment = $nodes->[1] . '-' . $nodes->[0];
	my ( $h, $m, $o, $p, $r );

	$o = $segments->{$p_segment} && !$segments->{$a_segment};
	$m = join "´", keys %{
		{
			map { $_ => 1 } split "´", $segments->{$p_segment} . "´" . $segments->{$a_segment}
		}
		};
	$h = join '  ', ref_sort( map { (m/^(.*)`(.*)`(.*)$/)[2] } split "´", $m );
	$r = join ';',  ref_sort( map { (m/^(.*)`(.*)`(.*)$/)[1] } split "´", $m );
	$p = join ';',  ref_sort( map { (m/^(.*)`(.*)`(.*)$/)[0] } split "´", $m );

	my $way = Geo::OSM::Way->new(
		{
			id        => $_[1]++,
			timestamp => '2010-03-26T06:57:06Z',
		},
		{
			route_label => 'line',
			route       => $r,
			operator    => $p,
			ref         => $h,
			oneway      => $o ? 'yes' : 'no',
		},
		$nodes,
	);
	print $way->xml;

	$_[1]++;

	$way = Geo::OSM::Way->new(
		{
			id        => $_[1]++,
			timestamp => '2010-03-26T06:57:06Z',
		},
		{
			route_label         => 'label',
			route_label_machine => $m,
			ref                 => $h,
			oneway              => $o ? 'yes' : 'no',
		},
		$nodes,
	);
	print $way->xml;

	$_[1]++;
}

sub ref_sort
{
	no warnings qw(numeric);
	return sort { $a <=> $b || $a cmp $b } keys %{ { map { $_ => 1 } @_ } };
}

