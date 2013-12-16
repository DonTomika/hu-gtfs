
=head1 NAME

HuGTFS::FeedManager::Volan::Balaton - HuGTFS feed manager for download + parsing Balaton Volán data

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Volan::Balaton;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Volan::Balaton;

use 5.14.0;
use utf8;
use strict;
use warnings;

use YAML qw//;

use HuGTFS::Util qw(:utils);
use HuGTFS::Crawler;
use HuGTFS::OSMMerger;
use HuGTFS::ShapeFinder;
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
	CAL_START        => HuGTFS::Cal::CAL_START,
	CAL_END          => HuGTFS::Cal::CAL_END,
};

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

=cut

sub download
{
	my $self = shift;

	return HuGTFS::Crawler->crawl(
		[ 'http://balatonvolan.hu/ez/terkeptervezet11.php?varos=91',
		  'http://balatonvolan.hu/ez/terkeptervezet11.php?varos=92' ],
		$self->data_directory, \&crawl_xml, \&cleanup,
		{ sleep => 0, name_file => \&name_files, proxy => 0, },
	);
}

=head3 cleanup

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;
	return $content if $url =~ m/\.pdf$/;

	utf8::encode($content);
	$content =~ s{<\?xml version="1\.0"\?>}{<?xml version="1.0" encoding="UTF-8"?>}o;

	$content =~ s/\bL([a-z]+)=/$1=/go;

	$content =~ s/<marker9[12]\d\d[OV]/\t<marker/go;

	return $content;
}

=head3 crawl_city

=cut

sub crawl_xml
{
	my ( $content, $mech, $url ) = @_;

	my @matches = ($content =~ m/<option value="(9[12]\d\d[OV])">/go);

	my @urls = map { ("http://www.balatonvolan.hu/ez/xml/$_.xml", "http://balatonvolan.hu/ez/pages/helyi" .(m/^91/? "vp": "bf"). "/$_.pdf") } @matches;
	return ( [@urls], undef, undef, \&cleanup, );
}

=head3 name_files

=cut

sub name_files
{
	my ( $url, $file ) = shift;

	if ( $url =~ m{xml/$} ) {
		return "index.html";
	}

	if ( $url =~ m{91(\d\d)([OV])\.(pdf|xml)$} ) {
		return "veszprem-$1-$2.$3";
	}

	if ( $url =~ m{92(\d\d)([OV])\.(pdf|xml)$} ) {
		return "balatonfured-$1-$2.$3";
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
			agency_id       => 'BALATON-VOLAN-VESZPREM',
			agency_phone    => '+36 (88) 590-755',
			agency_lang     => 'hu',
			agency_name     => 'Balaton Volán Zrt. (Veszprém)',
			agency_url      => 'http://www.balatonvolan.hu',
			agency_timezone => 'Europe/Budapest',
			fares => [
				{
					'fare_id'        => 'E_VESZPREM',
					'price'          => '245',
					'currency_type'  => 'HUF',
					'payment_method' => 'prepaid',
					'transfers'      => 0,
					'rules'          => [],
				},
				{
					'fare_id'        => 'G_VESZPREM',
					'price'          => '320',
					'currency_type'  => 'HUF',
					'payment_method' => 'onboard',
					'transfers'      => 0,
					'rules'          => [],
				},
			],
		},
		{
			agency_id       => 'BALATON-VOLAN-BALATONFURED',
			agency_phone    => '+36 (87) 342-255',
			agency_lang     => 'hu',
			agency_name     => 'Balaton Volán Zrt. (Balatonfüred)',
			agency_url      => 'http://www.balatonvolan.hu',
			agency_timezone => 'Europe/Budapest',
			fares => [
				{
					'fare_id'        => 'G_BALATONFURED',
					'price'          => '300',
					'currency_type'  => 'HUF',
					'payment_method' => 'onboard',
					'transfers'      => 0,
					'rules'          => [],
				},
				{
					'fare_id'        => 'N_BALATONFURED',
					'price'          => '700',
					'currency_type'  => 'HUF',
					'payment_method' => 'onboard',
					'transfers'      => 0,
					'rules'          => [],
				},
			],
		},
	);

