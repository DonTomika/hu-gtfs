
=head1 NAME

HuGTFS::FeedManager::Kisvasut::KBK - HuGTFS feed manager for download + parsing KBK (kisvasut.hu) data

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Kisvasut::Gyermekvasut;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Kisvasut::KBK;

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

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

=cut

sub download
{
	my $self = shift;

	return HuGTFS::Crawler->crawl(
		[
			      'http://kisvasut.hu/kvadmin/mrend_export.php?idoszak='
				. _DH(HuGTFS::Cal::CAL_START) . '|'
				. _DH(HuGTFS::Cal::CAL_END)
		],
		$self->data_directory,
		undef, \&cleanup,
		{ name_file => \&name_files },
	);
}

=head3 cleanup

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;
	$content =~ tr/őűõûÕ/ouőűŐ/;
	return $content;
}


=head3 name_files

=cut

sub name_files
{
	return "timetable.xml";
}

=head2 parse

=cut

sub parse
{
	my $self = shift;

	my @AGENCIES = (
		{
			agency_id       => 'MECSEKERDO-ALMA',
			agency_name     => 'Mecsekerdő Zrt. (Almamelléki ÁEV)',
			agency_phone    => '+36 (73) 514 102',
			agency_url      => 'http://www.mecsekerdő.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'NAGYCENK',
			agency_name     => 'Nagycenki Széchenyi Múzeumvasút (GySEV)',
			agency_phone    => '+36 (99) 517-244',
			agency_url      => 'http://www.gysev.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'BFENYVES',
			agency_name     => 'MÁV-Start Zrt. (Balatonfenyves GV)',
			agency_phone    => '+36 (40) 494-949',
			agency_url      => 'http://www.mav-start.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'ZALAERDO',
			agency_name     => 'Zalaerdő Zrt. (Csömödéri ÁEV)',
			agency_phone    => '+36 (92) 579-033',
			agency_url      => 'http://www.zalaerdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'KASZO',
			agency_name     => 'Kaszó Zrt. (Kaszói ÁEV)',
			agency_phone    => '+36 (82) 445-818',
			agency_url      => 'http://kaszort.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'GEMENC',
			agency_name     => 'Gemenc Zrt. (Gemenci ÁEV)',
			agency_phone    => '+36 (74) 491-483',
			agency_url      => 'http://gemenczrt.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'SEFAG',
			agency_name     => 'SEFAG Zrt. (Mesztegnyői ÁEV)',
			agency_phone    => '+36 (85) 329-312',
			agency_url      => 'http://sefag.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'KIRALYRET',
			agency_name     => 'Börzsöny 2020 Kft. (Királyréti EV)',
			agency_phone    => '+36 (20) 951-4912',
			agency_url      => 'http://kisvasut-kiralyret.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id   => 'NAGYBORZSONY',
			agency_name => 'Nagybörzsöny Erdei Kisvasút Nonprofit Kft. (Nagybörzsönyi EV)',
			agency_phone    => '+36 (70) 549-4797 ',
			agency_url      => 'http://www.kisvasut-kiralyret.fw.hu/nindex/nindex.htm',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'SZOB',
			agency_name     => 'Börzsöny Kisvasút Nonprofit Kft. (Szobi EV)',
			agency_phone    => '+36 (20) 203-7660',
			agency_url      => 'http://borzsonykisvasut.uw.hu/',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id   => 'KEMENCE',
			agency_name => 'Kisvasutak Baráti Köre Egyesület (Kemencei Erdei Múzeumvasút)',
			agency_phone    => '+36 (20) 586-5242',
			agency_url      => 'http://www.kisvasut.hu/index.php?rfa=3',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'EGERERDO-FT',
			agency_name     => 'Egererdő Zrt. (Felsőtárkányi ÁEV)',
			agency_phone    => '+36 (36) 434-210',
			agency_url      => 'http://www.egererdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'EGERERDO-SZ',
			agency_name     => 'Egererdő Zrt. (Szilvásváradi ÁEV)',
			agency_phone    => '+36 (36) 355-112',
			agency_url      => 'http://www.egererdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'EGERERDO-MV',
			agency_name     => 'Egererdő Zrt. (Mátravasút)',
			agency_phone    => '+36 (37) 320-025',
			agency_url      => 'http://www.egererdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'ESZAKERDO-LF',
			agency_name     => 'Északerdő Zrt. (Lillafüredi ÁEV)',
			agency_phone    => '+36 (46) 530-593',
			agency_url      => 'http://www.eszakerdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'ESZAKERDO-PH',
			agency_name     => 'Északerdő Zrt. (Pálházi ÁEV)',
			agency_phone    => '+36 (47) 370-002',
			agency_url      => 'http://www.eszakerdo.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},

		{
			agency_id       => 'ZSUZSIVASUT',
			agency_name     => 'Zsuzsi Erdei Vasút Nonprofit Kft.',
			agency_phone    => '+36 (52) 417-212',
			agency_url      => 'http://zsuzsivasut.hu/',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
		{
			agency_id       => 'HORTOBAGY',
			agency_name     => 'Hortobágyi Nemzeti Park Igazgatóság',
			agency_phone    => '+36 (52) 589-000',
			agency_url      => 'http://www.hnp.hu',
			agency_timezone => 'Europe/Budapest',
			agency_lang     => 'hu',
		},
	);

	my $route_agency = {
		"Hortobágy - Kondástó" => "HORTOBAGY",    # Hortobágy - Kondástó

		"8a"   => "NAGYCENK",           # Fertőboz - Kastély
		"39b"  => "BFENYVES",           # Balatonfenyves - Somogyszentpál
		"305"  => "ZALAERDO",           # Lenti - Csömödér - Kistolmács
		"307"  => "KASZO",              # Szenta - Kaszó
		"308"  => "MECSEKERDO-ALMA",    # Almamellék - Sasrét
		"310"  => "GEMENC",             # Pörböly - Gemenc Dunapart
		"310b" => "GEMENC",             # Gemenc Dunapart - Bárányfok
		"311"  => "SEFAG",              # Mesztegnyő - Felsőkak
		"317"  => "KIRALYRET",          # Kismaros - Királyrét
		"318"  => "NAGYBORZSONY",       # Nagyirtás - Nagybörzsöny
		"318a" => "SZOB",               # Szob - Márianosztra
		"319"  => "KEMENCE",            # Kemence - Feketevölgy - Hajagos
		"321"  => "EGERERDO-FT",        # Felsőtárkány - Stimeczház
		"323"  => "EGERERDO-SZ",        # Szilvásvárad - Szalajka-Fátyolvízesés
		"324"  => "EGERERDO-MV",        # Gyöngyös - Lajosháza - Szalajkaház
		"325"  => "EGERERDO-MV",        # Gyöngyös - Mátrafüred
		"330"  => "ESZAKERDO-LF",       # Miskolc - Lillafüred - Garadna
		"331"  => "ESZAKERDO-LF",       # Miskolc - Mahóca
		"332"  => "ESZAKERDO-PH",       # Pálháza - Rostalló
		"333"  => "ZSUZSIVASUT",        # Debrecen-Fatelep - Hármashegyalja
	};

	my $AGENCIES = ();
	my $ROUTES   = ();
	my $STOPS    = ();

	my $vonatnemek = { 'gm' => 'gőzvontatású nosztalgiavonat', };
	my $vonalak    = ();
	my $allomasok  = ();

	HuGTFS::Cal->empty();

	my $twig = XML::Twig->new(
		discard_spaces => 1,
		twig_roots     => { vonatnem => 1, vonal => 1, vonat => 1 },
	);

	$twig->parsefile( catfile( $self->data_directory, "timetable.xml" ) );

	my $osm_data = HuGTFS::OSMMerger->parse_osm(
		qr/\b(?:MÁV-Start Zrt\.|Kisvasutak Baráti Köre Egyesület|Hortobágyi Nemzeti Park Igazgatóság|Kaszó Zrt\.|Egererdő Zrt\.|Mecsekerdő Zrt\.|Gemenc Zrt\.|Nagybörzsöny Erdei Kisvasút Nonprofit Kft\.|GySEV|SEFAG Zrt\.|Börzsöny 2020 Kft\.|Börzsöny Kisvasút Nonprofit Kft\.)(?:\b|\z|;)/,
		$self->osm_file
	);

	$log->debug("Loading routes...");

	foreach my $v ( $twig->get_xpath("vonal") ) {
		my $vh = {
			id       => $v->att("id"),
			mezo     => $v->att("mezo"),
			nev      => $v->att("nev"),
			max_tav  => 0,
			tavolsag => {},
		};

		foreach my $a ( $v->get_xpath("allomas") ) {
			unless ( $allomasok->{ $a->att("id") } ) {
				$allomasok->{ $a->att("id") } = {
					nev => $a->att("nev"),
					id  => $a->att("id"),
				};
			}

			$vh->{tavolsag}->{ $a->att("id") } = $a->att("km");

			$vh->{max_tav} = $a->att("km") if $a->att("km") > $vh->{max_tav};
		}

		$vonalak->{ $v->att("id") } = $vh;
	}

	$log->debug("Loading route types...");
	foreach ( $twig->get_xpath("vonatnem") ) {
		$vonatnemek->{ $_->att("rovid") } = $_->att("nev");
	}

	$log->info("Loading trips...");
	foreach my $v ( $twig->get_xpath("vonat") ) {
		my ($year) = ( $v->att("nev") =~ m{^(\d+)} );

		$log->debug( "Loading trip: " . $v->att("nev") );

		my $tsn = $v->att("szam");

		my $mask = $v->get_xpath( 'idoszakok/maszk', 0 );
		next unless $mask && $mask->att("kezd") ne '0000-00-00';

		my $service = HuGTFS::Cal->new(
			service_id => $v->att("id"),
			start_date => DateTime->today,
			end_date   => DateTime->today,
		);

		my $trip = {
			trip_id  => $v->att("id"),
			route_id => $v->att("vonal_idref") . "_" . ( $v->att("fejjel") || $v->att("nem") ),
			direction_id    => ( ( $tsn =~ m/(\d+)/ )[0] % 2 ) ? 'inbound' : 'outbound',
			service_id      => $service->service_id,
			block_id        => $v->att("nev"),
			trip_short_name => $tsn,
			trip_headsign   => undef,

			stop_times => [],
		};
		$trip->{block_id} =~ s{ / }{_};

		my $start_date = $mask->att("kezd");
		$start_date =~ s/-//g;
		$start_date = DateTime->new( _D($start_date) );
		for ( split '', $mask->text ) {
			$service->add_exception( $start_date, 1 ) if $_;

			$start_date->add( days => 1 );
		}

		my $reverse_sdt = 0;    # reverse shape_dist_traveled?
		foreach my $i ( $v->get_xpath("idoadatok/idoadat") ) {
			state $t = {
				e => [ 0, 0 ],    # érkező végállomás
				i => [ 0, 0 ],    # induló végállomás
				n => [ 0, 0 ],    # normális
				x => [ 3, 3 ],    # feltételes
				h => [ 1, 1 ],    # áthalad
			};

			push @{ $trip->{stop_times} },
				{
				stop_name    => $allomasok->{ $i->att("all_idref") }->{nev},
				arrival_time => hms(
					( $i->att("erk") || $i->att("ind") ) =~ m/^((?:.?.(?=..)|))(.?.)$/, 0
				),
				departure_time => hms(
					( $i->att("ind") || $i->att("erk") ) =~ m/^((?:.?.(?=..)|))(.?.)$/, 0
				),
				shape_dist_traveled =>
					$vonalak->{ $v->att("vonal_idref") }->{tavolsag}->{ $i->att("all_idref") },
				pickup_type   => 0,
				drop_off_type => 0,
				};

			if ( $#{ $trip->{stop_times} }
				&& seconds( $trip->{stop_times}[-2]{departure_time} )
				> seconds( $trip->{stop_times}[-1]{arrival_time} ) )
			{
				$trip->{stop_times}[-1]{arrival_time}
					= _T( _S( $trip->{stop_times}[-1]{arrival_time} ) + 24 * 60 * 60 );
			}

			if ( seconds( $trip->{stop_times}[-1]{arrival_time} )
				> seconds( $trip->{stop_times}[-1]{departure_time} ) )
			{
				$trip->{stop_times}[-1]{departure_time}
					= _T( _S( $trip->{stop_times}[-1]{departure_time} ) + 24 * 60 * 60 );
			}

			if (   $#{ $trip->{stop_times} }
				&& $trip->{stop_times}[-1]{shape_dist_traveled}
				< $trip->{stop_times}[-2]{shape_dist_traveled} )
			{
				$reverse_sdt = $trip->{stop_times}[-2]{shape_dist_traveled}
					if $trip->{stop_times}[-2]{shape_dist_traveled} > $reverse_sdt;
			}

			@{ $trip->{stop_times}[-1] }{ 'pickup_type', 'drop_off_type' }
				= @{ $t->{ $i->att("megallas") } };
		}

		if ($reverse_sdt) {
			$_->{shape_dist_traveled} = $reverse_sdt - $_->{shape_dist_traveled}
				for ( @{ $trip->{stop_times} } );
		}

		$trip->{trip_headsign} = $trip->{stop_times}[-1]{stop_name};

		unless ( $ROUTES->{ $trip->{route_id} } ) {
			my $route = {
				agency_id => $route_agency->{
					       $vonalak->{ $v->att("vonal_idref") }->{mezo}
						|| $vonalak->{ $v->att("vonal_idref") }->{nev}
					},
				route_id         => $trip->{route_id},
				route_type       => 'rail',
				route_short_name => $vonalak->{ $v->att("vonal_idref") }->{mezo},
				route_long_name  => undef,
				route_desc       => $vonalak->{ $v->att("vonal_idref") }->{nev},
				trips            => [],
			};

			{    # Replace route name with the one present is OSM
				my $ref = $route->{route_short_name} || $route->{route_desc};
				$ref = 'Hortobágyi Öreg-tavi kisvasút' if $ref eq 'Hortobágy - Kondástó';

				if ( $osm_data->{shapes}->{train}->{$ref} ) {
					my $exemplar = $osm_data->{shapes}->{train}->{$ref}[0];
					$route->{route_long_name} = $exemplar->{name};
					$route->{route_long_name} =~ s/\s*\(.*?\)//go if $route->{route_long_name};
				}
			}

			$route->{route_long_name}
				.= ' (' . $vonatnemek->{ $v->att("fejjel") || $v->att("nem") } . ')'
				if ( $v->att("fejjel") || $v->att("nem") ) ne 'Sz';

			$ROUTES->{ $route->{route_id} } = $route;
		}

		push @{ $ROUTES->{ $trip->{route_id} }->{trips} }, $trip;
	}

=pod

	foreach my $route ( values %$ROUTES ) {
		foreach my $trip ( @{ $route->{trips} } ) {
			$route->{
				(
					       $trip->{direction_id}
						&& $trip->{direction_id} eq 'outbound' ? 'common_from' : 'common_to'
				)
				}->{ $trip->{stop_times}[-1]{stop_name} }++;
			$route->{
				(
					       $trip->{direction_id}
						&& $trip->{direction_id} eq 'outbound' ? 'common_to' : 'common_from'
				)
				}->{ $trip->{stop_times}[0]{stop_name} }++;
		}

		$route->{route_desc} = (
			sort { $route->{common_from}->{$b} <=> $route->{common_from}->{$a} }
				keys %{ $route->{common_from} }
			)[0]
			. ' / '
			. (
			sort { $route->{common_to}->{$b} <=> $route->{common_to}->{$a} }
				keys %{ $route->{common_to} }
			)[0];

		delete $route->{common_from};
		delete $route->{common_to};
	}

=cut

	$log->info("Merging data...");

	my $data = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
			trip_line_variants  => sub {
				my $route = $_[1];
				my $ref 
					= $route->{route_short_name}
					|| $route->{route_long_name}
					|| $route->{route_desc};

				$osm_data->{shapes}->{train}->{$ref}
					? @{ $osm_data->{shapes}->{train}->{$ref} }
					: ();
			},
		},
		$osm_data,
		{ routes => $ROUTES, },
	);

	$log->info("Dumping data...");

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_agency($_) for ( sort { $a->{agency_id} cmp $b->{agency_id} } @AGENCIES );

	#$dumper->dump_agency($_) for ( sort { $a->{agency_id} cmp $b->{agency_id} } values %$AGENCIES );

	$dumper->dump_route($_)
		for ( sort { $a->{route_id} cmp $b->{route_id} } @{ $data->{routes} } );
	$dumper->dump_stop($_) for ( map { $data->{stops}->{$_} } sort keys %{ $data->{stops} } );

	$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump() );

	$dumper->dump_statistics( $data->{statistics} );

	$dumper->deinit_dumper();
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
