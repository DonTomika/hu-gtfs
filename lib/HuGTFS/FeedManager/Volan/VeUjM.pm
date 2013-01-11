
=head1 NAME

HuGTFS::FeedManager::Volan::VeUjM

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Volan::VeUjM;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Volan::VeUjM;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Data::Dumper;

use WWW::Mechanize;
use Geo::Proj4;

use JSON qw/decode_json/;

use File::Spec::Functions qw/catfile/;

use DateTime;

use HuGTFS::Util qw(_D _S _T slurp burp seconds);
use HuGTFS::Cal;
use HuGTFS::OSMMerger;
use HuGTFS::Dumper;

BEGIN {
	$ENV{LC_ALL} = 'hu_HU.UTF-8';
}
use locale;

use constant {
	PROCESSES => 8,

	MAX_DAYS   => 2 * 31 + 2,
	START_DATE => DateTime->today->ymd(''),

	AUTOCOMPLETE_URL => "http://ujmenetrend.cdata.hu/uj_menetrend/volan/ajax_response_gen.php",
};

use Mouse;

with 'HuGTFS::FeedManager';
__PACKAGE__->meta->make_immutable;

no Mouse;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

my $agencies = {
	'Agria Volán' => {
		agency_id       => 'AGRIA-VOLAN',
		agency_name     => 'Agria Volán',
		agency_url      => 'http://www.agriavolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Alba Volán' => {
		agency_id       => 'ALBA-VOLAN',
		agency_name     => 'Alba Volán',
		agency_url      => 'http://www.albavolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Bács Volán' => {
		agency_id       => 'BACS-VOLAN',
		agency_name     => 'Bács Volán',
		agency_url      => 'http://www.bacsvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Bakony Volán' => {
		agency_id       => 'BAKONY-VOLAN',
		agency_name     => 'Bakony Volán',
		agency_url      => 'http://www.bakonyvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Balaton Volán' => {
		agency_id       => 'BALATON-VOLAN',
		agency_name     => 'Balaton Volán',
		agency_url      => 'http://www.balatonvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Borsod Volán' => {
		agency_id       => 'BORSOD-VOLAN',
		agency_name     => 'Borsod Volán',
		agency_url      => 'http://www.borsodvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Gemenc Volán' => {
		agency_id       => 'GEMENC-VOLAN',
		agency_name     => 'Gemenc Volán',
		agency_url      => 'http://www.gemencvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Hajdú Volán' => {
		agency_id       => 'HAJDU-VOLAN',
		agency_name     => 'Hajdú Volán',
		agency_url      => 'http://www.hajduvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Hatvani Volán' => {
		agency_id       => 'HATVANI-VOLAN',
		agency_name     => 'Hatvani Volán',
		agency_url      => 'http://www.hatvanivolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Jászkun Volán' => {
		agency_id       => 'JASZKUN-VOLAN',
		agency_name     => 'Jászkun Volán',
		agency_url      => 'http://www.jaszkunvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Kapos Volán' => {
		agency_id       => 'KAPOS-VOLAN',
		agency_name     => 'Kapos Volán',
		agency_url      => 'http://www.kaposvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Kisalföld Volán' => {
		agency_id       => 'KISALFOLD-VOLAN',
		agency_name     => 'Kisalföld Volán',
		agency_url      => 'http://www.kisalfoldvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Körös Volán' => {
		agency_id       => 'KOROS-VOLAN',
		agency_name     => 'Körös Volán',
		agency_url      => 'http://www.korosvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Kunság Volán' => {
		agency_id       => 'KUNSAG-VOLAN',
		agency_name     => 'Kunság Volán',
		agency_url      => 'http://www.kunsagvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Mátra Volán' => {
		agency_id       => 'MATRA-VOLAN',
		agency_name     => 'Mátra Volán',
		agency_url      => 'http://www.matravolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Nógrád Volán' => {
		agency_id       => 'NOGRAD-VOLAN',
		agency_name     => 'Nógrád Volán',
		agency_url      => 'http://www.nogradvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Pannon Volán' => {
		agency_id       => 'PANNON-VOLAN',
		agency_name     => 'Pannon Volán',
		agency_url      => 'http://www.pannonvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Somló Volán' => {
		agency_id       => 'SOMLO-VOLAN',
		agency_name     => 'Somló Volán',
		agency_url      => 'http://www.somlovolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Szabolcs Volán' => {
		agency_id       => 'SZABOLCS-VOLAN',
		agency_name     => 'Szabolcs Volán',
		agency_url      => 'http://www.szabolcsvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Tisza Volán' => {
		agency_id       => 'TISZA-VOLAN',
		agency_name     => 'Tisza Volán',
		agency_url      => 'http://www.tiszavolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Vasi Volán' => {
		agency_id       => 'VASI-VOLAN',
		agency_name     => 'Vasi Volán',
		agency_url      => 'http://www.vasivolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Vértes Volán' => {
		agency_id       => 'VERTES-VOLAN',
		agency_name     => 'Vértes Volán',
		agency_url      => 'http://www.vertesvolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Volánbusz (Budapest)' => {
		agency_id       => 'VOLANBUSZ-VOLAN',
		agency_name     => 'Volánbusz',
		agency_url      => 'http://www.volanbusz.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
	'Zala Volán' => {
		agency_id       => 'ZALA-VOLAN',
		agency_name     => 'Zala Volán',
		agency_url      => 'http://www.zalavolan.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
	},
};

my $proj
	= Geo::Proj4->new(
	"+proj=somerc +lat_0=47.14439372222222 +lon_0=19.04857177777778 +x_0=650000 +y_0=200000 +ellps=GRS67 +towgs84=52.684,-71.194,-13.975,-0.312,-0.1063,-0.3729,1.0191 +units=m +no_defs"
	);

#my $proj = Geo::Proj4->new("+proj=somerc +lat_0=47.14439372222222 +lon_0=19.04857177777778 +k_0=0.99993 +x_0=650000 +y_0=200000 +ellps=GRS67 +towgs84=52.684,-71.194,-13.975,-0.312,-0.1063,-0.3729,1.0191 +units=m +no_defs");

=head2 download

No Op.

=cut

sub download
{
	my $self = shift;

	my ( $places, $stops, $services, @days ) = ( {}, {}, {}, () );

	my $start_date = DateTime->new( _D( START_DATE || HuGTFS::Cal::CAL_START ) );
	while ( scalar @days < MAX_DAYS && $start_date->ymd('') <= HuGTFS::Cal::CAL_END ) {
		push @days, $start_date->clone;
		$start_date->add( days => 1 );
	}

	my $mech
		= WWW::Mechanize->new( agent =>
			'Mozilla/5.0 (Windows; U; Windows NT 6.1; nl; rv:1.9.2.13) Gecko/20101203 Firefox/3.6.13'
		);

	unless ( -f catfile( $self->data_directory, 'stop-places.csv' ) ) {

		# -> download list of places
		foreach ( 'a' ... 'z' ) {
			request_places( $_, $mech, $places );
		}

		# -> download list of stops
		foreach my $p ( sort keys %$places ) {
			request_stops( "$p, ", $mech, $stops );
		}

		my $settlements = { map { $_->{settlement_id} => $_ } values %$places };

		open( my $file, '>:utf8', catfile( $self->data_directory, 'stop-places.csv' ) );
		$file->print("stop_id,lsname,ls_id,site_code,settlement_id,eovx,eovy,lat,lon,zone\n");
		foreach my $s ( map {@$_} values %$stops ) {
			$file->print(
				"$s->{ls_id}_$s->{site_code},\"$s->{lsname}\",$s->{ls_id},$s->{site_code},$s->{settlement_id},$s->{eovx},$s->{eovy},$s->{lat},$s->{lon},"
					. uc( $settlements->{ $s->{settlement_id} }->{lsname} || '' )
					. "\n" );
		}
		close($file);
	}

	{
		$log->info("Loading stops...");

		my $CSV = Text::CSV::Encoded->new;
		open( my $file, catfile( $self->data_directory, "stop-places.csv" ) );
		$CSV->column_names( $CSV->getline($file) );
		while ( my $cols = $CSV->getline_hr($file) ) {
			$stops->{ $cols->{ls_id} }->[ $cols->{site_code} ] = $cols;
		}
	}

	if (0) {
		my @children = ();

		# fork -> send ...
		# -> download trips
		#	 -> foreach trip get [start, end, service_id]
		#	 -> add to list
		foreach my $i ( 35503 ... 35504 ) {
			$log->debug("Trip: $i");
			$mech->get(
				"http://ujmenetrend.cdata.hu/uj_menetrend/volan/talalat_kifejtes.php?run_id=$i&domain_type=1&sls_id=1&els_id=1"
			);

			my $content = $mech->content;
			next unless $content =~ m{<td  style="color:#000000;">}o;

			$content =~ s{iso-8859-2}{utf-8};

			burp( catfile( $self->data_directory, 'trips', "$i.html" ), $content );
		}
	}

	my $stop_map = { map { $_->[0]->{lsname} => $_->[0] } values %$stops };

	$log->info("Loading trips...");
	foreach ( glob( catfile( $self->data_directory, 'trips', '*.html' ) ) ) {
		my $content = slurp $_;

		my ( $service, $from, $to )
			= ( $content
				=~ m{közlekedik: <b>(.*?)</b>.*?<td  style="color:#000000; text-align:left;" >(.*?)</td>.*<td  style="color:#000000;text-align:left;" align="left" >(.*?)</td>}os
			);

		$service = lc($service);

		next if $service =~ m/^(?:egyenlőre nem közlekedik|egyelőre nem közlekedik)$/o;

		$from = normalize_name($from) unless $stop_map->{$from};
		$to   = normalize_name($to)   unless $stop_map->{$to};

		$services->{$service} = {
			name => $service,
			from => $from,
			to   => $to,
			}
			unless $services->{$service};
	}

	# fork -> send ...
	# -> foreach service
	# 	-> foreach day
	# 		-> plan trip from [start, end, day] -> mine service validity

	{
		$log->info("Loading calendar...");

		state $service_num = 0;
		HuGTFS::Cal->empty;

		my $existing = {};

		if ( -f catfile( $self->data_directory, "calendar.txt" ) ) {
			my $CSV = Text::CSV::Encoded->new;
			open( my $file, catfile( $self->data_directory, "calendar.txt" ) );
			$CSV->column_names( $CSV->getline($file) );
			while ( my $cols = $CSV->getline_hr($file) ) {
				next unless $cols->{service_id} =~ m/(\d+)/;

				$service_num = $1 > $service_num ? $1 : $service_num;

				$existing->{ $cols->{service_desc} } = HuGTFS::Cal->new(%$cols);
			}

			open( $file, catfile( $self->data_directory, "calendar_dates.txt" ) );
			$CSV->column_names( $CSV->getline($file) );
			while ( my $cols = $CSV->getline_hr($file) ) {
				my $cal = HuGTFS::Cal->find( $cols->{service_id} );
				next unless $cal;

				$cal->add_exception( $cols->{date},
					$cols->{exception_type} eq '1' ? 'added' : 'removed' );
			}
		}

		foreach my $service ( values %$services ) {
			if ( $existing->{ $service->{name} } ) {
				$service->{service} = $existing->{ $service->{name} };
			}
			else {
				$service->{service} = HuGTFS::Cal->new(
					service_id   => 'SERVICE' . ++$service_num,
					service_desc => $service->{name},
					start_date   => HuGTFS::Cal::CAL_START,
					end_date     => HuGTFS::Cal::CAL_END,
				);
			}

			my ( $from, $to )
				= ( $stop_map->{ $service->{from} }, $stop_map->{ $service->{to} } );

			$log->fatal("Missing head stop: $service->{from} / $service->{to}")
				unless $from && $to;
		}
	}

	my $abort            = 0;
	my $service_requests = 0;

	$SIG{INT} = sub {
		$log->warn("Aborting...");
		$abort = 1;
	};

	$SIG{HUP} = sub {
		$log->warn("Requests: $service_requests (dumping data)");

		my $dumper = HuGTFS::Dumper->new( dir => $self->data_directory );
		$dumper->dump_calendar($_) for HuGTFS::Cal->dump;
		$dumper->deinit();
	};

	$mech->proxy( ['http'], 'socks://localhost:9050' );

	foreach my $service ( sort { $a->{name} cmp $b->{name} } values %$services ) {
		last if $abort;

		$log->info("Service: $service->{name}");
		$log->info("Service: \t[$service->{from} -> $service->{to}]");
		foreach my $day (@days) {
			next if defined $service->{service}->get_exception($day);

			last if $abort;

			$log->debug( "Day: " . $day->ymd('-') );

			my ( $from, $to )
				= ( $stop_map->{ $service->{from} }, $stop_map->{ $service->{to} } );

			eval {
				$mech->post(
					"http://ujmenetrend.cdata.hu/uj_menetrend/volan/talalatok.php#idopont",
					{
						datum    => $day->ymd('-'),
						utirany  => 'oda',
						naptipus => '0',
						napszak  => '0',
						hour     => '00',
						min      => '00',

						honnan               => $from->{lsname},
						honnan_settlement_id => $from->{settlement_id},
						honnan_ls_id         => $from->{ls_id},
						honnan_eovx          => $from->{eovx},
						honnan_eovy          => $from->{eovy},
						honnan_site_code     => '0',
						honnan_zoom          => '9',
						ind_stype            => 'megallo',

						hova               => $to->{lsname},
						hova_settlement_id => $to->{settlement_id},
						hova_ls_id         => $to->{ls_id},
						hova_eovx          => $to->{eovx},
						hova_eovy          => $to->{eovy},
						hova_site_code     => '0',
						hova_zoom          => '9',
						erk_stype          => 'megallo',

						keresztul_stype         => 'megallo',
						keresztul               => '',
						keresztul_settlement_id => '',
						keresztul_ls_id         => '',
						keresztul_zoom          => '',
						keresztul_eovx          => '',
						keresztul_eovy          => '',
						keresztul_site_code     => '',

						target       => '0',
						rendezes     => '0',
						filtering    => '0',
						var          => '0',
						maxvar       => '240',
						maxatszallas => '0',
						preferencia  => '1',
						helyi        => 'No',
						maxwalk      => '0',
						talalatok    => '1',
						odavissza    => '0',
						ext_settings => 'block',
						submitted    => '1',
					}
				);
			};

			if ($@) {
				$log->warn("Failed request: $@");
				sleep 1;
				redo;
			}

			my $content = $mech->content;

			$log->fatal("Korlátozva...") and sleep 5 and redo
				if $content =~ m/Korlátozva/;

			$service_requests++;

			$service->{service}->add_exception( $day, 'removed' );

			while ( $content =~ m{<div id="expl_\d+">(.+?)</div>}og ) {
				my $s = lc($1);
				if ( exists $services->{$s} ) {
					$services->{$s}->{service}->add_exception( $day, 'added' );
				}
				elsif ( $s ne 'közlekedik: lásd a kifejtésben' ) {
					$log->warn("Missing service: $s");
				}
			}
		}
	}

	delete $SIG{INT};
	delete $SIG{HUP};

	$log->info("Service requests: $service_requests");

	my $dumper = HuGTFS::Dumper->new( dir => $self->data_directory );
	$dumper->dump_calendar($_) for HuGTFS::Cal->dump;
	$dumper->deinit();

	return 1;
}

sub create_download_child
{
	my ($children) = @_;
}

sub request_places
{
	my ( $tidbit, $mech, $places ) = @_;

	$log->debug("Downloading places: <$tidbit>");

	my $u
		= "ajaxquery=query%3Dget_stations2%26fieldvalue%3D${tidbit}%26fieldname%3Dhonnan%26divname%3Dhonnan_choices%26network%3D";
	utf8::encode($u);
	$mech->post( AUTOCOMPLETE_URL, content => $u );

	my $content = $mech->content;

	#utf8::encode($content);
	$content =~ s{^.*?document.getElementById\('honnan_choices'\)\.innerHTML = '}{};
	$content =~ s{</div>}{</div>\n}g;
	$content =~ s{<div id="[^"]*" [^>]*? onMouseOut="[^"]*"\s+}{}g;
	$content =~ s{zoom="\d+"\s+}{}g;
	$content =~ s{<img[^>]*?>}{}g;
	$content =~ s{>[^<]*</div>}{}g;
	$content =~ s{ +}{ }g;

	while ( $content
		=~ m{lsname="([^"]+?)" ls_id="(\d+)" site_code="(\w+)" settlement_id="(\d+)" eovx="([\d.]+)" eovy="([\d.]+)" dindex="(\d+)"}g
		)
	{
		if ( $7 eq '80' ) {
			for ( 'a' ... 'z' ) {
				request_places( $tidbit . $_, $mech, $places );
			}
		}

		next if $places->{$1} || $2 || $3;

		my @coord = $proj->inverse( $5, $6 );
		$places->{$1} = {
			lsname        => $1,
			ls_id         => $2,
			site_code     => $3,
			settlement_id => $4,
			eovx          => $5,
			eovy          => $6,
			lat           => $coord[0],
			lon           => $coord[1],
		};
	}
}

sub request_stops
{
	my ( $tidbit, $mech, $stops ) = @_;

	$log->debug("Downloading stops:  <$tidbit>");

	my $u
		= "ajaxquery=query%3Dget_stations2%26fieldvalue%3D${tidbit}%26fieldname%3Dhonnan%26divname%3Dhonnan_choices%26network%3D";
	utf8::encode($u);
	$mech->post( AUTOCOMPLETE_URL, content => $u );

	my $content = $mech->content;

	#utf8::encode($content);
	$content =~ s{^.*?document.getElementById\('honnan_choices'\)\.innerHTML = '}{};
	$content =~ s{</div>}{</div>\n}g;
	$content =~ s{<div id="[^"]*" [^>]*? onMouseOut="[^"]*"\s+}{}g;
	$content =~ s{zoom="\d+"\s+}{}g;
	$content =~ s{<img[^>]*?>}{}g;
	$content =~ s{>[^<]*</div>}{}g;
	$content =~ s{ +}{ }g;

	while ( $content
		=~ m{lsname="([^"]+?)" ls_id="(\d+)" site_code="(\w+)" settlement_id="(\d+)" eovx="([\d.]+)" eovy="([\d.]+)" dindex="(\d+)"}g
		)
	{

		#print Dumper([$1, $2, $3, $7]);

		next unless $2 ne '0';

		if ( 1 && ( $7 eq '80' || $7 eq '79' ) ) {
			for ( 'a' ... 'z', '0' ... '9' ) {
				request_stops( $tidbit . $_, $mech, $stops );
			}
		}

		my @coord = $proj->inverse( $5, $6 );

		$stops->{$2}->[$3] = {
			lsname        => $1,
			ls_id         => $2,
			site_code     => $3,
			settlement_id => $4,
			eovx          => $5,
			eovy          => $6,
			lat           => $coord[0],
			lon           => $coord[1],
		};
	}
}

=head2 parse

=cut

sub parse
{
	my $self    = shift;
	my %options = @_;

	my ( $agency, $routes, $stops, $stop_id_by_name, $glob );

	if ( $options{selective} ) {
		$glob = $options{selective} . '.html';
	}
	else {
		$glob = '*.html';
	}

	$agency = {
		agency_name     => 'Volán',
		agency_id       => 'VOLAN',
		agency_url      => 'http://menetrendek.hu',
		agency_timezone => 'Europe/Budapest',
		agency_lang     => 'hu',
		agency_phone    => undef,
	};

	$routes->{UNKNOWN} = {
		route_id        => 'UNKNOWN',
		route_long_name => 'ismeretlen',
		route_type      => 'bus',
		agency_id       => 'VOLAN',
		route_desc      => undef,
		trips           => [],
	};

	my $CSV = Text::CSV::Encoded->new(
		{
			encoding_in  => 'utf8',
			encoding_out => 'utf8',
			sep_char     => ',',
			quote_char   => '"',
			escape_char  => '"',
		}
	);

	HuGTFS::Cal->load(
		{
			service_id => 'DAILY',
			start_date => '20110101',
			end_date   => '20111212',
			monday     => 1,
			tuesday    => 1,
			wednesday  => 1,
			thursday   => 1,
			friday     => 1,
			saturday   => 1,
			sunday     => 1
		}
	);

	$log->info("Loading stops...");

	open( my $file, catfile( $self->data_directory, 'stop-places.csv' ) );
	$CSV->column_names( $CSV->getline($file) );
	while ( my $s = $CSV->getline_hr($file) ) {

		#print STDERR "'" . normalize_name( $s->{lsname} ) . "',\n";
		$s->{lsname} = expand_name( $s->{lsname} );

		$stops->{ $s->{stop_id} } = {
			stop_id   => $s->{stop_id},
			stop_code => 'B' . ('0' x (5 - $s->{ls_id})) . $s->{ls_id},
			stop_name => $s->{lsname},
			stop_lat  => $s->{lat},
			stop_lon  => $s->{lon},
			zone_id   => $s->{zone},
		};

		unless ( $stops->{ $s->{stop_id} }->{zone_id} ) {
			if ( $s->{lsname} =~ m/^Budapest/ ) {
				$stops->{ $s->{stop_id} }->{zone_id} = 'BUDAPEST';
			}
			else {
				$stops->{ $s->{stop_id} }->{zone_id} = 'ISMERETLEN';
			}
		}

		$stop_id_by_name->{ $s->{lsname} } = $s->{stop_id};
	}

	my $services = {};
	{
		$log->info("Loading calendar...");

		HuGTFS::Cal->empty;

		my $CSV = Text::CSV::Encoded->new;
		open( my $file, catfile( $self->data_directory, "calendar.txt" ) );
		$CSV->column_names( $CSV->getline($file) );
		while ( my $cols = $CSV->getline_hr($file) ) {
			$services->{ $cols->{service_desc} } = HuGTFS::Cal->new($cols)->service_id;
		}

		open( $file, catfile( $self->data_directory, "calendar_dates.txt" ) );
		$CSV->column_names( $CSV->getline($file) );
		while ( my $cols = $CSV->getline_hr($file) ) {
			HuGTFS::Cal::add_exception( $cols->{service_id}, $cols->{date},
				$cols->{exception_type} eq '1' ? 'added' : 'removed' );
		}
	}

	$log->info("Parsing trips...");

	my $fake_trip = 0;

TRIP:

	foreach ( glob( catfile( $self->data_directory, 'trips', $glob ) ) ) {
		my $data = slurp $_;
		my ($id) = ( $_ =~ m{/(\d+)\.html$} );
		# <span style="font-size:14px;">közlekedik: <b>munkanap</b><br></span>
		# <b style="white-space:nowrap; font-size:16px;">1036/1 járat&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Közlekedteti: Agria Volán</b><br><br><span style="font-size:14px;">közlekedik: <b>naponta</b><br></span><br><div align="center" style="overflow:auto;" id="timetable"><table width="95%" class="kifejtestabla">
		# <b style="white-space:nowrap; font-size:16px;">2640/31 járat&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Közlekedteti: Volánbusz (Budapest)</b><br><br><span style="font-size:14px;">járat info: <b>BKSZ 668</b>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;közlekedik: <b>munkanap</b><br></span><br><div align="center" style="overflow:auto;" id="timetable"><table width="95%" class="kifejtestabla">
		my ( $route_number, $trip_number, $operator, $bksz_route_number, $service_text )
			= ( $data
				=~ m{(?:<b [^>]*>(\d+)/(\d+) járat(?:&nbsp;)*Közlekedteti: ([^<]*)</b>.*?)?<span [^>]*>(?:járat info: <b>([^<]*)</b>.*?(?:&nbsp;)*)?közlekedik: <b>([^<]*)</b><br></span>}o
			);

		if ($bksz_route_number) {
			if ( $bksz_route_number =~ m/^BKSZ (\d+)$/ ) {
				 $bksz_route_number = $1;
			}
			else {
				$log->warn("Unknown jarat info (trip $id): $bksz_route_number");
				undef $bksz_route_number;
			}
		}

		$route_number = '0' . $route_number if $route_number && $route_number < 1000;

		unless ($route_number) {
			($service_text) = ( $data =~ m{közlekedik: <b>(.*?)</b>} );
			( $route_number, $trip_number ) = ( 'UNKNOWN', ++$fake_trip );
		}

		$service_text = lc($service_text);

		next if $service_text =~ m/^(?:egyenlőre nem közlekedik|egyelőre nem közlekedik)$/o;

		$log->fatal( "Bad trip? <id: $id> <route: $route_number> <"
				. ( $bksz_route_number || "undef" )
				. "> <trip: $trip_number> <$service_text>" )
			unless $id && $route_number && $service_text;

		my $trip = {
			operator              => $operator,
			trip_id               => "$id",
			route_id              => $bksz_route_number || $route_number,
			service_id            => undef,
			trip_headsign         => undef,
			direction_id          => ( $trip_number % 2 ) ? 'inbound' : 'outbound',
			trip_short_name       => $trip_number,
			trip_bikes_allowed    => 0,
			wheelchair_accessible => 0,

			stop_times => [],

			#trip_url              => undef,
			#block_id              => undef,
			#shape_id              => undef,
		};

		$trip->{service_id} = $services->{$service_text} || 'NEVER';
		$log->warn("Unknown service [trip $id]: $service_text")
			unless $trip->{service_id} ne 'NEVER';

		delete $trip->{direction_id} unless $route_number ne 'UNKNOWN';

		unless ( $routes->{ $trip->{route_id} } ) {
			$routes->{ $trip->{route_id} } = {
				route_id         => $trip->{route_id},
				route_short_name => $bksz_route_number || $route_number,
				route_type       => 'bus',
				agency_id        => 'VOLAN',
				route_desc       => undef,
				trips            => [],

				#route_url        => undef,
				#route_long_name  => undef,
			};
		}
=pod

			<!--<td>Budapest_XIV.</td> -->
			<td  style="color:#000000; text-align:left;" >Budapest, Stadion autóbusz-pályaudvar</td>
			<td>&nbsp;</td>
			<td>13:45</td>
			<td style="color:#990000; font-size:12px;">&nbsp;</td>
			<td style="color:#990000; font-size:12px;"></td><td style="text-align:right;">0.0</td><td>&nbsp;</td></tr><tr>

				<!--<td>Bükkszék</td> -->
				<td  style="color:#000000;text-align:left;" align="left" >Bükkszék, szövetkezeti italbolt</td>
				<td>16:33</td>
				<td>&nbsp;</td>
				<td style="color:#990000; font-size:12px;"></td>
				<td>&nbsp;</td>             
				<td  style="text-align:right;">133.1</td><td>&nbsp;</td></tr></table>

			<td  style="color:#000000; text-align:left;" >Budapest, Stadion autóbusz-pályaudvar</td>
			<td  style="color:#000000;text-align:left;" align="left" >Bükkszék, szövetkezeti italbolt</td>

			<td style="text-align:right;">000.0</td><td>&nbsp;</td>
			<td style="text-align:right;">133.1</td><td>&nbsp;</td>
=cut

		while ( $data
			=~ m{<td  style="color:#000000;\s?text-align:left;"(?: align="left")? >(.*?)</td>.*?<td>(&nbsp;|\d\d:\d\d)</td>.*?<td>(&nbsp;|\d\d:\d\d)</td>.*?<td\s+style="text-align:right;">(\d+\.\d+)</td><td>(.*?)</td>}gos
			)
		{
			my ( $stop_name, $arrival, $departure, $dist_traveled, $note )
				= ( $1, $2, $3, $4, $5 );

			$stop_name = expand_name($stop_name);

			$note = undef if $note && $note eq '&nbsp;';

			if($note && $note !~ m{^(?:&nbsp; <span style="font-size:10px;">csak (?:fel|le)szállás</span>)$}) {
				$log->warn("Unknown note ($id, $stop_name): $note");
			}

			unless ( $stop_id_by_name->{$stop_name} ) {
				unless ( $self->{warned_missing_stop}->{$stop_name} ) {
					$log->fatal( "Missing stop: " . normalize_name($1) );
					$self->{warned_missing_stop}->{$stop_name} = 1;
				}
				next;
			}

			push @{ $trip->{stop_times} },
				{
				stop_id             => $stop_id_by_name->{$stop_name},
				arrival_time        => $arrival eq '&nbsp;' ? $departure : $arrival,
				departure_time      => $departure eq '&nbsp;' ? $arrival : $departure,
				shape_dist_traveled => $dist_traveled,
				pickup_type         => $note && $note =~ m/csak leszállás/ ? 1 : 0,
				drop_off_type       => $note && $note =~ m/csak felszállás/ ? 1 : 0,
				};

			# > 18 hours difference between departure/arrival
			if ( $#{ $trip->{stop_times} }
				&& seconds( $trip->{stop_times}[-2]{departure_time} )
				- seconds( $trip->{stop_times}[-1]{arrival_time} ) > 18 * 60 * 60 )
			{
				$trip->{stop_times}[-1]{arrival_time}
					= _T( _S( $trip->{stop_times}[-1]{arrival_time} ) + 24 * 60 * 60 );
			}

			# > 12 hours difference between arrival/departure
			if (  seconds( $trip->{stop_times}[-1]{arrival_time} )
				- seconds( $trip->{stop_times}[-1]{departure_time} ) > 18 * 60 * 60 )
			{
				$trip->{stop_times}[-1]{departure_time}
					= _T( _S( $trip->{stop_times}[-1]{departure_time} ) + 24 * 60 * 60 );
			}

			if (
				$#{ $trip->{stop_times} }
				&& (
					(
						seconds( $trip->{stop_times}[-2]{departure_time} )
						> seconds( $trip->{stop_times}[-1]{arrival_time} )
					)
					|| ( seconds( $trip->{stop_times}[-1]{departure_time} )
						< seconds( $trip->{stop_times}[-1]{arrival_time} ) )
				)
				)
			{
				$log->warn("trip $id: decreasing stop times [$stop_name]");
				pop @{ $trip->{stop_times} };
			}
		}

		next unless scalar @{ $trip->{stop_times} };

		$trip->{trip_headsign} = $stops->{ $trip->{stop_times}->[-1]->{stop_id} }->{stop_name};

		push @{ $routes->{ $trip->{route_id} }->{trips} }, $trip;
	}

	foreach my $r ( values %$routes ) {
		foreach my $trip ( @{ $r->{trips} } ) {
			$r->{
				(
					       $trip->{direction_id}
						&& $trip->{direction_id} eq 'outbound' ? 'common_from' : 'common_to'
				)
				}->{ $stops->{ $trip->{stop_times}[-1]{stop_id} }->{stop_name} }++;
			$r->{
				(
					       $trip->{direction_id}
						&& $trip->{direction_id} eq 'outbound' ? 'common_to' : 'common_from'
				)
				}->{ $stops->{ $trip->{stop_times}[0]{stop_id} }->{stop_name} }++;
		}

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

	$log->info("Splitting into per-agency datasets...");

	my $new_routes = {};
	foreach my $route ( values %$routes ) {
		foreach my $trip ( @{ $route->{trips} } ) {
			my $a        = $trip->{operator} ? $agencies->{ $trip->{operator} } : $agency;
			my $route_id = $a->{agency_id} . '+' . $route->{route_id};

			unless ( $new_routes->{$route_id} ) {
				$new_routes->{$route_id} = {
					%{$route},
					agency_id => $a->{agency_id},
					route_id  => $route_id,
					trips     => [],
				};
			}

			push @{ $new_routes->{$route_id}->{trips} }, $trip;

			delete $trip->{operator};
		}
	}

	$log->info("Dumping data & creating shapes...");

	my $used_stops = {};

	my $osm_data = HuGTFS::OSMMerger->parse_osm( qr/^(?:Volánbusz)$/o, $self->osm_file );

	my $data = HuGTFS::OSMMerger->new(
		{
			skipped_route => sub { },
			skipped_trip  => sub {
				my $trip = $_[0];
				$used_stops->{ $_->{stop_id} } = 1 for @{ $trip->{stop_times} };
				&skipped_trip_real;
			},
			finalize_trip => sub {
				my $trip = $_[0];
				$used_stops->{ $_->{stop_id} } = 1 for @{ $trip->{stop_times} };
			},
			remove_geometryless => 1,
		},
		$osm_data,
	);

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_calendar($_) for HuGTFS::Cal->dump;
	$dumper->dump_agency($agency);
	$dumper->dump_agency($_) for sort { $a->{agency_id} cmp $b->{agency_id} } values %$agencies;

	foreach my $r ( sort { $a->{route_id} cmp $b->{route_id} } values %$new_routes ) {
		delete $routes->{ $r->{route_id} };

		$data->merge( { routes => [$r], stops => $stops } );

		$dumper->dump_route($_) for @{ $data->{routes} };
	}

	$dumper->dump_stop($_)
		for sort { $a->{stop_id} cmp $b->{stop_id} } values %{ $data->{stops} };

	$dumper->dump_stop($_)
		for sort { $a->{stop_id} cmp $b->{stop_id} }
		grep     { $used_stops->{ $_->{stop_id} } } values %$stops;

	$dumper->dump_statistics( $data->{statistics} );

	$data->finalize_statistics;

	$dumper->deinit();
}

sub skipped_trip_real
{
	state $mech        = WWW::Mechanize->new;
	state $cache       = {};
	state $shape_cache = {};

	my ( $trip, $route, $data, $gtfs ) = @_;

	return $trip
		if $route->{route_short_name}
				&& $route->{route_short_name} > 1000
				&& ( $route->{route_short_name} < 2100 || $route->{route_short_name} >= 2300 )
				&& ( $route->{route_short_name} < 2400 || $route->{route_short_name} >= 2500 );

	$trip->{shape} = {
		shape_id     => 'SHAPE_' . $trip->{trip_id},
		shape_points => [],
	};

	my $prev_st = $trip->{stop_times}[0];
	foreach my $st ( @{ $trip->{stop_times} }[ 1 ... $#{ $trip->{stop_times} } ] ) {
		my $url = 'http://localhost:5000/viaroute?output=json&instructions=false';

		my ( $prev_stop, $stop ) = @{ $gtfs->{stops} }{ $prev_st->{stop_id}, $st->{stop_id} };

		$url .= "&start=$prev_stop->{stop_lat},$prev_stop->{stop_lon}";
		$url .= "&dest=$stop->{stop_lat},$stop->{stop_lon}";

		my @points = ();
		if ( $cache->{$url} ) {
			@points = @{ $cache->{$url} };
		}
		else {
			$mech->get($url);

			my $json = eval { decode_json( $mech->content ) };
			if ($@) {
				$log->fatal("JSON Decode error: $@");
				$log->fatal("URL: $url");

				$json = { status => '1' };
			}

			if ( $json->{status} eq '0' ) {
				@points = @{ $json->{route_geometry} };
			}
			else {
				@points = ();
			}

			$cache->{$url} = \@points;
		}

		my $i = 1;

		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $prev_stop->{stop_lat},
			shape_pt_lon        => $prev_stop->{stop_lon},
			shape_dist_traveled => $prev_st->{shape_dist_traveled} + $i / 10000,
			};

		foreach (@points) {
			push @{ $trip->{shape}->{shape_points} },
				{
				shape_pt_lat        => $_->[0],
				shape_pt_lon        => $_->[1],
				shape_dist_traveled => $prev_st->{shape_dist_traveled} + ( ++$i ) / 10000,
				};
		}

		push @{ $trip->{shape}->{shape_points} },
			{
			shape_pt_lat        => $stop->{stop_lat},
			shape_pt_lon        => $stop->{stop_lon},
			shape_dist_traveled => $st->{shape_dist_traveled},
			};

		$prev_st = $st;
	}

	my $shape_sha = HuGTFS::OSMMerger::shape_sha256( $trip->{shape} );
	if ( $shape_cache->{$shape_sha} ) {
		$trip->{shape_id} = $shape_cache->{$shape_sha};
		delete $trip->{shape};
	}
	else {
		$shape_cache->{$shape_sha} = $trip->{shape}->{shape_id};
	}

=pod
	my $shape_sha = HuGTFS::OSMMerger::shape_sha256( $trip->{shape} );
	if ( $shape_cache->{$shape_sha}
		&& HuGTFS::OSMMerger::shape_equal( $trip->{shape}, $shape_cache->{$shape_sha} ) )
	{
		$trip->{shape_id} = $shape_cache->{$shape_sha}->{shape_id};
		delete $trip->{shape};
	}
	else {
		$shape_cache->{$shape_sha} = HuGTFS::OSMMerger::shape_clone( $trip->{shape} );
	}
=cut

	return $trip;
}

# converts to menetrendek.hu name
sub normalize_name
{
	$_ = shift;

	s/\[\d+\]//go;
	s/\.\././go;

	s/\s+/ /go;
	s/autóbuszforduló/autóbusz-forduló/go;
	s/Budapest, Stadion aut\. pu\./Budapest, Stadion autóbusz-pályaudvar/go;
	s/Bp\., Újpest Városkapu vasútállomás XIII\. ker\./Budapest(Újpest), Városkapu vasútállomás XIII. ker./go;
	s/^Bp\./Budapest/go;

	s/Hács, tsz\./Hács, Tsz/go;
	s/műv\. otthon/Művelődési otthon/go;
	s/műv\. ház/Művelődési Ház/go;
	s/Műv\. /Művelődési /go;

	s/orvosi rendelo/orvosi rendelő/go;
	s/vendéglo/vendéglő/go;
	s/földmuves szövetkezet/földműves szövetkezet/;

	state $map = {
#<<<
		"11,4-es km tábla,3501-es út"                        => "11,4-es km tábla, 3501-es út",
		"15,3-as km-kő"                                      => "15,3-as km kő",
		"26. sz. fő. u. Sz.besenyői elágazás"                => "26. sz. főút szirmabesenyői elágazás",
		"3,9 km. tábla"                                      => "3,9 km tábla",
		"46-os major bek. út"                                => "46-os major bekötő út",
		"47-es major közp."                                  => "47-es major központ",
		"4 -es km kő II."                                    => "4-es km kő II.",
		"52-es major bek. út"                                => "52-es major bekötő út",
		"52-es major közp."                                  => "52-es major központ",
		"57-es major, közp."                                 => "57-es major, központ",
		"Abapuszta, vasútállomás mh."                        => "Abapuszta, vasútállomás megállóhely",
		"Abasár, P.vörösmarti u.35."                         => "Abasár, Vörösmarty Mihály út 35.",
		"Abaújszántó, Mg.Szakközép iskola"                   => "Abaújszántó, Mezőgazdasági Szakközép iskola",
		"Abony, Abonyi L. u."                                => "Abony, Abonyi Lajos utca",
		"Abony, Ságvári E. Tsz. üz. egys. bej."              => "Abony, Ságvári Endre Tsz üzemegység bejárat",
		"Abony, Ságvári Tsz. gépt."                          => "Abony, Ságvári Termelőszövetkezet géptelep",
		"Abony, Ságvári Tsz. központ"                        => "Abony, Ságvári Termelőszövetkezet központ",
		"Ács, Béke u."                                       => "Ács, Béke utca",
		"Ács, Dózsa Gy. u."                                  => "Ács, Dózsa György utca",
		"Ács, Újbarázda u."                                  => "Ács, Újbarázda utca",
		"Ács, Zöldfa u."                                     => "Ács, Zöldfa utca",
		"Adács, Róbert K.u."                                 => "Adács, Róbert Károly út",
		"Ádánd, építőanyag ker."                             => "Ádánd, építőanyag kereskedés",
		"Ádánd, Műv. Otthon"                                 => "Ádánd, Művelődési Otthon",
		"Ádánd, Zrínyi u."                                   => "Ádánd, Zrínyi utca",
		"Agárd, Költségvetési ü."                            => "Agárd, Költségvetési üzem",
		"Agárd, Mikszáth K. u."                              => "Agárd, Mikszáth Kálmán utca",
		"Ágfalva, Patak u."                                  => "Ágfalva, Patak utca",
		"Aggtelek, Kossuth u.Barlang b.u"                    => "Aggtelek, Kossuth utca Barlang bejárati út",
		"Agró-Telek Mg. Kft."                                => "Agró-Telek Mezőgazdasági Kft.",
		"Ajak, ref. templom"                                 => "Ajak, református templom",
		"Ajka Dózsa Gy.u."                                   => "Ajka, Dózsa György utca",
		"Ajka, Virágzó TSZ. bejárati út"                     => "Ajka, Virágzó Termelőszövetkezet bejárati út",
		"Alap, sz. vendéglő"                                 => "Alap, szövetkezeti vendéglő",
		"Albertirsa, Győzelem u. (közp. iskola)"             => "Albertirsa, Győzelem utca (központi iskola)",
		"Albertirsa, Katona Gy. u."                          => "Albertirsa, Katona Gyula utca",
		"Albertirsa, Szt. István út"                         => "Albertirsa, Szent István út",
		"Alkotmány Tsz (4501 sz.út)"                         => "Alkotmány Tsz (4501 sz. út)",
		"Almamellék, Kossuth u. 55"                          => "Almamellék, Kossuth utca 55.",
		"Álmosd, Bartók B.u.43."                             => "Álmosd, Bartók Béla utca 43.",
		"Álmosd, Kossuth u."                                 => "Álmosd, Kossuth utca",
		"Álmosd, Széchenyi u.6."                             => "Álmosd, Széchenyi utca 6.",
		"Alsónémedi, D.haraszti u. 13."                      => "Alsónémedi, Haraszti utca 13.",
		"Alsónémedi, D.haraszti u. 81."                      => "Alsónémedi, Haraszti utca 81.",
		"Alsópáhok, Dózsa u. 131"                            => "Alsópáhok, Dózsa utca 131.",
		"Alsózsolca, Arany J.u."                             => "Alsózsolca, Arany János utca",
		"Alsózsolca, Betonelőregyártó üzem b. u"             => "Alsózsolca, Betonelőregyártó üzem bejárati út",
		"Apagy, Bajcsy Zs. u."                               => "Apagy, Bajcsy-Zsilinszky utca",
		"Apagy, Főiskolai Tangazd."                          => "Apagy, Főiskolai Tangazdaság",
		"Apátistvánfalva (Balázsfalva.), autóbusz-váróterem" => "Apátistvánfalva (Balázsfalva), autóbusz-váróterem",
		"Áporka, Petőfi S. u."                               => "Áporka, Petőfi Sándor utca",
		"Apróhomok, 8.sz.bolt"                               => "Apróhomok, 8. sz. bolt",
		"Aranykalász Tsz. gépcsop."                          => "Aranykalász Tsz. gépcsoport",
		"Aranyosapáti, József A. u. 21."                     => "Aranyosapáti, József Attila utca 21.",
		"Arnót, Lévay J. u."                                 => "Arnót, Lévay utca",
		"Ároktő, Petőfi u."                                  => "Ároktő, Petőfi utca",
		"Árpádhalom, Székács u."                             => "Árpádhalom, Székács utca",
		"Ártánd, Kossuth u."                                 => "Ártánd, Kossuth utca",
		"Ártánd, Rákóczi u.87."                              => "Ártánd, Rákóczi utca 87.",
		"Ásotthalom, ált. iskola"                            => "Ásotthalom, általános iskola",
		"Ásotthalom, Gagarin u."                             => "Ásotthalom, Gagarin utca",
		"Ásotthalom, Köztársaság u."                         => "Ásotthalom, Köztársaság utca",
		"Ásotthalom, Munkácsy u."                            => "Ásotthalom, Munkácsy utca",
		"A.szalók, Balassi u."                               => "Abádszalók, Balassi utca",
		"A.szalók, Ezüstkal. u."                             => "Abádszalók, Ezüstkalász út",
		"A.szalók, Kossuth út"                               => "Abádszalók, Kossuth út",
		"A.szalók, Madách u."                                => "Abádszalók, Madách utca",
		"A.szalók, Rozmaring u."                             => "Abádszalók, Rozmaring utca",
		"Aszód, Arany J.u."                                  => "Aszód, Arany János utca",
		"Aszód, Bethlen G. u."                               => "Aszód, Bethlen Gábor utca",
		"Áta, Kossuth L. u. 45."                             => "Áta, Kossuth Lajos utca 45.",
		"Babócsa, sz.étt."                                   => "Babócsa, szövetkezeti étterem",
		"Babót, szövetkezeti bolt."                          => "Babót, szövetkezeti bolt",
		"Bácsalmás, 12. sz bolt"                             => "Bácsalmás, 12. sz. bolt",
		"Bácsbokod, Gépjavító V."                            => "Bácsbokod, Gépjavító Vállalat",
		"Badacsonytomaj, K.tóti elágazás"                    => "Badacsonytomaj, káptalantóti elágazás",
		"Bagod, Vitenyédi u. 58"                             => "Bagod, Vitenyédi utca 58.",
		"Baja, Kálvária elágazás"                            => "Baja, Kálvária",
		"Baja, Közúti Ig. kirendeltség"                      => "Baja, Közúti Igazgatóság kirendeltség",
		"Bak, Kossuth u. 91"                                 => "Bak, Kossuth u. 91.",
		"Balatonendréd, ref.templom"                         => "Balatonendréd, református templom",
		"Balkányi Állami Gazdaság üe."                       => "Balkányi Állami Gazdaság üzemegység",
		"Basal, Művelődési Ház"                              => "Basal, Művelődési ház",
		"Bátonyterenye, Gyulatanya, bejárati út"             => "Bátonyterenye, Gyulatanya bejárati út",
		"Bátonyterenye(K.terenye), bánya"                    => "Bátonyterenye(Kisterenye), bánya",
		"Bátonyterenye(K.terenye), B.telágazás"              => "Bátonyterenye(Kisterenye), bányatelepi elágazás",
		"Bátonyterenye(K.terenye) Int.bejárati út"           => "Bátonyterenye(Kisterenye) Int. bejárati út",
		"Bátonyterenye(K.terenye), ózdi útelág"              => "Bátonyterenye(Kisterenye), ózdi útelág",
		"Bátonyterenye(K.terenye), posta"                    => "Bátonyterenye(Kisterenye), posta",
		"Bátonyterenye(K.terenye), vásártér"                 => "Bátonyterenye(Kisterenye), vásártér",
		"Bátonyterenye, m. szelei elágazás"                  => "Bátonyterenye, mátraszelei elágazás",
		"Bátonyterenye(N.bátony), Bányaváros"                => "Bátonyterenye(Nagybátony), Bányaváros",
		"Bátonyterenye(N.bátony), FŰTŐBER"                   => "Bátonyterenye(Nagybátony), FŰTŐBER",
		"Bátonyterenye(N.bátony), Ózdi út 10."               => "Bátonyterenye(Nagybátony), Ózdi út 10.",
		"Bátonyterenye(N.bátony), VOLÁN tp."                 => "Bátonyterenye(Nagybátony), VOLÁN tp.",
		"Battonya, autóbusz-váróterem bejárati út"           => "Battonya, autóbusz-váróterem",
		"Bauxitkutató V. bejárati út"                        => "Bauxitkutató Vállalat bejárati út",
		"Becske, N.kövesdi elágazás"                         => "Becske, nógrádkövesdi elágazás",
		"Becsvölgye, III. ker. bejárati út"                  => "Becsvölgye, III. kerület bejárati út",
		"Becsvölgye, III. ker. F. Söröző"                    => "Becsvölgye, III. kerület F. Söröző",
		"Becsvölgye, III. ker. posta"                        => "Becsvölgye, III. kerület posta",
		"Becsvölgye, II. ker. italbolt"                      => "Becsvölgye, II. kerület italbolt",
		"Becsvölgye, I. ker. autóbusz-forduló"               => "Becsvölgye, I. kerület autóbusz-forduló",
		"Becsvölgye, Kopácsai u. 32"                         => "Becsvölgye, Kopácsai u. 32.",
		"Becsvölgye, k.szegi elágazás"                       => "Becsvölgye, kustánszegi elágazás",
		"Bedőbokor 68.sz."                                   => "Bedőbokor 68. sz.",
		"Bekecs, Táncsics M.u."                              => "Bekecs, Táncsics M. u.",
		"Békéscsaba, Bútoripari szöv."                       => "Békéscsaba, Bútoripari szövetkezet",
		"Békéscsaba, meteor u."                              => "Békéscsaba, Meteor u.",
		"Békés, temető bej."                                 => "Békés, temető bejárat",
		"Béke Tsz (54102 sz.út)"                             => "Béke Tsz (54102 sz. út)",
		"Béke Tsz (54 sz.út)"                                => "Béke Tsz (54 sz. út)",
		"Belecskapuszta, Gyerm. otthon"                      => "Belecskapuszta, Gyermekotthon",
		"Belegrád, autóbusz-fordulóduló"                     => "Belegrád, autóbusz-forduló",
		"Belsösárd, Petőfi u. 53"                            => "Belsösárd, Petőfi u. 53.",
		"Berekböszörmény, Árpád u.54"                        => "Berekböszörmény, Árpád u. 54.",
		"Berekfürdő, strandf."                               => "Berekfürdő, strandfürdő",
		"Berente, Cementipari V."                            => "Berente, Cementipari Vállalat",
		"Berente, Esze T u. 36"                              => "Berente, Esze T. u. 36.",
		"Berente, Hőerőmű gy. felüljáró"                     => "Berente, Hőerőmű gyalogos felüljáró",
		"Berettyóújfalu, gimn."                              => "Berettyóújfalu, gimnázium",
		"Berh. Lakat u."                                     => "Berhida, Lakat u.",
		"Beszterec, V.hadsereg u. 36."                       => "Beszterec, Vöröshadsereg u. 36.",
		"Bezeréd, Petőfi u. 1"                               => "Bezeréd, Petőfi u. 1.",
		"B.földvár, közp. autóbusz-váróterem"                => "Balatonföldvár, központi autóbusz-váróterem",
		"Biharkeresztes,Kossuth u.1"                         => "Biharkeresztes, Kossuth u. 1.",
		"Biharkeresztes,Kossuth u."                          => "Biharkeresztes, Kossuth u.",
		"Biharnagybajom,Kossuth u."                          => "Biharnagybajom, Kossuth u.",
		"Bihartorda,Kossuth u.103."                          => "Bihartorda, Kossuth u. 103.",
		"Birján, Kossuth u. 56"                              => "Birján, Kossuth u. 56.",
		"Boba, vasútállomás bejárati út"                     => "Boba, vasútállomás",
		"Bödeháza, Kossuth u. 11"                            => "Bödeháza, Kossuth u. 11.",
		"Böhönye, közp. autóbusz-váróterem"                  => "Böhönye, központi autóbusz-váróterem",
		"Bojt, Kossuth u.62"                                 => "Bojt, Kossuth u. 62.",
		"Boncodfölde, Kossuth u. 14"                         => "Boncodfölde, Kossuth u. 14.",
		"Bonyhád, Mátyás kir. u."                            => "Bonyhád, Mátyás király u.",
		"Borsodbóta, s.mercsei elágazás"                     => "Borsodbóta, sajómercsei elágazás",
		"Borsodnádasd, Mocsolyástelep. bejárati út"          => "Borsodnádasd, Mocsolyástelep bejárati út",
		"Borsodnádasd, Művelődési otthon"                    => "Borsodnádasd, művelődési otthon",
		"Borsodszentgyörgy, Szt.györgyi u."                  => "Borsodszentgyörgy, Szentgyörgyi u.",
		"Borszörcsök, t.szertár"                             => "Borszörcsök, tűzoltószertár",
		"Bózsva(N.Bózsva), autóbusz-váróterem"               => "Bózsva(Nagybózsva), autóbusz-váróterem",
		"B.halom, Szabadság u.45."                           => "Bodroghalom, Szabadság u. 45.",
		"B.szabadi, alsó"                                    => "Balatonszabadi, alsó",
		"B.szabadi, harangláb"                               => "Balatonszabadi, harangláb",
		"B.szabadi, Kakasdomb"                               => "Balatonszabadi, Kakasdomb",
		"B.szabadi, Kinizsi u."                               => "Balatonszabadi, Kinizsi u.",
		"B.szabadi, községháza"                              => "Balatonszabadi, községháza",
		"B.szabadi, sz.i b."                                 => "Balatonszabadi, szövetkezeti italbolt",
		"B.terenye, Jászai úti iskola"                       => "Bátonyterenye, Jászai úti iskola",
		"Bucsuszentlászló,József A. u. 4"                    => "Bucsuszentlászló, József A. u. 4.",
		"Bucsuszentlászló, N.szentandrási elágazás"          => "Bucsuszentlászló, nemesszentandrási elágazás",
		"Budaábrány, Szabadság u. 3o"                        => "Budaábrány, Szabadság u. 30.",
		"Budaábrány, Szabadság u.76"                         => "Budaábrány, Szabadság u. 76.",
		"Budapest Cérnázó Kft."                              => "Budapest, Cérnázó Kft.",
		"Budapest(Csepel), Kiss J. alt. u."                  => "Budapest(Csepel), Kiss János altábornagy utca",
		"Budapest, Kacsóh P. út"                             => "Budapest, Kacsóh Pongrác út",
		"Budapest, Kelenföldi pu."                           => "Budapest, Kelenföldi pályaudvar",
		"Budapest, R.palota, Szántóföld út"                  => "Budapest(Rákospalota), Szántóföld út",
		"Budapest (Újpest), Városkapu vasútállomás IV.ker."  => "Budapest(Újpest), Városkapu vasútállomás IV. ker.",
		"Budapest, Waldorf ált. iskola"                      => "Budapest, Waldorf általános iskola",
		"Bugaci útelágazás(5302 sz. út)"                     => "Bugaci útelágazás (5302 sz. út)",
		"Bugaci útelágazás (54 sz.út)"                       => "Bugaci útelágazás (54 sz. út)",
		"Bugyi, apaji Állami Gazdaság üz. egys."             => "Bugyi, apaji Állami Gazdaság üzemegység",
		"Bükkzsérc,József A.u.1."                            => "Bükkzsérc, József A. u. 1.",
		"Cece, vasútállomás bejárati út"                     => "Cece, vasútállomás",
		"Celldömölk, Aranykerék vend."                       => "Celldömölk, Aranykerék vendéglő",
		"Cered, Mg. Szöv."                                   => "Cered, Mezőgazdasági Szövetkezet",
		"Cibakpuszta, 58.sz."                                => "Cibakpuszta, 58. sz.",
		"Csabacsüd Alföld Tsz közp."                         => "Csabacsüd Alföld Tsz központ",
		"Csabacsüd, Alföld Tsz üe."                          => "Csabacsüd, Alföld Tsz üzemegység",
		"Csabatáj Tsz. üe."                                  => "Csabatáj Tsz üzemegység",
		"Csapi, Arany J.u.5."                                => "Csapi, Arany J. u. 5.",
		"Csaroda, het. fej. elágazás"                        => "Csaroda, hetefejércsei elágazás",
		"Csemő, 12 sz. vegyesbolt"                           => "Csemő, 12. sz. vegyesbolt",
		"Cserháthaláp, M.nándori elág"                       => "Cserháthaláp, magyarnándori elágazás",
		"Cserhátsurány, tak. szöv."                          => "Cserhátsurány, takarékszövetkezet",
		"Csernely, Fehérn. üzem bejárati út"                 => "Csernely, Fehérnemű üzem bejárati út",
		"Cserszegtomaj, II.iskola"                           => "Cserszegtomaj, II. iskola",
		"Csesztreg, Fő u. 25"                                => "Csesztreg, Fő u. 25.",
		"Csesztreg, Teleki u. 41"                            => "Csesztreg, Teleki u. 41.",
		"Csongrád, Petőfi szöv."                             => "Csongrád, Petőfi szövetkezet",
		"Csonkahegyhát, Kossuth u. 37-42"                    => "Csonkahegyhát, Kossuth u. 37-42.",
		"Csorbai ÁG, közp."                                  => "Csorbai ÁG, központ",
		"Csót, Gépjavító V."                                 => "Csót, Gépjavító Vállalat",
		"Dabas, Gyón t.szentgyörgyi elágazás"                => "Dabas, Gyón tatárszentgyörgyi elágazás",
		"Darvas, Rákóczi u.11"                               => "Darvas, Rákóczi u. 11.",
		"Debr.Bocskai Étterem/ Hajnal u.9-11"                => "Debrecen, Bocskai Étterem/ Hajnal u. 9-11",
		"Debrecen, Agrártud.Egyetem"                         => "Debrecen, Agrártudományi Egyetem",
		"Debrecen(Bánk),Tiborc u."                           => "Debrecen(Bánk), Tiborc u.",
		"Debrecen, Gönczi P .u. iskola"                      => "Debrecen, Gönczi P. u. iskola",
		"Debrecen, H.szováti elágazás4-es út"                => "Debrecen, hajdúszováti elágazás 4-es út",
		"Debrecen, Kassai u.(Árpád tér)"                     => "Debrecen, Kassai u. (Árpád tér)",
		"Debrecen, MAV Járműjav. V."                         => "Debrecen, MAV Járműjavító Vállalat",
		"Debrecen,Mikepércsi u.Erőmű"                        => "Debrecen, Mikepércsi u. Erőmű",
		"Debrecen, Orvost. Egyetem"                          => "Debrecen, Orvostudományi Egyetem",
		"Debréte, szövetkezeti bolt."                        => "Debréte, szövetkezeti bolt",
		"Dejtár, Szabadság út. 47."                          => "Dejtár, Szabadság út 47.",
		"Dinnyés tanya (5302 sz.út)"                         => "Dinnyés tanya (5302. sz. út)",
		"Döge, ref. templom"                                 => "Döge, református templom",
		"Dormánd, ÁG."                                       => "Dormándi ÁG",
		"Dorogháza, újtelepi elág"                           => "Dorogháza, újtelep",
		"Dorog, Közt. úti ABC"                               => "Dorog, Köztársaság úti ABC",
		"Dunaharaszti, Bajcsy-Zs.u."                         => "Dunaharaszti, Bajcsy-Zs. u.",
		"Dunakeszi, Szociális Foglalk."                      => "Dunakeszi, Szociális Foglalkoztató",
		"Dunavarsány, Betonútép. V."                         => "Dunavarsány, Betonútépítő Vállalat",
		"Ecser, muvelodési ház"                              => "Ecser, Művelődési ház",
		"Ecser, Steinmetz k. u."                             => "Ecser, Steinmetz kapitány u.",
		"Edelény(Finke), Mg. tp."                            => "Edelény(Finke), Mezőgazdasági telep",
		"Edelény, Szentpéteri u.6"                           => "Edelény, Szentpéteri u. 6.",
		"Edelény, Szociális Gondozó Int."                    => "Edelény, Szociális Gondozó Intézet",
		"Egercsehi, Április 4 út 79."                        => "Egercsehi, Április 4. út 79.",
		"Eger(Felnémet), fűr.telep"                          => "Eger(Felnémet), fűrésztelep",
		"Egerszalók, Ady E. út 60"                           => "Egerszalók, Ady E. út 60.",
		"Egervár, Széchenyi F. út 57"                        => "Egervár, Széchenyi F. út 57.",
		"Eger, ZF Hungária Kft. Kistályai út 2."             => "Eger, ZF Hungária",
		"Előszállás, N.kar-i út"                             => "Előszállás, Nagykarácsonyi út",
		"Emőd, Bagolyvár Cs."                                => "Emőd, Bagolyvár Csárda",
		"Encs, Béke u.1."                                    => "Encs, Béke u. 1.",
		"Encs, Fügöd Fő u.114."                              => "Encs, Fügöd Fő u. 114.",
		"Encs, Fügöd Fő u.18."                               => "Encs, Fügöd Fő u. 18.",
		"Ercsi, sz. áruház"                                  => "Ercsi, szövetkezeti áruház",
		"Érd, Érdliget Sárvíz u."                            => "Érd(Érdliget), Sárvíz u.",
		"Erdőbénye, Bethlen G. u. 2"                         => "Erdőbénye, Bethlen G. u. 2.",
		"Erdőkertes, Géza u., autóbusz-forduló"              => "Erdőkertes, Géza u. autóbusz-forduló",
		"Erdőtelek, Márkó dűlő"                              => "Erdőtelek, Kiskőrös Márkó dűlő",
		"Erdőtelek, Nyárfa u."                               => "Erdőtelek(Kiskőrös), Nyárfa u.",
		"Esztergom, Blaha L. u."                             => "Esztergom, Blaha Lujza utca",
		"Esztergom, Eperjesi strand"                         => "Esztergom, Eperjesi utcai strand",
		"Esztergom, Eperjesi út"                             => "Esztergom, Eperjesi utca 82.",
		"Esztergom, Finommech. Vállalat"                     => "Esztergom, Finommechanikai Vállalat",
		"Esztergom, Fogaskerék V."                           => "Esztergom, Fogaskerék Vendéglő",
		"Esztergom, Gárdonyi G. u."                          => "Esztergom, Gárdonyi Géza utca",
		"Esztergom, Húsipar"                                 => "Esztergom, Húsipari vállalat",
		"Esztergom, Kertv. vasútállomás bejárati út"         => "Esztergom(Kertváros), vasútállomás bejárati út",
		"Esztergom, Kőrösi L. úti isk"                       => "Esztergom, Kőrösi L. úti iskola",
		"Esztergom, Suzuki u."                               => "Esztergom, SUZUKI",
		"Esztergom, városi kirend."                          => "Esztergom, városi kirendeltség",
		"Esztergom, vaskapu"                                 => "Esztergom, Vaskapu",
		"Fábiánsebestyén, Kinizsi Tsz 3-as üe."              => "Fábiánsebestyén, Kinizsi Tsz 3-as üzemegység",
		"Farkasgyepű, TBC Gyógyint."                         => "Farkasgyepű, TBC Gyógyintézet",
		"Fehérgyarmat, Mártírok u.5."                        => "Fehérgyarmat, Mártírok u. 5.",
		"Felsőberecki, Kossuth u.97."                        => "Felsőberecki, Kossuth u. 97.",
		"Felsődobsza, Kossuth u.94."                         => "Felsődobsza, Kossuth u. 94.",
		"Felsőlajos, Almavirág Szakszöv."                    => "Felsőlajos, Almavirág Szakszövetkezet",
		"Felsőmocsolád, Tak. szöv."                          => "Felsőmocsolád, takarékszövetkezet",
		"Felsőnyárád, döv.-i elágazás"                       => "Felsőnyárád, dövényi elágazás",
		"Felsőnyék, Marx krt."                               => "Felsőnyék, Marx körút",
		"Felsővadász, Petőfi u.1."                           => "Felsővadász, Petőfi u. 1.",
		"Felsőzsolca, Kassai u.51."                          => "Felsőzsolca, Kassai u. 51.",
		"Felszabadulás Tsz II. üe."                          => "Felszabadulás Tsz II. üzemegység",
		"Fertőszéplak, szövetkezeti bolt."                   => "Fertőszéplak, szövetkezeti bolt",
		"Földm. szöv. 4. sz. bolt"                           => "Földműves szövetkezet 4. sz. bolt",
		"Fonyódliget, Víghajós Étt."                         => "Fonyódliget, Víghajós Étterem",
		"Fót, Vízmüvek"                                      => "Fót, Vízművek",
		"Fülöp, Bánházai u.4."                               => "Fülöp, Bánházai u. 4.",
		"Fülöp, Penészleki u.6."                             => "Fülöp, Penészleki u. 6.",
		"Fülöpszállás, Csősz t."                             => "Fülöpszállás, Csősz tanya",
		"Fülpösdaróc, Pécsi ép. u. 10."                      => "Fülpösdaróc, Pécsi építők útja 10.",
		"Fűzfőgyártelep, v.őrh."                             => "Fűzfőgyártelep, vasúti őrház",
		"Fűzfőgyártelep, v. sorompó"                         => "Fűzfőgyártelep, vasúti sorompó",
		"Gáborjánháza, Kossuth u. 27"                        => "Gáborjánháza, Kossuth u. 27.",
		"Gáborján, Malom u. 137"                             => "Gáborján, Malom u. 137.",
		"Gadány, Műv. Otthon"                                => "Gadány, Művelődési Otthon",
		"Gádoros, tak. szöv."                                => "Gádoros, takarékszövetkezet",
		"Galgamácsa, Művelődési Otthon"                      => "Galgamácsa, Művelődési otthon",
		"Galgamácsa, tsz.-tanya"                             => "Galgamácsa, tsz-tanya",
		"Gesztely, Petőfi u.12."                             => "Gesztely, Petőfi u. 12.",
		"Gesztely, Rákóczi u.16."                            => "Gesztely, Rákóczi u. 16.",
		"Göd, Kék Duna üd. bejárati út"                      => "Göd, Kék Duna üdülő bejárati út",
		"Gödöllő, Olt. Ell. Int."                            => "Gödöllő, Oltóanyag-ellenőrző Intézet",
		"Gödre, tsz. major"                                  => "Gödre, Tsz major",
		"Görbeháza, Csillag Mg. Szövetkezet"                 => "Görbeháza, Csillag Mezőgazdasági Szövetkezet",
		"Görcsönydoboka, S. u."                              => "Görcsönydoboka, Ságvári Endre utca",
		"Gosztola, Fő u. 2"                                  => "Gosztola, Fő u. 2.",
		"Gosztola, Polg. Hiv."                               => "Gosztola, Polgármesteri Hivatal",
		"Gutorfölde, Ady u. 35"                              => "Gutorfölde, Ady u. 35.",
		"Gutorfölde, Náprádfa Közt. tér"                     => "Gutorfölde, Náprádfa Köztársaság tér",
		"Gyenesdiás, takarékp."                              => "Gyenesdiás, Takarékpénztár",
		"Gyomaendrőd, Alkotmány Tsz."                        => "Gyomaendrőd, Alkotmány Tsz",
		"Gyomaendrőd, Alkotm. Tsz. II."                      => "Gyomaendrőd, Alkotmány Tsz II.",
		"Gyomaendrőd, Kossuth út."                           => "Gyomaendrőd, Kossuth út",
		"Gyomaendrőd, Napkeleti vend."                       => "Gyomaendrőd, Napkeleti vendéglő",
		"Gyömöre, Petőfi S. ut"                              => "Gyömöre, Petőfi S. út",
		"Gyöngyös, izr.temető"                               => "Gyöngyös, izraelita temető",
		"Gyöngyössolymos, Bartók B.u."                       => "Gyöngyössolymos, Bartók B. u.",
		"Gyöngyös, s.tenyésztő"                              => "Gyöngyös, sertéstenyésztő",
		"Gyöngyös, Szt. Bertalan templom"                    => "Gyöngyös, Szent Bertalan templom",
		"Győr, Gyárváros vasúti mh."                         => "Győr, Gyárváros vasúti megállóhely",
		"Győr, horgásztó(83. sz. út)"                        => "Győr, horgásztó (83. sz. út)",
		"Győr, Ipari Park Innonet közp."                     => "Győr, Ipari Park Innonet központ",
		"Győr(Ipari Park), Innonet közp."                    => "Győr(Ipari Park), Innonet központ",
		"Győr, Ménfőcsanak S.pátkai út"                      => "Győr, Ménfőcsanak Sokorópátkai út",
		"Győr(Ménfőcsanak), S.pátkai út"                     => "Győr(Ménfőcsanak), Sokorópátkai út",
		"Győr(Ménfőcsanak) vasúti mh."                       => "Győr(Ménfőcsanak) vasúti megállóhely",
		"Győr, Puskás T. u. Madách u."                       => "Győr, Puskás T. u., Madách u.",
		"Győr, Szt. István út Iparkamara"                    => "Győr, Szent István út, Iparkamara",
		"Győrújbarát, István kir. út"                        => "Győrújbarát, István király út",
		"Hahót, Zrinyi u. 151"                               => "Hahót, Zrinyi u. 151.",
		"Hajdúbagos, Nagy u. 45"                             => "Hajdúbagos, Nagy u. 45.",
		"Hajdúböszörmény,Béke Tsz."                          => "Hajdúböszörmény, Béke Tsz",
		"Hajdúböszörmény,Bocskai Tsz."                       => "Hajdúböszörmény, Bocskai Tsz",
		"Hajdúböszörmény, Csillag Mg. Tsz. II. Ü"            => "Hajdúböszörmény, Csillag Mg. Tsz. II. üzemegység",
		"Hajdúböszörmény, Csillag Mg. Tsz. I. Üe"            => "Hajdúböszörmény, Csillag Mg. Tsz. I. üzemegység",
		"Hajdúböszörmény, Zója Tsz."                         => "Hajdúböszörmény, Zója Tsz",
		"Hajdúdorog, Újfehértó u.54."                        => "Hajdúdorog, Újfehértó u. 54.",
		"Hajdúdorog, vasútállomás bejárati út."              => "Hajdúdorog, vasútállomás bejárati út",
		"Hajdúnánás, Bocskai u. ABC."                        => "Hajdúnánás, Bocskai u. ABC",
		"Hajdúnánás, gimn."                                  => "Hajdúnánás, gimnázium",
		"Hajdúsámson, Árpád u.26"                            => "Hajdúsámson, Árpád u. 26.",
		"Hajdúsámson, Árpád u.92"                            => "Hajdúsámson, Árpád u. 92.",
		"Hajdúsámson , Martinka Bojtorján u."                => "Hajdúsámson, Martinka Bojtorján u.",
		"Hajdúszoboszló, Ady E. u. 106"                      => "Hajdúszoboszló, Ady E. u. 106.",
		"Hajdúszoboszló, Búzakalász Tsz."                    => "Hajdúszoboszló, Búzakalász Tsz",
		"Hajdúszoboszló, Nádudvari u.1.sz."                  => "Hajdúszoboszló, Nádudvari u. 1. sz.",
		"Hajdúszoboszló, Nádudvari u.9o.sz."                 => "Hajdúszoboszló, Nádudvari u. 90. sz.",
		"Halesz, 5 sz.dűlő"                                  => "Halesz, 5 sz. dűlő",
		"Halmajugra, ÁFÉSZ 5. sz. b."                        => "Halmajugra, ÁFÉSZ 5. szövetkezeti bolt",
		"Halmajugra, ÁFÉSZ 6. sz. b."                        => "Halmajugra, ÁFÉSZ 6. szövetkezeti bolt",
		"Hámán K. Tsz. üz. egys."                            => "Hámán K. Tsz üzemegység",
		"Hejőpapi, Kossuth u.10. (autóbusz-forduló)"         => "Hejőpapi, Kossuth u. 10. (autóbusz-forduló)",
		"Hidasnémeti, takarékszöv."                          => "Hidasnémeti, takarékszövetkezet",
		"Hódmezővásárhely, Bem Tsz üe."                      => "Hódmezővásárhely, Bem Tsz üzemegység",
		"Hódmezővásárhely, Dózsa Tsz 1-es üe."               => "Hódmezővásárhely, Dózsa Tsz 1-es üzemegység",
		"Homokszentgyörgy, Műv. Otthon"                      => "Homokszentgyörgy, Művelődési Otthon",
		"Hunya, Müvelödési Otthon"                           => "Hunya, Művelődési Otthon",
		"Jánoshalma, Bácska Ip. Szöv."                       => "Jánoshalma, Bácska Ipari Szövetkezet",
		"Jászágó, Művelődési otthon"                         => "Jászágó, Művelődési Otthon",
		"Jászkarajenő, Műv. Ház"                             => "Jászkarajenő, Művelődési Ház",
		"Kálmánháza, Művelődési Ház"                         => "Kálmánháza, Művelődési ház",
		"Kamut, Tsz. üe."                                    => "Kamut, Tsz. üzemegység",
		"Katymár, Katymár Állami Gazdaság üe"                => "Katymár, Katymár Állami Gazdaság üzemegység",
		"Kemestaródfa, Művelődési otthon"                    => "Kemestaródfa, Művelődési Otthon",
		"Kenyeri, Művelődési otthon"                         => "Kenyeri, Művelődési Otthon",
		"Kisberzsenyi elágazás"                              => "Kisberényi elágazás (1)",
		"Kiskunmajsa, Cipőipari szöv."                       => "Kiskunmajsa, Cipőipari szövetkezet",
		"Kisszekeres, Művelődési ház"                        => "Kisszekeres,Művelődési ház",
		"Kisszekeres, Művelődési Ház"                        => "Kisszekeres,Művelődési ház",
		"Komló, Művelődési Ház"                              => "Komló, Művelődési ház",
		"Kondoros, Gabona Szöv."                             => "Kondoros, Gabona Szövetkezet",
		"Kunhegyes, ref. temető"                             => "Kunhegyes, református temető",
		"Kunmadaras, ruhaip. szöv."                          => "Kunmadaras, ruhaipari szövetkezet",
		"Lenin Tsz. I. üe."                                  => "Lenin Tsz. I. üzemegység",
		"Letkés, Leléthídi major"                            => "Letkés, Lelédhídi major",
		"Maglód, muvelodési ház"                             => "Maglód, Művelődési ház",
		"Magyarlak, Művelődési otthon"                       => "Magyarlak, Művelődési Otthon",
		"Magyarnándor, Tsz.-iroda"                           => "Magyarnándor, Tsz-iroda",
		"Majosháza, Művelődési Ház"                          => "Majosháza, Művelődési ház",
		"Makó, Nagycsorgó-Rákos"                             => "Makó, Nagycsorgó",
		"Makó, ref.templom"                                  => "Makó, református templom",
		"Mohora, cserh. útelágazás"                          => "Mohora, cserháthalápi útelágazás",
		"Mosonmagyaróvár, Ev.templom"                        => "Mosonmagyaróvár, Evangélikus templom",
		"Nagyecsed, ref. templom"                            => "Nagyecsed, református templom",
		"Nagykőrös, Állami Gazdaság Fekete üe."              => "Nagykőrös, Állami Gazdaság Fekete üzemegység",
		"Nagykőrös, Gépgyártó szöv."                         => "Nagykőrös, Gépgyártó szövetkezet",
		"Nemesbikk, Művelődési Ház"                          => "Nemesbikk, Művelődési ház",
		"Ököritófülpös, ref. templom"                        => "Ököritófülpös, református templom",
		"Olcsva, ref. templom"                               => "Olcsva, református templom",
		"Őrbottyán, ref. gy. otthon"                         => "Őrbottyán, református gyermekotthon",
		"Orgovány, Műv. Ház"                                 => "Orgovány, Művelődési Ház",
		"Pankotai Állami Gazdaság üe."                       => "Pankotai Állami Gazdaság üzemegység",
		"Paszab, Háziipari szöv."                            => "Paszab, Háziipari szövetkezet",
		"Pátroha, ref. templom"                              => "Pátroha, református templom",
		"Petőfiszállás, Műv. Ház"                            => "Petőfiszállás, Művelődési Ház",
		"P.monostor,műv.ház"                                 => "P.monostor, Művelődési ház",
		"Pusztaottlaka, Tökfalu Szöv. Bolt"                  => "Pusztaottlaka, Tökfalu szövetkezeti bolt",
		"Pusztaottlaka(Tökfalu), Szöv. Bolt"                 => "Pusztaottlaka(Tökfalu), szövetkezeti bolt",
		"Rábagyarmat, Művelődési otthon"                     => "Rábagyarmat, Művelődési Otthon",
		"Rákóczi Tsz. III. üe."                              => "Rákóczi Tsz. III. üzemegység",
		"Rákóczi Tsz. üe."                                   => "Rákóczi Tsz. üzemegység",
		"Salgótarján, Kohász műv. közp."                     => "Salgótarján, Kohász Művelődési Központ",
		"Sárosd, Tükröspusztai elágazás"                     => "Sárosd, Tükröspuszta Állami Gazdaság",
		"Selyeb, Művelődési Ház"                             => "Selyeb, Művelődési ház",
		"Solti Állami Gazdaság Burjáni üe."                  => "Solti Állami Gazdaság Burjáni üzemegység",
		"Szeged, Postás Művelődési Ház"                      => "Szeged, Postás Művelődési ház",
		"Szeged, Szőreg takarékszöv."                        => "Szeged, Szőreg takarékszövetkezet",
		"Szeged(Szőreg), takarékszöv."                       => "Szeged(Szőreg), takarékszövetkezet",
		"Szilsárkány, szövetkezeti vendéglo"                 => "Szilsárkány, szövetkezeti vendéglő",
		"Szőcsénypuszta, Műv. Otthon"                        => "Szőcsénypuszta, Művelődési Otthon",
		"Tabdi, Műv. Ház"                                    => "Tabdi, Művelődési Ház",
		"Tarcal, autóbusz-váróterem (Művelődési Ház)"        => "Tarcal, autóbusz-váróterem (Művelődési ház)",
		"Tatabánya, Közműv. Háza"                            => "Tatabánya, Közművelődés Háza",
		"Tatabánya, Puskin Művelődési Ház"                   => "Tatabánya, Puskin művelődési ház",
		"Tata, Háziipari szöv."                              => "Tata, Háziipari szövetkezet",
		"Teleki, Műv. Otthon"                                => "Teleki, Művelődési Otthon",
		"Tiszalúc, Művelődési Ház"                           => "Tiszalúc, Művelődési ház",
		"Tiszaújváros, VOLÁN Üe."                            => "Tiszaújváros, VOLÁN üzemegység",
		"Tököl, Művelődési Ház"                              => "Tököl, Művelődési ház",
		"Tomajmonostora, Művelődési Ház"                     => "Tomajmonostora, Művelődési ház",
		"Tompa, Műv.Ház"                                     => "Tompa, Művelődési Ház",
		"Üllés, Haladás Tsz III. üe."                        => "Üllés, Haladás Tsz III. üzemegység",
		"Üllés, Haladás Tsz II. üe."                         => "Üllés, Haladás Tsz II. üzemegység",
		"Vaja, MŰV. ház"                                     => "Vaja, Művelődési ház",
		"Vasszilvágy, gépjav."                               => "Vasszilvágy, gépjavító",
		"ZEISS, Művek"                                       => "ZEISS Művek",
#>>>
	};

	$_ = $map->{$_} if exists $map->{$_};

	return $_;
}

# Converts to "local" name
sub expand_name
{
	$_ = normalize_name(shift);

#<<<
	state $map = {

		# VE -> Volánbusz
		'Bajna, Csapási híd'                       => 'Csapási híd',

		'Biatorbágy, Torbágyi téglagyár'           => 'Torbágyi téglagyár',

		'Bicske, Műszaki Áruház'                   => 'Bicske, műszaki áruház',
		'Bicske, vasútállomás bejárati út'         => 'Bicske, benzinkút',
		
		'Budakeszi, Farkashegyi repülőtér'         => 'Farkashegyi repülőtér',
		'Budakeszi, Hidegvölgyi erdészlak'         => 'Hidegvölgyi erdészlak',
		'Budakeszi, Kossuth Lajos utca'            => 'Budakeszi, Gyógyszertár',
		'Budakeszi, munkásszállás'                 => 'Budakeszi, Harmatfű utca',
		'Budakeszi, szőlőtelep'                    => 'Budakeszi-Szőlőtelep',

		'Budaörs, Hidépitő Vállalat'               => 'Budaörs, Hídépítő Vállalat',

		'Budapest, Barostelep vasútállomás'        => 'Budapest, Barosstelep vasútállomás',
		'Budapest, Bécsi út'                       => 'Budapest, Bécsi út (Vörösvári út)',
		'Budapest, Bécsi úti temető'               => 'Budapest, Óbudai temető',
		'Budapest, Borszéki út'                    => 'Budapest, Borszéki utca',
		'Budapest, Csepel 8553. utca'              => 'Budapest, Almafa utca',
		'Budapest, Csepel 8654. utca'              => 'Budapest, Szilvafa utca',
		'Budapest, Csepel Csárda'                  => 'Budapest, Hárosi csárda',
		'Budapest, Csepel Csillag telep'           => 'Budapest, Tejút utca',
		'Budapest, Csepel Erdősor utca'            => 'Budapest, Erdősor utca',
		'Budapest, Csepel Hárosi iskola'           => 'Budapest, Hárosi iskola',
		'Budapest, Csepel Háros'                   => 'Lakihegy, áruházi bekötőút',
		'Budapest, Csepel HÉV állomás'             => 'Budapest, Csepel HÉV-állomás',
		'Budapest, Csepel Karácsony S. utca'       => 'Budapest, Karácsony Sándor utca',
		'Budapest, Csepel Koltói A. utca'          => 'Budapest, Koltói Anna utca',
		'Budapest, Csepel temető'                  => 'Budapest, Csepeli temető',
		'Budapest, Csepel Vas Gereben utca'        => 'Budapest, Vas Gereben utca',
		'Budapest, Csepel Vízművek'                => 'Budapest, Vízművek lakótelep',
		'Budapest, Diósdi út'                      => 'Budapest, Diósdi utca',
		'Budapest, János kórház'                   => 'Budapest, Szent János kórház',
		'Budapest, Kelenföld BKV. garázs'          => 'Budapest, Kelenföld BKV Garázs',
		'Budapest, Kelenföldi pu.'                 => 'Budapest, Kelenföldi pályaudvar',
		'Budapest, Keserűvízforrás'                => 'Budapest, Keserűvíz forrás',
		'Budapest, Korányi Szanatórium'            => 'Budapest, Orsz. Korányi tbc Intézet',
		'Budapest, Óbudai rendelöintézet'          => 'Budapest, Óbudai rendelőintézet',
		'Budapest, Szoborpark Múzeum'              => 'Budapest, Memento Park',
		'Budapest, Tündérkert'                     => 'Budapest, Szépjuhászné',
		'Budapest, Újpest Városkapu vasútállomás XIII. ker.'
		                                           => 'Budapest, Újpest Városkapu vasútállomás XIII. kerület',

		'Csobánka, Csikóváraljai menedékház'       => 'Csikóváraljai menedékház',
		'Csobánka, Csobánkai elágazás'             => 'Csobánkai elágazás',

		'Dorog, IBUSZ'                             => 'Dorog, IBUSZ iroda',

		'Érd(Érdliget), Sárvíz u.'                 => 'Érd, Sárvíz utca',

		'Etyek, falatozó'                          => 'Etyek, italbolt',
		'Etyek, Háromrózsa-tanya'                  => 'Háromrózsa-tanya',

		'Gyarmatpuszta, elágazás'                  => 'Gyarmatpusztai elágazás',

		'Gyermely, Semelweis út'                   => 'Gyermely, Semmelweis utca',
		'Gyermely, tésztagyár'                     => 'Gyermelyi tésztagyár',

		'Kabláspuszta, bej út.'                    => 'Kabláspuszta bejárati út',

		'Kesztölc, autóbusz forduló'               => 'Kesztölc, autóbusz-forduló',
		'Kesztölc elágazás'                        => 'Kesztölci elágazás',
		'Kesztölc, Jószerencsét Takarékszövetkezet'=> 'Jószerencsét Takarékszövetkezet',

		'Mány, Alsóőrspuszta, bejárati út'         => 'Alsóörspuszta bejárati út',

		'Páty, Herceghalmi Állami Gazdaság ü.e.'   => 'Újmajor',

		'Perbál, szövetkezeti vendéglő'            => 'Perbál, Központ',
		'Perbál, Takarékszövetkezet tároló'        => 'Perbál, Gombás üzem',
		'Perbál, Takarékszövetkezet Újmajor'       => 'Tök, Körtvélyes',

		'Piliscsaba, Garancsi tó'                  => 'Garancsi tó',

		'Piliscsév, piliscsévi elágazás'           => 'Piliscsév, elágazás',

		'Pilisszentiván, autóbusz forduló'         => 'Pilisszentiván, autóbusz-forduló',

		'Pilismarót, szobi rév elágazás'           => 'Szobi rév elágazás',

		'Pilisszentkereszt, autóbusz forduló'      => 'Pilisszentkereszt, autóbusz-forduló',
		'Pilisszentkereszt, Dobogókő hegytető'     => 'Dobogókő, hegytető',
		'Pilisszentkereszt, Dobogókő Kétbükkfan'   => 'Dobogókő, Kétbükkfanyereg',
		'Pilisszentkereszt, Dobogókő MANRÉZA'      => 'Dobogókő, MANRÉZA',
		'Pilisszentkereszt, Dobogókő Pilis üdül'   => 'Dobogókő, Pilis üdülő',
		'Pilisszentkereszt, Gyógyáruértékesítő'    => 'Gyógyáruértékesítő Vállalat',
		'Pilisszentkereszt, Kakashegyi erdészhá'   => 'Kakashegyi erdészházak',
		'Pilisszentkereszt, Nagykovácsi puszta'    => 'Nagykovácsi puszta',

		'Pilisvörösvár, 10 sz. út, útőrház'        => 'Pilisvörösvár, 10-es sz. út, útőrház',
		'Pilisvörösvár, Fő út 31.'                 => 'Pilisvörösvár, Fő út 31.',
		'Pilisvörösvár, Szt. Erzsébet Otthon'      => 'Pilisvörösvár, Szent Erzsébet Otthon',
		'Pilisvörösvár, üdülőtelep'                => 'Pilisvörösvári üdülőtelep',

		'Pócsmegyer, Surány Galamb utca'           => 'Surány, Galamb utca',
		'Pócsmegyer, Surány Napsugár tér'          => 'Surány, Napsugár tér',
		'Pócsmegyer, Surány Rózsa utca 15.'        => 'Surány, Rózsa utca 15.',
		'Pócsmegyer, Surány Rózsa utca 41.'        => 'Surány, Rózsa utca 41.',

		'Pomáz, Bajcsy Zs. utca 41.'               => 'Pomáz, Bajcsy Zsilinszky utca 41.',
		'Pomáz, Bajcsy Zs. utca 5.'                => 'Pomáz, Bajcsy Zsilinszky utca 5.',
		'Pomáz, Kiskovácsi Kórház'                 => 'Kiskovácsi, Kórház',
		'Pomáz, Kiskovácsi puszta'                 => 'Kiskovácsi puszta',
		'Pomáz, Pankos-tető'                       => 'Pankos-tető',

		'Solymár, AUCHAN Pilis áruház'             => 'Solymár, AUCHAN áruház',
		'Solymár, PEVDI 6.sz. gyáre.'              => 'Solymár, PEVDI 6. sz. gyáregység',
		'Solymár, Solymári elágazás'               => 'Solymári elágazás (Auchan áruház)',
		'Solymár, Solymári kőfaragó'               => 'Solymári kőfaragó',
		'Solymár, Solymári téglagyár bejárati út'  => 'Solymár, téglagyári bekötőút',

		'Sóskút, Öreghegy Széles utca'             => 'Sóskút-Öreghegy, Széles utca',

		'Százhalombatta, Bentapuszta'              => 'Bentapuszta',
		'Százhalombatta, De-Rt. 2 sz. kapu'        => 'Százhalombatta, DE-Zrt. 2 sz. kapu',
		'Százhalombatta, DE-Rt. 4.sz. kapu'        => 'Százhalombatta, DE-Zrt. 4 sz. kapu',
		'Százhalombatta, DE-Rt. 4.sz.kapu'         => 'Százhalombatta, DE-Zrt. 4 sz. kapu',
		'Százhalombatta, DE-Rt. főkapu'            => 'Százhalombatta, DE-Zrt. főkapu',
		'Százhalombatta, DE-Zrt. 2. sz. kapu'      => 'Százhalombatta, DE-Zrt. 2 sz. kapu',

		'Szentendre, Dömörkapu autóbusz forduló'   => 'Dömörkapu, autóbusz forduló',
		'Szentendre, Dömörkapu lakótelep'          => 'Dömörkapu, lakótelep',
		'Szentendre, Dömörkapu tábor'              => 'Dömörkapu, tábor',
		'Szentendre, Dömörkapu tölgyes'            => 'Dömörkapu, tölgyes',

		'Szomor, Kakukk-hegy'                      => 'Szomor, Kakukkhegy',
		'Szomor, Mátyás kir. utca'                 => 'Szomor, Mátyás király utca',
		'Szomor, autóbusz-váróterem'               => 'Szomor, autóbusz váróterem',

		'Tahitótfalu, Nagyárok'                    => 'Tahitótfalu-Nagyárok',
		'Tahitótfalu, Pokolcsárda'                 => 'Tahitótfalu-Pokolcsárda',
		'Tahitótfalu, Tahitótfalui üdülőtelep'
		                                           => 'Tahitótfalu, üdülőtelep',
		'Tahitótfalu, Váci rév'                    => 'Tahitótfalu-Váci rév',

		'Tárnok, Márton utca'                      => 'Tárnok, Marton utca',
		'Tárnok, Rákóczi Ferenc út'                => 'Tárnok, Rákóczi Ferenc utca',
		'Tárnok, tárnoki elágazás'                 => 'Tárnoki elágazás',
		'Tárnok, tárnoki horgászsétány'            => 'Tárnoki horgászsétány',

		'Tinnye, Berekerdei erdészház bejárati út' => 'Berekerdei erdészház, bejárati út',

		'Telki, Pátyi elágazás'                    => 'Pátyi elágazás',

		'Tök, Anyácsapuszta'                       => 'Anyácsapuszta',

		'Törökbálint, Baross utca'                 => 'Törökbálint, Baross Gábor utca',

		'Üröm, Pilisborosjenői elágazás'           => 'Pilisborosjenői elágazás',
		'Üröm, Ürömi mészégető'                    => 'Ürömi mészégető',

		'Visegrád, Szentgyörgypuszta'              => 'Visegrád-Szentgyörgypuszta',

		'Zsámbék, Szomori elágazás'                => 'Szomori elágazás',

		# Ugh...
		'Százhalombatta, Óvoda'                    => 'Százhalombatta, óvoda',
		'Páty, újtelep'                            => 'Páty, Újtelep',
		'Telki, üdülőtelep'                        => 'Telki, Üdülőtelep',
		'Telki, újtelep'                           => 'Telki, Újtelep',

	};
#>>>
	return $map->{$_} if exists $map->{$_};

	# sub-names
	s/^([^,]+?)\s*\(([^,)]+)\),/$1, $2/go;

	# utca
	s/\bu\.(?=\w)/utca /go;
	s/\bu\.(?=\W|\z)/utca/go;

	# sétány
	s/\bst\.(?=\w)/sétány /go;
	s/\bst\.(?=\W|\z)/sétány/go;

	# körut
	s/\bkrt\.(?=\w)/körút /go;
	s/\bkrt\.(?=\W)/körút/go;

	# takarékszövetkezet
	s/\bTsz.?(?=\w)/Takarékszövetkezet /go;
	s/\bTsz.?(?=\W|\z)/Takarékszövetkezet/go;
	s/\bTSZ(?=\W|\z)/Takarékszövetkezet/go;

	# telep
	s/\btp\.(?: |\z)/telep/go;

	# autóbusz-forduló, autóbusz-állomás,
	s/\bautóbusz-forduló(?:\z|\b)/autóbusz forduló/go;
	s/\bautóbusz-állomás(?:\z|\b)/autóbusz állomás/go;

	# nevek
	state $abbrev = [
#<<<
		map {
			[ qr/\b\Q$_->[0]\E(?=\w)/, $_->[1] ],
			[ qr/\b\Q$_->[0]\E/, $_->[1] ]
		}

		[ 'Ady E.',         'Ady Endre'         ],
		[ 'Alszeghy K.',    'Alszeghy Kálmán'   ],
		[ 'Arany J.',       'Arany János'       ],
		[ 'Bajcsy-Zs.',     'Bajcsy-Zsilinszky' ],
		[ 'Deák F.',        'Deák Ferenc'       ],
		[ 'Dózsa Gy.',      'Dózsa György'      ],
		[ 'Erkel F.',       'Erkel Ferenc'      ],
		[ 'Esze T.',        'Esze Tamás'        ],
		[ 'Kodály Z.',      'Kodály Zoltán'     ],
		[ 'Kossuth L.',     'Kossuth Lajos'     ],
		[ 'Kölcsey F.',     'Kölcsey Ferenc'    ],
		[ 'Irinyi J.',      'Irinyi János'      ],
		[ 'Jókai M.',       'Jókai Mór'         ],
		[ 'Hága L.',        'Hága László'       ],
		[ 'Heltai J.',      'Heltai Jenő'       ],
		[ 'Móricz Zs.',     'Móricz Zsigmond'   ],
		[ 'Munkácsy M.',    'Munkácsy Mihály'   ],
		[ 'Nagy L.',        'Nagy Lajos'        ],
		[ 'Orbán B.',       'Orbán Balázs'      ],
		[ 'Pázmány P.',     'Pázmány Péter'     ],
		[ 'Petőfi S.',      'Petőfi Sándor'     ],
		[ 'Radnóti M.',     'Radnóti Miklós'    ],
		[ 'Rákóczi F.',     'Rákóczi Ferenc'    ],
		[ 'Somogyi B.',     'Somogyi Béla'      ],
		[ 'Szab.',          'Szabadság'         ],
		[ 'Szily K.',       'Szily Kálmán'      ],
		[ 'Táncsics M.',    'Táncsics Mihály'   ],
#>>>
	];

	foreach my $a (@$abbrev) {
		s/$a->[0]/$a->[1]/g;
	}

=pod

	s/(?<=\d\.)sz\. ?bolt\b/ szövetkezeti bolt/go;
	s/(?<=\W)sz\. ?bolt\b\.?/szövetkezeti bolt/go;
	s/(?<=\W)Szöv\. ?bolt\b\.?/szövetkezeti bolt/go;
	s/(?<=\W)sz\. ?áruház\b/szövetkezeti áruház/go;
	s/(?<=\W)bolt\./bolt/go;
	s/(?<=\W)földmuves\b/földműves/go;

	s/(?<=\W)űe\b\.?/üzemegység/go;
	s/(?<=\W)üz\. ?egys\b\.?/üzemegység/go;
	s/(?<=\W)tp\b\.?/telep/go;

	s/(?<=\W)műv\. ?ház/Művelődési Ház/go;
	s/(?<=\W)műv\. közp\b\.?/Művelődési Központ/go;
	s/(?<=\W)Műv\. Ház/Művelődési Ház/go;
	s/(?<=\W)Műv\. Otthon/Művelődési Otthon/go;
	s/(?<=\W)Művelődési ház\b/Művelődési Ház/go;

	s/(?<=\W)ÁG\b\.?/Állami Gazdaság/go;
	s/(?<=\W)Mg\b\.?(?=\w)/Mezőgazdasági /go;
	s/(?<=\W)Mg\b\.?/Mezőgazdasági/go;

	s/(?<=\W)gépcsop\b\.?/gépcsoport/go;

	s/(?<=\W)szöv\b\.?/szövetkezet/go;
	s/(?<=\W)Szöv\b\.?/Szövetkezet/go;

	s/(?<=\W)bej\./bejárat/go;
	s/(?<=\W)közp\./központ/go;
	s/(?<=\W)átj\./átjáró/go;

	s/(?<=\W)v\. őrház\b/vasúit őrház/go;
	s/(?<=\W)pu\./pályaudvar/go;

=cut

	return $map->{$_} if exists $map->{$_};

	return $_;
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

__DATA__

		'Pilisborosjenő, téglagyár'                => 'Pilisborosjenő, téglagyár',
		'Pilisborosjenő, Újtelep'                  => 'Pilisborosjenő, Újtelep',