#<<<
#>>>
	my ( $STOPS, $TRIPS, $ROUTES ) = ( {}, {}, );

	my $twig = XML::Twig->new( discard_spaces => 1, );

	$log->info("Parsing routes...");

	foreach my $file ( glob( catfile( $self->data_directory, '*.xml' ) ) ) {
		$log->debug("Parsing route: $file");

		$twig->parsefile($file);

		foreach my $marker ( $twig->get_xpath("marker") ) {
			my ( $route_id, $seq, $arrival, $departure, $stop, $direction_id, $trip_short_name,
				$service_id )
				= (
				$marker->att("vonal"),
				$marker->att("sorsz"),
				$marker->att("eora") . ":" . $marker->att("eperc"),
				$marker->att("iora") . ":" . $marker->att("iperc"),
				{
					stop_id   => $marker->att("kod"),
					stop_lat  => $marker->att("gpsy"),
					stop_lon  => $marker->att("gpsx"),
					stop_code => $marker->att("kod"),
					stop_name => name_map( $marker->att("nev") ),
				},
				$marker->att("odavi") eq "O" ? "outbound" : "inbound",
				$marker->att("jarat"),
				$marker->att("kkorl"),
				);

			next if $trip_short_name eq 0;

			$STOPS->{ $stop->{stop_code} } = $stop unless $STOPS->{ $stop->{stop_code} };

			my $route = $ROUTES->{$route_id};
			my ($city, $route_short_name) = ($route_id =~ m/^(\d\d)(\d\d)$/);

			unless ($route) {
				$route = $ROUTES->{$route_id} = {
					route_id   => $route_id,
					route_type => 'bus',
					route_short_name => int($route_short_name),
					route_bikes_allowed => 1,
					agency_id => $city eq "92" ? 'BALATON-VOLAN-BALATONFURED' : 'BALATON-VOLAN-VESZPREM',
				};
			}

			my $trip = $TRIPS->{ $route_id . '-' . $trip_short_name };

			unless ( $trip ) {
				my $pdf_link = $self->reference_url . ($city eq '92' ? 'balatonfured' : 'veszprem') . '-' . $route_short_name . '-' . ($direction_id eq 'outbound' ? 'O' : 'V' ) . ".pdf"; 
				$trip = $TRIPS->{ $route_id . '-' . $trip_short_name } = {
					trip_id         => $route_id . '-' . $trip_short_name,
					route_id        => $route_id,
					direction_id    => $direction_id,
					trip_url        => $pdf_link,
					trip_short_name => $trip_short_name,
					service_id      => map_service_id( $service_id ),
					stop_times      => [],
				};

				push @{ $route->{trips} }, $trip;
			}

			$arrival   = $arrival   =~ m/^\d+:\d+$/ ? _0D($arrival)   : undef;
			$departure = $departure =~ m/^\d+:\d+$/ ? _0D($departure) : undef;

			$arrival   = $departure unless $arrival;
			$departure = $arrival   unless $departure;

			push @{ $trip->{stop_times} },
				{
				stop_sequence  => $seq,
				stop_name      => $stop->{stop_name},
				stop_code      => $stop->{stop_code},
				arrival_time   => $arrival,
				departure_time => $departure,
				};
		}
	}

	$log->info("Handling trips...");

	foreach my $trip ( values %$TRIPS ) {
		$trip->{stop_times}
			= [ sort { $a->{stop_sequence} <=> $b->{stop_sequence} } @{ $trip->{stop_times} } ];
		delete $_->{stop_sequence} for @{ $trip->{stop_times} };

		$trip->{trip_headsign} = $trip->{stop_times}[-1]{stop_name};

		my $r = $ROUTES->{ $trip->{route_id} };
		$r->{
			(
				       $trip->{direction_id}
					&& $trip->{direction_id} eq 'outbound' ? 'common_from' : 'common_to'
			)
			}->{ $trip->{stop_times}[-1]{stop_name} }++;
		$r->{
			(
				       $trip->{direction_id}
					&& $trip->{direction_id} eq 'outbound' ? 'common_to' : 'common_from'
			)
			}->{ $trip->{stop_times}[0]{stop_name} }++;
	}

	foreach my $r ( values %$ROUTES ) {
		$r->{route_desc} = (
			sort { $r->{common_from}->{$b} <=> $r->{common_from}->{$a} }
				keys %{ $r->{common_from} }
			)[0]
			. ' / '
			. (
			sort { $r->{common_to}->{$b} <=> $r->{common_to}->{$a} }
				keys %{ $r->{common_to} }
			)[0];

		delete $r->{common_from};
		delete $r->{common_to};

	}

	my $gtfs_data = { routes => [ sort { $a->{route_id} <=> $b->{route_id} } values %$ROUTES ], trips => $TRIPS, stops => {} };

	my $osm_data = HuGTFS::OSMMerger->parse_osm( qr/Balaton Volán/, $self->osm_file );

	my $data = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
		},
		$osm_data,
		$gtfs_data
	);

	$ROUTES = { map { $_->{route_id} => $_ } @{ $data->{routes} } };
	$TRIPS  = $data->{trips};
	$STOPS  = $data->{stops};
	delete $_->{trips} for values %$ROUTES;

	$log->info("Dumping data...");

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_agency($_) for ( sort { $a->{agency_id} cmp $b->{agency_id} } @AGENCIES );

	$dumper->dump_route($_) for ( sort { $a->{route_id} cmp $b->{route_id} } values %$ROUTES );
	$dumper->dump_stop($_)  for ( sort { $a->{stop_id} cmp $b->{stop_id} } values %$STOPS );
	$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump() );
	$dumper->dump_trip($_) for ( sort { $a->{trip_id} cmp $b->{trip_id} } @$TRIPS );

	$dumper->dump_statistics( $data->{statistics} );

	$dumper->deinit_dumper();
}

