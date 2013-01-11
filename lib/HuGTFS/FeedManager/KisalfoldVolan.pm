
=head1 NAME

HuGTFS::FeedManager::KisalfoldVolan - HuGTFS feed manager for download + parsing Kisalföld Volán data

=head1 SYNOPSIS

	use HuGTFS::FeedManager::KisalfoldVolan;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::KisalfoldVolan;

use 5.14.0;
use utf8;
use strict;
use warnings;

use YAML qw//;

use HuGTFS::Util qw(:utils);
use HuGTFS::Crawler;
use HuGTFS::OSMMerger;
use HuGTFS::Dumper;

use HuGTFS::Cal;

use File::Temp qw/tempfile/;
use File::Spec::Functions qw/catfile tmpdir/;

use XML::Twig;
use DateTime;

use Mouse;

with 'HuGTFS::FeedManager';
__PACKAGE__->meta->make_immutable;

no Mouse;

use constant {
	CAL_START        => '20101212',
	CAL_END          => '20111211',
	CAL_SUMMER_START => '20110616',
	CAL_SUMMER_END   => '20110831',
};

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

=cut

sub download
{
	my $self = shift;

	return HuGTFS::Crawler->crawl(
		[
			'http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/lines.cgi?city=gyor',
			'http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/lines.cgi?city=sopron',
		],
		$self->data_directory,
		\&crawl_city,
		\&cleanup,
		{ sleep => 0, name_file => \&name_files, proxy => 0, },
	);
}

=head3 cleanup

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;

	$content =~ s/ISO-8859-2/UTF-8/;

	return $content;
}

=head3 crawl_city

=cut

sub crawl_city
{
	my ( $content, $mech, $url ) = @_;

	my @urls = ();

	while ( $content =~ m/value="lines\.cgi\?city=([a-z]+)&term=(\d+)"/g ) {
		my ( $city, $date ) = ( $1, $2 );

		push @urls, (
			map {
				m/id=(.*)&dir=to&city=(.*)/;
				"http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/$2/$date/$1.XML"
				}
				map { $_->url_abs } $mech->find_all_links(
				url_abs_regex =>
					qr{^http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/line.cgi\?id=.*&dir=to&city=.*}
				)
		);

		push @urls, "http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/$city/$date/STOPS.XML";
	}

	return ( [@urls], undef, undef, \&cleanup, );
}

=head3 name_files

=cut

sub name_files
{
	my ( $url, $file ) = shift;

	if ( $url =~ m{lines.cgi\?city=(.+?)$} ) {
		return "routes_$1.html";
	}

	if ( $url =~ m{ctp-nd/(.*)/(.*)/STOPS.XML$} ) {
		return "$1_$2_stops.xml";
	}

	if ( $url =~ m{ctp-nd/(.*)/(.*)/(.*).XML$} ) {
		return "$1_$2_route_$3.xml";
	}

	return undef;
}

=head2 parse

=cut

