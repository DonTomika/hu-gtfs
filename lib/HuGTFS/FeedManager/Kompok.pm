=head1 NAME

HuGTFS::FeedManager::Kompok - HuGTFS feed manager for simple ferries

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Kompok;

=head1 DESCRIPTION

Merges existing YaML gtfs data with OpenStreetMap route=ferry routes.

Supports exactly two stops for each trip.

=head1 METHODS

=cut

package HuGTFS::FeedManager::Kompok;

use 5.14.0;
use utf8;
use strict;
use warnings;

use HuGTFS::Util qw(entity_id);
use Geo::OSM::OsmReaderV6;

use Mouse;

extends 'HuGTFS::FeedManager::YaGTFS';
__PACKAGE__->meta->make_immutable;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 parse

Loads cached data and merges it with openstreetmap data as needed.

* stop_time:stop_time may be specified instead of arrival_time/departure_time
* trip:departures may be used instead-of/in-addition-to frequencies

=cut

override 'create_geometries' => sub {
	my $self = shift;

	# Load OSM data
	#  route=ferry ways + amenity=ferry_terminal endpoints

	my ( $nodes, $ways, $lines );
	my $pr_first = sub {
		my $e = shift;

		$nodes->{ $e->id } = $e
			if $e->isa("Geo::OSM::Node")
				&& $e->tag("amenity")
				&& $e->tag("amenity") eq "ferry_terminal";

		if ( $e->isa("Geo::OSM::Way") && $e->tag("route") && $e->tag("route") eq 'ferry' ) {
			$nodes->{$_} = $nodes->{$_} || 1 for $e->nodes;
			$ways->{ $e->id } = $e;

			delete $ways->{ $e->id }
				unless ref $nodes->{ $e->nodes->[0] } && ref $nodes->{ $e->nodes->[-1] };
		}
	};
	my $pr_second = sub {
		my $e = shift;

		$nodes->{ $e->id } = $e
			if $e->isa("Geo::OSM::Node") && $nodes->{ $e->id };
	};

	$log->info( "Reading osm data (stage one): " . $self->osm_file );

	unless ( Geo::OSM::OsmReader->init($pr_first)->load( $self->osm_file ) ) {
		$log->logdie( "Failed to parse osm file: " . $self->osm_file );
	}

	$log->info( "Reading osm data (stage two): " . $self->osm_file );
	unless ( Geo::OSM::OsmReader->init($pr_second)->load( $self->osm_file ) ) {
		$log->logdie( "Failed to parse osm file: " . $self->osm_file );
	}

	$log->info("Parsing osm data...");

	for ( values %$ways ) {
		my @n = map { $nodes->{$_} } $_->nodes;

		# Avoid ferry routes w/o names
		next unless $n[0]->tag("name") && $n[-1]->tag("name");

		$lines->{ $n[0]->tag("name") . "#" . $n[-1]->tag("name") } = \@n;
	}

	for ( keys %$lines ) {
		my ( $a, $b ) = split /#/;
		next if $lines->{"$b#$a"};

		$lines->{"$b#$a"} = [ reverse @{ $lines->{$_} } ];
	}

	# Map OSM data to GTFS
	foreach my $route ( values %{ $self->data->{routes} } ) {
		for( my $k = $#{ $route->{trips} }; $k >= 0; --$k) {
			my $trip = $route->{trips}->[$k];
			my $l = $trip->{stop_times}->[0]->{stop_name} . '#'
				. $trip->{stop_times}->[1]->{stop_name};

			unless ( $lines->{$l} ) {
				$log->warn("No ferry route found for: $l");
				splice( @{ $route->{trips} }, $k, 1);
				next;
			}

			$l = $lines->{$l};

			unless ( $self->data->{stops}->{ entity_id( $l->[0] ) } ) {
				$self->data->{stops}->{ entity_id( $l->[0] ) } = create_stop( $l->[0] );
			}
			unless ( $self->data->{stops}->{ entity_id( $l->[-1] ) } ) {
				$self->data->{stops}->{ entity_id( $l->[-1] ) } = create_stop( $l->[-1] );
			}

			$trip->{stop_times}->[0]->{stop_id} = entity_id( $l->[0] );
			$trip->{stop_times}->[1]->{stop_id} = entity_id( $l->[-1] );
			delete $trip->{stop_times}->[0]->{stop_name};
			delete $trip->{stop_times}->[1]->{stop_name};

			{
				my $i = -1;
				$trip->{shape} = {
					shape_id     => 'SHAPE_' . $trip->{trip_id},
					shape_points => [
						map {
							$i++;
							{
								shape_pt_sequence   => $i,
								shape_dist_traveled => $i,
								shape_pt_lon        => $_->lon,
								shape_pt_lat        => $_->lat,
							};
							} @$l
					]
				};
				$trip->{stop_times}->[0]->{shape_dist_traveled} = 0;
				$trip->{stop_times}->[1]->{shape_dist_traveled} = $i;
			}
		}
	}
};

sub create_stop
{
	my $e = shift;

	return {
		stop_id         => entity_id($e),
		stop_name       => $e->tag("name"),
		stop_lon        => $e->lon,
		stop_lat        => $e->lat,
		stop_osm_entity => entity_id($e),
	};
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