sub map_service_id
{
	my $service_id = shift;

	state $map = {
		# naponta
		"."  => "NAPONTA",

		# szabad és munkaszüneti napokon
		"A"  => "HETVEGEN",

		# iskolai előadási napokon
		"I"  => "TANITASI_MUNKANAPON",

		# külön rendeletre
		"K"  => "NEVER",

		# munkanapokon 
		"M"  => "MUNKANAPON",

		# munkaszüneti napok kivételével naponta 
		"N"  => HuGTFS::Cal->find("MUNKASZUNETINAPON")->invert->service_id,

		# szabadnapokon (szombat) 
		"O"  => "SZABADNAPON",

		# munkaszüneti napokon
		"V"  => "MUNKASZUNETINAPON",

		# tanszünetben munkanapokon
		"T"  => "TANSZUNETI_MUNKANAPON",

		# külön rendeletre
		"8"  => "NEVER",

		# IV.01.-től IX.29-ig munkanapokon
		"26" => HuGTFS::Cal->find("MUNKANAPON")->restrict("20130401-20130929")->service_id,

		# nyári tanszünetben naponta
		"29" => HuGTFS::Cal->find("NAPONTA")->restrict("20130716-20130902")->service_id,

		# IV.1.től X.31.-ig nyári tanszünet kivételével naponta
		"32" => HuGTFS::Cal->find("NAPONTA")->restrict("20130401-20130715,20130902-20131031")->service_id,

		# IV.01.-től IX.29-ig szabad és munkaszüneti napokon
		"43" => HuGTFS::Cal->find("HETVEGEN")->restrict("20130401-20130929")->service_id,

		# nyári időszámítás alatt munkaszüneti napokon
		"45" => HuGTFS::Cal->find("MUNKASZUNETINAPON")->restrict("20130331-20131027")->service_id,

		# nyári időszámítás alatt munkanapokon
		"52" => HuGTFS::Cal->find("MUNKANAPON")->restrict("20130331-20131027")->service_id,

		# VI.20-tól VIII.31-ig naponta
		"53" => HuGTFS::Cal->find("NAPONTA")->restrict("20130520-20130831")->service_id,

		# IX.30.-től III.31-ig munkanapokon
		"68" => HuGTFS::Cal->find("MUNKANAPON")->restrict("-20130331,20130930-")->service_id,

		# tanszünetben munkanapokon 
		"72" => HuGTFS::Cal->find("MUNKANAPON")->restrict(HuGTFS::Cal::CAL_TANSZUNET)->service_id,

		# IX.30.-től III.31-ig szabad és munkaszüneti napokon
		"78" => HuGTFS::Cal->find("HETVEGEN")->restrict("-20130331,20130930-")->service_id,

		# nyári időszámítás alatt munkaszüneti napok kivételével naponta, téli időszámítás alatt munkanapokon.
		"86" => HuGTFS::Cal::or_service(
			HuGTFS::Cal->find("MUNKASZUNETINAPON")->restrict("20130331-20131027")->invert,
			HuGTFS::Cal->find("MUNKANAPON")->restrict("-20130401,20131028-")
			)->service_id,

		# nyári időszámítás alatt szabad és munkaszüneti napokon
		"88" => HuGTFS::Cal->find("HETVEGEN")->restrict("20130331-20131027")->service_id,
	};

	$log->warn("Missing service period: $service_id") unless $map->{$service_id};

	return $map->{$service_id} || "NEVER";
}