sub parse
{
	my $self = shift;

	my @AGENCIES = (
		{
			agency_id       => 'KISALFOLD-SOPRON',
			agency_phone    => '+36 (99) 311-130',
			agency_lang     => 'hu',
			agency_name     => 'Kisalföld Volán Zrt. (Sopron)',
			agency_url      => 'http://www.kvrt.hu',
			agency_timezone => 'Europe/Budapest',
			routes          => [],
		},
		{
			agency_id       => 'KISALFOLD-GYOR',
			agency_phone    => '+36 (96) 318-755',
			agency_lang     => 'hu',
			agency_name     => 'Kisalföld Volán Zrt. (Győr)',
			agency_url      => 'http://www.kvrt.hu',
			agency_timezone => 'Europe/Budapest',
			routes          => [],
		},
	);

	my ( $STOPS, $ROUTES, $DATE_LIMITS ) = ( {}, [], {} );

	my $twig = XML::Twig->new( discard_spaces => 1, );

	$log->info("Creating calendar...");
	create_calendar();

	$log->info("Parsing stops...");

	foreach my $file ( glob( catfile( $self->data_directory, '*_*_stops.xml' ) ) ) {
		my ( $city, $date ) = ( $file =~ m/([a-z]+)_(\d+)_stops\.xml$/ );
		$log->debug("Parsing stops: $file");

		$twig->parsefile($file);

		foreach my $stop_xml ( $twig->get_xpath("stop") ) {
			my $stop = {
				stop_id   => $city . "-" . $date . "-" . $stop_xml->att("id"),
				stop_name => $stop_xml->att("name"),
				stop_code => $stop_xml->att("id"),
			};

			$STOPS->{ $stop->{stop_id} } = $stop;
		}

		$DATE_LIMITS->{$city}->{$date} = CAL_END;
	}

	foreach my $city ( keys %$DATE_LIMITS ) {

		my $prev;
		for ( sort keys %{ $DATE_LIMITS->{$city} } ) {

			if ($prev) {
				my $date = DateTime->new( _D $_);
				$date->add( days => -1 );
				$DATE_LIMITS->{$city}->{$prev} = $date->ymd('');
			}

			$prev = $_;
		}
	}

	$log->info("Parsing routes...");

	#my $rel_id = 1000;

	foreach my $file ( glob( catfile( $self->data_directory, '*_*_route_*.xml' ) ) ) {
		my ( $city, $date, $route_id ) = ( $file =~ m/([a-z]+)_(\d+)_route_(.*?)\.xml$/ );
		my $route = {
			route_id   => "$date-$route_id",
			agency_id  => 'KISALFOLD-' . uc($city),
			route_type => 'bus',
		};

		next
			unless $date >= DateTime->now()->ymd('')
				|| $DATE_LIMITS->{$city}->{$date} == CAL_END;

		$log->debug("Parsing route: $file");

		$twig->parsefile($file);

		my ($line_xml) = $twig->get_xpath("/line");
		$route->{route_short_name} = $line_xml->att("id");
		$route->{route_long_name}  = $line_xml->att("name");

		#my @rels = ();

		foreach my $direction ( 'to', 'back' ) {

			my ($direction_xml) = $twig->get_xpath("/line/$direction");
			next unless $direction_xml;

			my ( $normal_stop_times, $peak_stop_times ) = ( [], [] );

			#print STDERR "\t<relation id='-$rel_id' action='modify' timestamp='2011-05-31T15:49:04Z' visible='true'>\n";
			#push @rels, $rel_id;
			#$rel_id++;

			foreach my $stop_xml ( $direction_xml->get_xpath("stops/stop") ) {
				my $st = {
					stop_code           => $stop_xml->att("id"),
					arrival_time        => hms( 0, $stop_xml->att("time"), 0 ),
					departure_time      => hms( 0, $stop_xml->att("time"), 0 ),
					shape_dist_traveled => $stop_xml->att("time"),
					drop_off_type       => 0,
					pickup_type         => 0,
					special             => (
						$stop_xml->att("special") && $stop_xml->att("special") eq "true" ? 1 : 0
					),
				};

				if ( $stop_xml->att("boardonly") eq "true" ) {
					@{$st}{ 'pickup_type', 'drop_off_type' } = ( 0, 1 );
				}
				if ( $stop_xml->att("leaveonly") eq "true" ) {
					@{$st}{ 'pickup_type', 'drop_off_type' } = ( 1, 0 );
				}

				$st->{stop_name}
					= $STOPS->{ $city . "-" . $date . "-" . $stop_xml->att("id") }->{stop_name};

				if ( scalar @$normal_stop_times
					&& $st->{arrival_time} eq $normal_stop_times->[-1]->{arrival_time} )
				{
					$st->{arrival_time} = $st->{departure_time}
						= hms( 0, $stop_xml->att("time"), 30 );
					$st->{shape_dist_traveled} += 0.5;
				}

				push @$normal_stop_times, $st;

				if ( defined $stop_xml->att("peak") ) {
					my $peak = {
						%$st,
						arrival_time   => hms( 0, $stop_xml->att("peak"), 0 ),
						departure_time => hms( 0, $stop_xml->att("peak"), 0 ),
					};

					if ( scalar @$peak_stop_times
						&& $peak->{arrival_time} eq $peak_stop_times->[-1]->{arrival_time} )
					{
						$peak->{arrival_time} = $peak->{departure_time}
							= hms( 0, $stop_xml->att("peak"), 30 );
						$peak->{shape_dist_traveled} += 0.5;
					}

					push @$peak_stop_times, $peak;
				}

				#print STDERR "\t\t<member type='node' ref='$ST->{$st->{stop_code}}' role='stop' />\n";
			}

			#print STDERR "\t\t<tag k='type' v='line_variant' />\n";
			#print STDERR "\t\t<tag k='line_variant' v='bus' />\n";
			#print STDERR "\t\t<tag k='ref'  v='$route_id' />\n";
			#print STDERR "\t\t<tag k='from' v='$normal_stop_times->[0]->{stop_name}' />\n";
			#print STDERR "\t\t<tag k='to'   v='$normal_stop_times->[-1]->{stop_name}' />\n";
			#print STDERR "\t</relation>\n";

			foreach my $service_xml ( $direction_xml->get_xpath("daytypes/daytype") ) {
				our $service_id = HuGTFS::Cal->find( $service_xml->att("id") )
					->limit( $date, $DATE_LIMITS->{$city}->{$date} )->service_id;

				my @peaks = ();
				foreach my $peak_xml ( $service_xml->get_xpath("peaks/peak") ) {
					push @peaks,
						[ map { $peak_xml->att($_) } qw/fromhour frommin untilhour untilmin/ ];
				}

				foreach my $departure_xml ( $service_xml->get_xpath("departures/departure") ) {
					state $trip_num = 0;
					$trip_num++;

					my $stop_times = $normal_stop_times;
					my ( $from, $to )
						= ( $departure_xml->att("start"), $departure_xml->att("end") );

					if ( scalar @peaks ) {
						foreach my $peak (@peaks) {
							next
								unless $peak->[0] <= $departure_xml->att("hour")
									&& (   $peak->[0] != $departure_xml->att("hour")
										|| $peak->[1] <= $departure_xml->att("min") )
									&& $peak->[2] >= $departure_xml->att("hour")
									&& (   $peak->[2] != $departure_xml->att("hour")
										|| $peak->[3] >= $departure_xml->att("min") );

							$stop_times = $peak_stop_times;
							last;
						}
					}

					local $service_id = $service_id;
					$service_id
						= HuGTFS::Cal::and_service( $service_id,
						$departure_xml->att('daytype') )->service_id
						if $departure_xml->att('daytype');

					my $trip = {
						trip_id               => "$route_id-$trip_num",
						wheelchair_accessible => (
							       $departure_xml->att("bustype")
								&& $departure_xml->att("bustype") eq 'lowfloor' ? 1 : 0
						),
						direction_id => ( $direction eq 'to' ? 'outbound' : 'inbound' ),
						service_id => $service_id,
						trip_url =>
							"http://www.kisalfoldvolan.hu/uj_menetrend/ctp-nd/line.cgi?id=${route_id}&dir=${direction}&city=${city}&term=${date}",
						stop_times => [
							grep { $_->{stop_code} =~ /^$from/ .. $_->{stop_code} =~ /^$to/ }
								@$stop_times
						],
					};

					$trip->{trip_headsign} = $trip->{stop_times}[-1]{stop_name};

					$trip->{stop_times} = [
						map {
							$_ = {%$_};
							$_->{departure_time} = $_->{arrival_time}
								= _T( _S( $_->{arrival_time} ) 
									+ $departure_xml->att("hour") * 60 * 60
									+ $departure_xml->att("min") * 60 );
							$_;
							} @{ $trip->{stop_times} }
					];

					delete $trip->{stop_times}->[0]->{special}
						if $trip->{stop_times}->[0]->{special};

					$trip->{stop_times} = [
						map { delete $_->{special}; $_ }
						grep { not $_->{special} } @{ $trip->{stop_times} }
					];

					push @{ $route->{trips} }, $trip;
				}
			}
		}

		#print STDERR "\t<relation id='-$rel_id' action='modify' timestamp='2011-05-31T15:49:04Z' visible='true'>\n";
		#for (@rels) {
		#	print STDERR "\t\t<member type='relation' ref='-$_' role='' />\n";
		#}
		#print STDERR "\t\t<tag k='type' v='line' />\n";
		#print STDERR "\t\t<tag k='line' v='bus' />\n";
		#print STDERR "\t\t<tag k='ref' v='$route_id' />\n";
		#print STDERR "\t\t<tag k='operator' v='Kisalföld Volán' />\n";
		#print STDERR "\t\t<tag k='network'  v='local' />\n";
		#print STDERR "\t</relation>\n";
		#$rel_id++;

		push @$ROUTES, $route;
	}

	my $osm_data = HuGTFS::OSMMerger->parse_osm( "Kisalföld Volán", $self->osm_file );
	my $data = HuGTFS::OSMMerger->new( { remove_geometryless => 1, }, $osm_data, { routes => $ROUTES, } );

	{    # Create blocks
		    # This is done after osm-merging so that the stop_id may be used as a safety-net
		    # agains creating bad blocks

		$log->info("Creating blocks...");

		my $block_num;

		for my $route (
			grep {
				$_->{route_id}
					=~ m/^(?:gyor-\d+-(?:2|22|22A|22E|30|31)|sopron-\d+-(?:1|2|7|7A|7B|10Y|12V))$/
			} @$ROUTES
			)
		{
			my ( $city, $date, $route_id )
				= ( $route->{route_id} =~ m/^([a-z]*)-(\d*)-([0-9A-Z]*)$/ );

			my @trips = @{ $route->{trips} };

			# sopron-2 may become 2/15/15A and vice versa
			if ( $city eq 'sopron' && $route_id =~ m/^(?:2|15|15A)$/ ) {

				@trips = map { @{ $_->{trips} } }
					grep { $_->{route_id} =~ m/^sopron-$date-(?:2|15|15A)$/ } @$ROUTES;
			}

			foreach my $trip ( grep { $_->{direction_id} eq 'outbound' } @trips ) {
				foreach my $block_trip ( grep { $_->{direction_id} eq 'inbound' }
					@{ $route->{trips} } )
				{
					next unless $trip->{service_id} eq $block_trip->{service_id};

					next
						unless $trip->{stop_times}->[-1]->{stop_id} eq
							$block_trip->{stop_times}->[0]->{stop_id};

					my $dep_diff = _S( $block_trip->{stop_times}->[0]->{departure_time} )
						- _S( $trip->{stop_times}->[-1]->{arrival_time} );
					next unless $dep_diff >= 0 && $dep_diff < 3 * 60;    # 3 minutes

					$block_num++;
					$trip->{block_id} = $block_trip->{block_id}
						= "$city-$route->{route_short_name}-$block_num";

					last;
				}
			}
		}
	}

	$log->info("Dumping data...");
	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_agency($_) for ( sort { $a->{agency_id} cmp $b->{agency_id} } @AGENCIES );

	$dumper->dump_route($_)
		for ( sort { $a->{route_id} cmp $b->{route_id} } @{ $data->{routes} } );
	$dumper->dump_stop($_) for ( map { $data->{stops}->{$_} } sort keys %{ $data->{stops} } );
	$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump() );

	$dumper->dump_statistics( $data->statistics );

	$dumper->deinit_dumper();
}

