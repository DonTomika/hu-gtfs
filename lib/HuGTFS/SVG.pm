=head1 NAME

HuGTFS::SVG - GTFS->SVG converter used within HuGTFS

=head1 SYNOPSIS

	use HuGTFS::SVG;

	HuGTFS::SVG->convert($dest_svg, @gtfs_feeds);
	
=head1 REQUIRES

perl 5.14.0, Text::CSV::Encoded, Archive::ZIP, IO::File, SVG

=head1 DESCRIPTION

Simple module for creating SVG files from gtfs feeds.

=head1 METHODS

=cut

package HuGTFS::SVG;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Carp qw/ carp cluck confess croak /;

use IO::String;
use Text::CSV::Encoded;
use IO::File;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Data::Dumper;
use HuGTFS::Cal;
use HuGTFS::Util qw/ burp _TX _T _S /;
use SVG;

=head2 convert $svg_file, @feeds

Convert a GTFS feed's trips into an SVG animation for the specified time interval.

=cut

sub convert
{
	my $class = shift;
	my $kml   = shift;
	my $args  = shift;
	my @files = @_;

	binmode( STDOUT, ':utf8' );
	binmode( STDERR, ':utf8' );
	binmode( STDIN,  ':utf8' );
	local $| = 1;

	my ( $WIDTH, $HEIGHT, $RADIUS, $SPEED, $FPS, $BUFFER )
		= ( 1280, 720, 2, $args->{speed} || 60 * 6, $args->{fps} || 10, $args->{buffer} || 2 );

	my $CSV = Text::CSV::Encoded->new(
		{
			encoding_in  => 'utf8',
			encoding_out => 'utf8',
			sep_char     => ',',
			quote_char   => '"',
			escape_char  => '"',
			eol          => "\r\n",
		}
	);

	my ( $minx, $miny, $maxx, $maxy ) = ( 100, 100, 0, 0 );
	my ( $starttime, $endtime ) = ( DateTime->today, DateTime->now );

	#my $svg = SVG->new( width => 400, height => 300 );
	my $svg = SVG->new(
		height => $HEIGHT,
		width  => $WIDTH,
		-pubid => "-//W3C//DTD SVG 1.1//EN",
		-dtd   => "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd",
	);
	$svg->rect(
		width     => $WIDTH,
		height    => $HEIGHT,
		'z-index' => 0,
		fill      => 'black',
	);

	if ( $#files && !$args->{bbox} ) {
		die "A BBOX must be specified when using multiple gtfs feeds.";
	}

	if ( $args->{from} && $args->{to} ) {
	}
	else {
		$endtime->add( days => 1 );
		$endtime->truncate( to => 'day' );
	}

	while ( my $gtfs = shift @files ) {
		my $ZIP       = Archive::Zip->new();
		my $trip_dest = {};
		my ( $stops, $routes, $trips, $shapes, $stop_times, %paths ) = ( {}, {}, {}, {}, {} );

		unless ( $ZIP->read($gtfs) == AZ_OK ) {
			die 'read error';
		}

		my $io_routes     = IO::String->new( $ZIP->contents('routes.txt') );
		my $io_trips      = IO::String->new( $ZIP->contents('trips.txt') );
		my $io_stop_times = IO::String->new( $ZIP->contents('stop_times.txt') );
		my $io_shapes     = IO::String->new( $ZIP->contents('shapes.txt') );
		my $io_calendar   = IO::String->new( $ZIP->contents('calendar.txt') );
		my $io_calendar_d = IO::String->new( $ZIP->contents('calendar_dates.txt') );

		$CSV->column_names( $CSV->getline($io_routes) );
		while ( my $cols = $CSV->getline_hr($io_routes) ) {
			$routes->{ $cols->{route_id} } = $cols;
		}

		$CSV->column_names( $CSV->getline($io_calendar) );
		HuGTFS::Cal->empty;
		while ( my $cols = $CSV->getline_hr($io_calendar) ) {
			HuGTFS::Cal->new($cols);
		}

		$CSV->column_names( $CSV->getline($io_shapes) );
		while ( my $cols = $CSV->getline_hr($io_shapes) ) {
			unless ( $shapes->{ $cols->{shape_id} } ) {
				$shapes->{ $cols->{shape_id} } = [];
			}
			push @{ $shapes->{ $cols->{shape_id} } }, $cols;

			if ( !$args->{bbox} ) {    #!$bbox) {
				$minx = $cols->{shape_pt_lon} < $minx ? $cols->{shape_pt_lon} : $minx;
				$miny = $cols->{shape_pt_lat} < $miny ? $cols->{shape_pt_lat} : $miny;
				$maxx = $cols->{shape_pt_lon} > $maxx ? $cols->{shape_pt_lon} : $maxx;
				$maxy = $cols->{shape_pt_lat} > $maxy ? $cols->{shape_pt_lat} : $maxy;
			}
		}

		if ( $args->{bbox} ) {
			( $minx, $miny, $maxx, $maxy ) = split /,/, $args->{bbox};
		}

		$minx -= 0.02 * ( $maxx - $minx );
		$miny -= 0.02 * ( $maxy - $miny );
		$maxx += 0.02 * ( $maxx - $minx );
		$maxy += 0.02 * ( $maxy - $miny );

		for ( keys %$shapes ) {
			$shapes->{$_} = [ sort { $a->{shape_pt_sequence} <=> $b->{shape_pt_sequence} }
					@{ $shapes->{$_} } ];
		}

		$CSV->column_names( $CSV->getline($io_stop_times) );
		while ( my $cols = $CSV->getline_hr($io_stop_times) ) {
			unless ( $stop_times->{ $cols->{trip_id} } ) {
				$stop_times->{ $cols->{trip_id} } = [];
			}
			push @{ $stop_times->{ $cols->{trip_id} } }, $cols;
		}

		for ( keys %$stop_times ) {
			$stop_times->{$_} = [ sort { $a->{stop_sequence} <=> $b->{stop_sequence} }
					@{ $stop_times->{$_} } ];
		}

		$CSV->column_names( $CSV->getline($io_calendar_d) );
		while ( my $cols = $CSV->getline_hr($io_calendar_d) ) {
			HuGTFS::Cal->find( $cols->{service_id} )
				->add_exception( $cols->{date},
				$cols->{exception_type} eq '2' ? 'removed' : 'added' );
		}

		my $py = sub {
			my $y = shift;
			my $h = ( $maxy - $miny ) / 2;
			return ( ( -1 * ( $y - $miny - $h ) + $h ) / ( $maxy - $miny ) ) * $HEIGHT;
		};

		my $px = sub {
			my $x = shift;
			return ( ( $x - $minx ) / ( $maxx - $minx ) ) * $WIDTH;
		};

		my $ct = sub {
			my $t = shift;
			my @time = ( $t =~ m/^(\d{1,2}):(\d{2}):(\d{2})$/ );
			return $BUFFER + ( $time[0] * 60 * 60 + $time[1] * 60 + $time[2] ) / $SPEED;
		};

		$CSV->column_names( $CSV->getline($io_trips) );
		while ( my $trip = $CSV->getline_hr($io_trips) ) {
			my $start_date = '';
			unless ( HuGTFS::Cal->find( $trip->{service_id} )->enabled( DateTime->now ) ) {
				next;
			}

			my $offset = 0;
			my @st     = map {
				$_->{arrival_time}
					= $_->{arrival_time}
					? _T( _S( $_->{arrival_time} ) - $offset )
					: $_->{arrival_time};
				$_->{departure_time}
					= $_->{departure_time}
					? _T( _S( $_->{departure_time} ) - $offset )
					: $_->{departure_time};
				$_;
				}
				grep {
				       ( $_->{arrival_time} && _S( $_->{arrival_time} ) >= $offset )
					|| ( $_->{departure_time} && _S( $_->{departure_time} ) >= $offset )
				} @{ $stop_times->{ $trip->{trip_id} } };
			my @sh = @{ $shapes->{ $trip->{shape_id} } };

			my ( $cur, $prev, $shape_it ) = ( shift @st, undef, 0 );

			my $o = $svg->circle(
				r          => $RADIUS,
				fill       => 'red',
				'z-index'  => 20,
				visibility => 'hidden'
			);

			$o->animate(
				attributeName => 'visibility',
				values        => 'hidden;visible',
				begin => _TX( $ct->( $cur->{arrival_time} || $cur->{departure_time} ) - 1 ),
				dur   => '1s',
				fill  => 'freeze',
			);

			while (@st) {
				$prev = $cur;
				$cur  = shift @st;

				my $v = '';
				while ($shape_it <= $#sh
					&& $sh[$shape_it]->{shape_dist_traveled} <= $cur->{shape_dist_traveled} )
				{
					if ($v) {
						$v .= $v =~ m/L/ ? ' ' : ' L';
					}
					else {
						$v = 'M';
					}
					$v .= $px->( $sh[$shape_it]->{shape_pt_lon} ) . ' '
						. $py->( $sh[$shape_it]->{shape_pt_lat} );

					$shape_it++;
				}
				$shape_it--;

				unless ( $paths{$v} ) {
					$svg->path(
						'z-index'      => 10,
						d              => $v,
						fill           => 'none',
						stroke         => 'grey',
						'stroke-width' => $RADIUS / 3,
					);

					$paths{$v} = 1;
				}

				# animate -> from prev -> cur alatg shape path
				$o->animateMotion(
					fill  => 'freeze',
					path  => $v,
					begin => _TX( $ct->( $prev->{departure_time} || $prev->{arrival_time} ) ),
					dur   => (
						      $ct->( $cur->{departure_time}  || $cur->{arrival_time} )
							- $ct->( $prev->{departure_time} || $prev->{arrival_time} )
						)
						. 's',
				);
			}

			$o->animate(
				attributeName => 'visibility',
				values        => 'visible;hidden',
				begin         => _TX( $ct->( $cur->{departure_time} || $cur->{arrival_time} ) ),
				dur           => '1s',
				fill          => 'freeze',
			);
		}
	}

	for ( 0 .. ( 24 * 60 * 60 * $FPS ) / $SPEED ) {
		my $text = $svg->text(
			x          => 10,
			y          => 20,
			visibility => 'hidden',
			'z-index'  => 30,
			fill       => 'yellow',
		);
		$text->cdata( _T( $_ * $SPEED / $FPS ) );
		$text->animate(
			attributeName => 'visibility',
			values        => 'visible',
			begin         => _TX( $BUFFER + $_ / $FPS ),
			dur           => ( 1 / $FPS ) . 's',
		);
	}

	burp $kml, $svg->xmlify;
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