sub name_map
{
	my $name = shift;

	#$name =~ s/^(?:Veszprém, ?|V\.prém, ?|Balatonfüred, ?|B\.füred, ?)//g;
	$name =~ s/V\.prém/Veszprém/;
	$name =~ s/B\.füred/Balatonfüred/;

	$name =~ s/u\.$/utca/;
	$name =~ s/ltp\.$/lakótelep/;
	$name =~ s/isk\.$/iskola/;

#<<<
	state $map = {
		"Balatonfüred, Arany Csillag Sz."       => "Arany Csillag Szálló", #
		"Balatonfüred, aut. áll. (vá.)"         => "Autobusz állomás (vásútállomás)",
		"Balatonfüred, B.arács, v. mh. bej. út" => "Balatonarács, vasúti megállóhely bejárati út",
		"Balatonfüred, Fürdő u.-üzletközpont"   => "Fürdő utca-üzletközpont",
		"Balatonfüred, há. bej. út"             => "Hajóállomás. bejárati út", #
		"Balatonfüred, III. ker. posta"         => "III. kerületi posta", #
		"Balatonfüred, kh."                     => "Községháza",
		"Balatonfüred, MG Szakközépiskola"      => "Mezőgazdasági Szakközépiskola",
		"Balatonfüred, Perczel M. utca"         => "Perczel Mór utca",
		"Balatonfüred, Séta u.-Kiserdő"         => "Séta utca-Kiserdő",
		"Balatonfüred, vá. bej. út"             => "Balatonfüred, vásutállomás bejárati út",
		"Gyulafirátót, ford."                   => "Gyulafirátót, forduló",
		"Veszprém, Ady E. utca"                 => "Ady Endre utca",
		"Veszprém, Ady E. u. 60."               => "Ady Endre utca 60.",
		"Veszprém, Almádi utca"                 => "Almádi út",
		"Veszprém, Aradi Vértanúk utca"         => "Aradi vértanúk útja",
		"Veszprém, Aulich L. utca"              => "Aulich Lajos utca",
		"Veszprém, aut. áll."                   => "Autóbusz-állomás",
		"Veszprém, Avar u. 52."                 => "Avar utca 52.",
		"Veszprém, Avar u ."                    => "Avar utca",
		"Veszprém, Bolgár M. utca"              => "Bolgár Mihály utca",
		"Veszprém, Bv. Intézet"                 => "Büntetésvégrehajtó Intézet",
		"Veszprém, Cholnoky ford."              => "Cholnoky forduló",
		"Veszprém, Cholnoky J. utca"            => "Cholnoky Jenő utca",
		"Veszprém, Diófa u. 2."                 => "Diófa utca 2.",
		"Veszprém, Dózsa Gy. tér"               => "Dózsa György tér",
		"Veszprém, Dugovics T. utca"            => "Dugovics Titusz utca",
		"Veszprém, Egry J. utca"                => "Egry József utca",
		"Veszprém, Egyetem utca"                => "Egyetem utca",
		"Veszprém, Endrődi S. lakótelep"        => "Endrődi Sándor lakótelep",
		"Veszprém, Endrődi S. utca"             => "Endrődi Sándor utca",
		"Veszprém, Gy.rátót, felső"             => "Gyulafirátót, felső", #
		"Veszprém, Haszkovó ford."              => "Haszkovó forduló",
		"Veszprém, Jutasi út 61."               => "Jutasi út 61.",
		"Veszprém, Jutasi úti lakótelep"        => "Jutasi úti lakótelep",
		"Veszprém, Jutaspuszta elág."           => "Jutaspuszta elágazás",
		"Veszprém, Jutaspuszta elág"            => "Jutaspuszta elágazás",
		"Veszprém, Kabai J. utca"               => "Kabay János utca",
		"Veszprém, Kádártai u. ford."           => "Kádártai utca forduló",
		"Veszprém, Kádárta, bej. út"            => "Kádárta, bejárati út",
		"Veszprém, Kádárta, felső"              => "Kádárta, felső",
		"Veszprém, Kádárta, sz. b."             => "Kádárta, szövetkezeti bolt",
		"Veszprém, Kádárta, tsz."               => "Kádárta, takarékszövetkezet",
		"Veszprém, Kádárta, v. mh. 20"          => "Kádárta, vasúti megállóhely 20.", #
		"Veszprém, Láhner Gy. utca"             => "Láhner György utca",
		"Veszprém, Lóczy L. utca"               => "Lóczy Lajos utca",
		"Veszprém, Munkácsy M. utca"            => "Munkácsy Mihály utca",
		"Veszprém, Paál L. utca"                => "Paál László utca",
		"Veszprém, Pajta u. 22."                => "Pajta utca 22.",
		"Veszprém, Pajta u. 9."                 => "Pajta utca 9.",
		"Veszprém, Pápai u. ford."              => "Pápai úti forduló",
		"Veszprém, Pázmándi u. 24."             => "Pázmándi utca 24.",
		"Veszprém, Petőfi S. utca"              => "Petőfi Sándor utca",
		"Veszprém, Radnóti M. tér"              => "Radnóti Miklós tér",
		"Veszprém, Ranolder J. tér"             => "Ranolder János tér",
		"Veszprém, Stadion u. 19."              => "Stadion utca 19.",
		"Veszprém, Stadion u. 28."              => "Stadion utca 28.",
		"Veszprém, Szabadság ltp. b. utca"      => "Szabadság lakótelep bejárati út", #
		"Veszprém, Sziklai J. utca"             => "Sziklay János utca",
		"Veszprém, Szikra u. 22."               => "Szikra utca 22.",
		"Veszprém, színház"                     => "Színház",
		"Veszprém, SZTK-rendelő"                => "SZTK rendelő",
		"Veszprém,Tüzér u. ford."               => "Tüzér utca forduló",
		"Veszprém,Tüzér utca"                   => "Tüzér utca",
		"Veszprém, Tüzér u. ford."              => "Tüzér utca forduló",
		"Veszprém, Tüzér utca"                  => "Tüzér utca",
		"Tüzér u. ford."                        => "Tüzér utca forduló",
		"Tüzér utca"                            => "Tüzér utca",
		"Veszprém, Vámosi u. 24."               => "Vámosi utca 24.",
		"Veszprém, Vámosi u. ford."             => "Vámosi utca forduló",
		"Veszprém, vá."                         => "Vasútállomás",
		"Veszprém, Virág B. utca"               => "Virág Benedek utca",
		"Veszprém, Vértanú utca"                => "Vértanúk utca",
	};
#>>>
	$name = $map->{$name} || $name;

	$name =~ s/^(?:Balatonfüred|Veszprém),\s*//o;

	return ucfirst($name);
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2012 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