sub create_calendar
{
	my $data = [
	#<<<
		[
			qw/service_id monday tuesday wednesday thursday friday saturday sunday start_date end_date service_desc/
		],

		[ ["Iskolás munkanapokon (hétfőtől péntekig)"], "TNMUNKANAP",
			1, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END, ],

		[ ["Tanszünetes munkanapokon"], "TSMUNKANAP",
			1, 1, 1, 1, 1, 0, 0, CAL_SUMMER_START, CAL_SUMMER_END, ],

		[ ["Szabadnapokon (szombaton)"], "SZABADNAP",
			0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END, ],

		[ ["Vasárnap, ünnepnap"], "MSZNAP",
			0, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END, ],

		[ ["hétfői munkanapokon közlekedik"], "H",
			1, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END, ],

		[ ["hétfőtől csütörtökig, munkanapokon közlekedik"], "HC",
			1, 1, 1, 1, 0, 0, 0, CAL_START, CAL_END, ],

		[ ["tanév tartama alatt (szeptember 1-től június 15-ig) közlekedik"], "J",
			1, 1, 1, 1, 1, 1, 1, CAL_START, CAL_END, ],

		[ ["hétfő kivételével munkanapokon közlekedik"], "KP",
			0, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END, ],

		[ ["május 1-től október 2-ig közlekedik"], "NT",
			1, 1, 1, 1, 1, 1, 1, 20110501, 20111002, ],

		[ ["pénteki munkanapokon közlekedik"], "P",
			0, 0, 0, 0, 1, 0, 0, CAL_START, CAL_END, ],

		[ ["a VOLT Fesztivál alatt közlekedik"], "VO",
			1, 1, 1, 1, 1, 1, 1, 20110629, 20110703, ],

		[ ["nyári tanszünetben (június 16-tól augusztus 31-ig) közlekedik"], "W",
			1, 1, 1, 1, 1, 1, 1, CAL_SUMMER_START, CAL_SUMMER_END, ],

	#>>>
	];

	HuGTFS::Cal->empty;

	foreach my $i ( 1 .. $#$data ) {
		$data->[$i]->[ $#{ $data->[0] } + 1 ] = $data->[$i]->[0]->[0];    # service_desc
		shift @{ $data->[$i] };

		HuGTFS::Cal->new( map { $data->[0]->[$_] => $data->[$i]->[$_] } 0 .. $#{ $data->[0] } );
	}

	my $exceptions = [ [qw/service_id date exception_type/], ];

	push(
		@$exceptions,

		# TNMUNKANAP
		[qw/TNMUNKANAP 20110314 removed /],
		[qw/TNMUNKANAP 20110315 removed /],
		[qw/TNMUNKANAP 20110319 added   /],
		[qw/TNMUNKANAP 20110321 removed /],
		[qw/TNMUNKANAP 20110322 removed /],
		[qw/TNMUNKANAP 20110325 removed /],
		[qw/TNMUNKANAP 20110326 removed /],
		[qw/TNMUNKANAP 20110613 removed /],
		[qw/TNMUNKANAP 20111031 removed /],
		[qw/TNMUNKANAP 20111101 removed /],
		[qw/TNMUNKANAP 20111102 removed /],
		[qw/TNMUNKANAP 20111103 removed /],
		[qw/TNMUNKANAP 20111104 removed /],

		# TSMUNKANAP
		[qw/TSMUNKANAP 20110421 added   /],
		[qw/TSMUNKANAP 20110422 added   /],
		[qw/TSMUNKANAP 20110426 added   /],
		[qw/TSMUNKANAP 20111102 added   /],
		[qw/TSMUNKANAP 20111103 added   /],
		[qw/TSMUNKANAP 20111104 added   /],
		[qw/TSMUNKANAP 20111105 added   /],

		# SZABADNAP
		[qw/SZABADNAP 20110101 removed /],
		[qw/SZABADNAP 20110314 added   /],
		[qw/SZABADNAP 20110319 removed /],
		[qw/SZABADNAP 20110820 removed /],
		[qw/SZABADNAP 20111031 added   /],
		[qw/SZABADNAP 20111105 removed /],

		# MSZNAP
		[qw/MSZNAP 20110101 added/],
		[qw/MSZNAP 20110315 added/],
		[qw/MSZNAP 20110425 added/],
		[qw/MSZNAP 20110613 added/],
		[qw/MSZNAP 20110820 added/],
		[qw/MSZNAP 20111101 added/],
	);

	foreach my $i ( 1 .. $#$exceptions ) {
		HuGTFS::Cal->find( $exceptions->[$i]->[0] )
			->add_exception( @{ $exceptions->[$i] }[ 1, 2 ] );
	}

	{    # summer school recess
		my $date      = DateTime->new( _D CAL_SUMMER_START );
		my $service   = HuGTFS::Cal->find("TNMUNKANAP");
		my $service_j = HuGTFS::Cal->find("J");
		while ( $date->ymd('') <= CAL_SUMMER_END ) {
			$service->add_exception( $date, 'removed' )
				if $service->enabled($date);
			$service_j->add_exception( $date, 'removed' )
				if $service_j->enabled($date);
			$date->add( days => 1 );
		}
	}
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

