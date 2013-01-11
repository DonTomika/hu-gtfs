
=head1 NAME

HuGTFS::ShapeFinder - Creates shapes for a trip based on its stops

=head1 SYNOPSIS

	use HuGTFS::ShapeFinder;

=head1 REQUIRES

perl 5.14.0, OSRM

=head1 EXPORTS

Nothing.

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::ShapeFinder;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Digest::MD5 qw(md5_hex);
use DateTime;
use Encode qw(encode_utf8);
use Geo::OSM::OsmReaderV6;
use Unicode::Normalize;
use Digest::SHA qw(sha256_hex);
use Log::Log4perl;
use HuGTFS::Util qw(:utils);
use HuGTFS::OSMMerger qw//;
use JSON qw/decode_json/;

my $log = Log::Log4perl::get_logger(__PACKAGE__);

=head2 new %options

=head3 Options

=over 2

=item osm_filer

The OSM file to parse.

=item operator

The operator for which to extract data.

=back

=cut

sub new
{
	my ( $class, %options ) = @_;
	my $self = bless { cache => {}, }, $class;

	$self->{options} = {
		data => undef,

		# highway
		bus_url_base        => 'http://localhost:5000/viaroute?output=json&instructions=false&compression=false',
		trolleybus_url_base => 'http://localhost:5000/viaroute?output=json&instructions=false&compression=false',

		# railway
		tram_url_base       => 'http://localhost:5002/viaroute?output=json&instructions=false&compression=false',
		light_rail_url_base => 'http://localhost:5001/viaroute?output=json&instructions=false&compression=false',
		subway_url_base     => 'http://localhost:5001/viaroute?output=json&instructions=false&compression=false',
		rail_url_base       => 'http://localhost:5001/viaroute?output=json&instructions=false&compression=false',
		narrow_gauge_url_base =>
			'http://localhost:5001/viaroute?output=json&instructions=false&compression=false',

		mech => WWW::Mechanize->new,
		%options
	};

	$self->{gtfs} = $options{gtfs};

	return $self;
}

=head2 create_shapes @trips

=cut

sub create_shapes
{
	my ( $self, @trips ) = @_;
	my $data = $self->{options}->{data};

	if ( ref $trips[0] eq 'HASH' && $trips[0]->{stops} ) {
		$data = shift @trips;
	}

	$self->create_shape( $_, $data ) for @trips;
}

=head2 create_shape $trip [, $data]

=cut

sub create_shape
{
	my ( $self, $trip, $data ) = @_;
	$data ||= $self->{options}->{data};

	my $route = $trip->{route} || $self->{gtfs}->{routes}->{ $trip->{route_id} };
	my $url = $self->{options}->{ $route->{route_type} . '_url_base' };

	my @stop_points = ();

	my $right_only = ($route->{route_type} =~ m/^(?:bus|trolleybus)$/);
	$url .= '&side=right' if $right_only;

	for ( @{ $trip->{stop_times} } ) {
		my $stop
			= $_->{stop_lat}
			? $_
			: (    $data->{stops}->{ $_->{stop_id} }
				|| $self->{gtfs}->{stops}->{ $_->{stop_id} } );

		my ( $lat, $lon ) = (
			$stop->{stop_lat} || $stop->{stop_point_lat},
			$stop->{stop_lon} || $stop->{stop_point_lon}
		);

		unless($stop && $lat && $lon) {
			$log->warn("Missing stop data: " . ($stop ? $stop->{stop_id} : $_->{stop_id}));
			return 0;
		}

		if (
			   $stop->{stop_point_lat}
			&& $stop->{stop_point_lon}
			&& $stop->{stop_lat}
			&& $stop->{stop_lon}
			&& (   $stop->{stop_point_lat} != $stop->{stop_lat}
				|| $stop->{stop_point_lon} != $stop->{stop_lon} )
			)
		{
			$url
				.= "&loc=$stop->{stop_point_lat},$stop->{stop_point_lon}:$stop->{stop_lat},$stop->{stop_lon}";
		}
		elsif ( $stop->{stop_point_lat} && $stop->{stop_point_lon} ) {
			$url .= "&loc=$stop->{stop_point_lat},$stop->{stop_point_lon}";
		}
		else {
			$url .= "&loc=$stop->{stop_lat},$stop->{stop_lon}";
		}

		push @stop_points, [ $_, $lat, $lon, undef, $_->{shape_dist_traveled}, undef, $stop ];
	}

	#$url =~ s/^(.*?)&via=(.*)&via=(.*?)$/$1&start=$2&dest=$3/;

	#die join("\n&", split('&', $url));

	if ( exists $self->{cache}->{$url} ) {
		if ( $self->{cache}->{$url} ) {
			$trip->{shape_id} = $self->{cache}->{$url};
			return 2;
		}

		return undef;
	}
	$self->{cache}->{$url} = undef;

	eval { $self->{options}->{mech}->get($url); };
	if ($@) {
		$log->warn("Error find shapes: $@");
		return undef;
	}

	my $json = eval { decode_json( $self->{options}->{mech}->content ) };
	if ($@) {
		$json = { status => '1', status_message => "JSON Decode error: $@" };
	}

	if ( $json->{status} ne '0' ) {
			$log->fatal("Failed to find shape ($trip->{trip_id}, $route->{route_id}): $json->{status_message}\n\t$url");
		return undef;
	}

	my @linestring = @{ $json->{route_geometry} };

	my $p = HuGTFS::OSMMerger::expand_linestring( \@linestring, \@stop_points, $right_only );
	if ( $p < 1 ) {
		my $missing = "Unmatched:";
		for my $i (0 .. $#stop_points) {
			next if defined $stop_points[$i][3];
			my $stop_text = "$stop_points[$i][6]{stop_name}" . ($stop_points[$i][6]{stop_code} ? " ($stop_points[$i][6]{stop_code})" : "");
			#$missing .= " [$i, " . ($stop_points[$i][5] ? "$stop_points[$i][5], " : "") . "$stop_points[$i][6]{stop_name}]";
			$missing .= "\n\t\t[$i, " . ($stop_points[$i][5] ? "$stop_points[$i][5], " : "") . "$stop_text]";
		}
		$log->warn("Imperfect match ($p): $trip->{trip_id}, $route->{route_id}\n\t$missing\n\t$url");
		#print Data::Dumper::Dumper( \@stop_points );
		return undef;
	}

	$trip->{shape} = {
		shape_id     => 'HUGTFS_SHAPEFINDER_' . $trip->{trip_id},
		shape_points => [],
	};

	my $prev_stop = undef;
	foreach my $stop (@stop_points) {
		unless ($prev_stop) {
			$prev_stop = $stop;
			next;
		}

		if ( defined $prev_stop->[3] && defined $stop->[3] ) {
			my $j = 0;
			for ( my $i = $prev_stop->[3]; $i < $stop->[3]; $i++ ) {
				push @{ $trip->{shape}->{shape_points} },
					{
					shape_pt_lat        => $linestring[$i][0],
					shape_pt_lon        => $linestring[$i][1],
					shape_dist_traveled => $prev_stop->[4] + $j / 10000,
					};

				$j++;
			}
		}
		elsif ( defined $prev_stop->[3]) {
			my $i = $prev_stop->[3];
			push @{ $trip->{shape}->{shape_points} },
				{
				shape_pt_lat        => $linestring[$i][0],
				shape_pt_lon        => $linestring[$i][1],
				shape_dist_traveled => $prev_stop->[4],
				};
		}
		else {
			push @{ $trip->{shape}->{shape_points} },
				{
				shape_pt_lat        => $prev_stop->[1],
				shape_pt_lon        => $prev_stop->[2],
				shape_dist_traveled => $prev_stop->[4],
				};
		}

		$prev_stop = $stop;
	}

	if ( defined $stop_points[-2]->[3] && $stop_points[-1]->[3] ) {
		( my $stop, $prev_stop ) = ( $stop_points[-1], $stop_points[-2] );

=pod
		my $j = 0;
		for ( my $i = $prev_stop->[3]; $i < $stop->[3]; $i++ ) {
			push @{ $trip->{shape}->{shape_points} },
				{
				shape_pt_lat        => $linestring[$i][0],
				shape_pt_lon        => $linestring[$i][1],
				shape_dist_traveled => $prev_stop->[4] + $j / 10000,
				};

			$j++;
		}
=cut
		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $linestring[ $stop->[3] ][0],
			shape_pt_lon        => $linestring[ $stop->[3] ][1],
			shape_dist_traveled => $stop->[4],
			};
	}
	else {
		( my $stop, $prev_stop ) = ( $stop_points[-1], $stop_points[-2] );

=pod
		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $prev_stop->[1],
			shape_pt_lon        => $prev_stop->[2],
			shape_dist_traveled => $prev_stop->[4],
			};
=cut
		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $stop->[1],
			shape_pt_lon        => $stop->[2],
			shape_dist_traveled => $stop->[4],
			};
	}

	$self->{cache}->{$url} = $trip->{shape}->{shape_id};

	return 1;
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
