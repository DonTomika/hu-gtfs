
=head1 NAME

HuGTFS::FeedManager::Volan::Volanbusz - HuGTFS feed manager for download + parsing Volánbusz data

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Volan::Volanbusz;

=head1 DESCRIPTION

Downloads & parses Volánbusz timetables.

=head1 METHODS

=cut

package HuGTFS::FeedManager::Volan::Volanbusz;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Text::CSV::Encoded;
use Data::Dumper;
use DateTime;

use File::Spec::Functions qw/catfile/;
use Encode;
use Digest::JHash qw(jhash);
use YAML     ();
use YAML::XS ();
use HuGTFS::Cal;
use XML::Twig;

use HuGTFS::Util qw(:utils);
use HuGTFS::Crawler;
use HuGTFS::OSMMerger;
use HuGTFS::Dumper;

use Mouse;

with 'HuGTFS::FeedManager';
__PACKAGE__->meta->make_immutable;

no Mouse;

use constant {
	CAL_START    => HuGTFS::Cal::CAL_START,
	CAL_END      => HuGTFS::Cal::CAL_END,
	CAL_SUMMER   => HuGTFS::Cal::CAL_TANSZUNET_NYAR,
};

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 download

Downloads timetables.

Global letter list:
	http://www.volanbusz.hu/hu/menetrend/helykozi

Then letters:
	http://www.volanbusz.hu/hu/menetrend/helykozi/A

Routes: 
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&dir=to&type=helykozi

Services:
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=34&type=helykozi&dir=to
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=34&type=helykozi&dir=from

Timetables:
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=34&type=helykozi&dir=to
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=34&type=helykozi&dir=from
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=35&type=helykozi&dir=to
	http://www.volanbusz.hu/menetrend.php?menetrend=1069&menetrend_id=35&type=helykozi&dir=from

=cut

sub download
{
	my $self = shift;

	return HuGTFS::Crawler->crawl(
		[ 'http://www.volanbusz.hu/hu/menetrend/helykozi', 'http://www.volanbusz.hu//hu/belfoldiutazas/menetrend/helyi','http://www.volanbusz.hu//hu/belfoldiutazas/menetrend/naptar', ],
		$self->data_directory, \&crawl_letters, \&cleanup,
		{ sleep => 0, name_file => \&name_files, },
	);
}

=head3 cleanup

Cleans up the returned html, removing commonly changing parts that don't affect the timetables.

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;

	$content =~ s/^\s*//;

	$content =~ s{charset=windows-1250}{charset=UTF-8};
	$content =~ s/\x{a0}/ /g;
	$content =~ s/&nbsp;/ /g;
	$content =~ s/volanbusz\.css\?\d{8}/volanbusz.css/go;

	$content =~ s{<div class="hir(?: top)?">.*?\n                    </div>\n}{}gosm;

	$content =~ s{<div class="header_date">\d+-\d+-\d+</div>}{};
	$content
		=~ s{<div id="aleft">.*?<div id="amain_wide">}{<div id="amain_wide" style="margin-left: auto; margin-right: auto; float: none;">}gs;
	$content =~ s{/design/menetrend_ikon/}{http://www.volanbusz.hu/design/menetrend_ikon/}go;

	$content =~ s{href="/hu/belfoldiutazas/menetrend/naptar"}{href="naptar.html"}go;

	# This takes alot of time...
	$content
		=~ s{(['"])(?:['"]*?)menetrend\.php\?menetrend=(\d+?)&amp;menetrend_id=(\d+?)&amp;type=helykozi&amp;dir=(to|from)\1}{$1route_$2_$4_$3.html$1}go;
	$content
		=~ s{(['"])(?:['"]*?)menetrend\.php\?menetrend=(\d+?)&amp;menetrend_id=(\d+?)&amp;type=helykozi\1}{$1route_$2_XX_$3.html$1}go;
	$content
		=~ s{(['"])(?:['"]*?)menetrend\.php\?menetrend=(\d+?)&amp;dir=(to|from)&amp;type=helykozi\1}{$1route_$2_$3.html$1}go;
	$content =~ s{(["'])(?:['"]*?)menetrend/helykozi/(['"]+?)\1}{$1char_$2.html$1}go;

	$content =~ s{(href=['"])menetrendprint\.php}{$1http://www.volanbusz.hu/menetrendprint.php}go;

	return $content;
}

=head3 crawl_services

=cut

sub crawl_services
{
	my ( $content, $mech, $url ) = @_;

	return (
		[
			$mech->find_all_links(
				url_abs_regex => qr{^http://www\.volanbusz\.hu/menetrend\.php\?}
			)
		],
		undef, undef,
		\&cleanup,
	);
}

=head3 crawl_routes

=cut

sub crawl_routes
{
	my ( $content, $mech, $url ) = @_;

	return (
		[
			$mech->find_all_links(
				url_abs_regex => qr{^http://www\.volanbusz\.hu/menetrend\.php\?}
			)
		],
		undef,
		\&crawl_services,
		\&cleanup,
	);
}

=head3 crawl_letters

=cut

sub crawl_letters
{
	my ( $content, $mech, $url ) = @_;

	if($url =~ m/belfoldi/) {
		return (
			[
				$mech->find_all_links(
					url_abs_regex => qr{^http://www\.volanbusz\.hu/menetrend\.php\?}
				)
			],
			undef,
			\&crawl_services,
			\&cleanup,
		);
	}

	return (
		[
			$mech->find_all_links(
				url_abs_regex => qr{^http://www\.volanbusz\.hu/hu/menetrend/helykozi/(?:.+)$}
			),
		],
		undef,
		\&crawl_routes,
		\&cleanup,
	);
}

=head3 name_files

=cut

sub name_files
{
	my ( $url, $file ) = shift;

	if ( $url =~ m{naptar$} ) {
		return "naptar.html";
	}

	if ( $url =~ m{menetrend/helykozi/(.+)$} ) {
		return "char_$1.html";
	}

	if ( $url =~ m{menetrend\.php\?menetrend=(.+?)&menetrend_id=(.+?)&type=helykozi$} ) {
		return "route_$1_XX_$2.html";
	}

	if ( $url =~ m{menetrend=(.+?)&menetrend_id=(.+?)&type=helykozi&dir=(to|from)$} ) {
		return "route_$1_$3_$2.html";
	}

	if ( $url =~ m{menetrend=(.+?)&dir=(to|from)} ) {
		return "route_$1_$2.html";
	}

	if ( $url =~ m{helykozi$} ) {
		return "list_chars.html";
	}

	return undef;
}

=head2 parse

Parses timetables.

=cut

our $twig = XML::Twig->new(
	discard_spaces => 1,
	twig_roots     => {
		'table[@id="menetrend_header"]' => 1,
		'table[@id="menetrend"]'        => 1,
		'table[@class="menetrend"]'     => 1,

		# JEL MAGYARAZATT
	}
);

my $SERVICE_MAP = {};
my ( $TRIPS, $STOPS, $ROUTES, $AGENCY ) = ( [], {}, {}, {}, );    # volan route -> trip id -> {}
my ($dump_timetables) = (0);
my ( %services, %restrictions, %valid );

$AGENCY = {
	'agency_id'       => 'VOLANBUSZ',
	'agency_phone'    => '+36 (1) 371 94 49',
	'agency_lang'     => 'hu',
	'agency_name'     => 'Volánbusz Zrt.',
	'agency_url'      => 'http://www.volanbusz.hu',
	'agency_timezone' => 'Europe/Budapest',
};

#<<<
my $local_zones = {
	'Dunakeszi'   => 'DUNAKESZI',
	'Érd'         => 'ÉRD',
	'Gödöllő'     => 'GÖDÖLLŐ',
	'Szentendre'  => 'SZENTENDRE',
	'Törökbálint' => 'TÖRÖKBÁLINT',
	'Vác'         => 'VÁC',
};


my $local_routes = {
	map {
		my $n = $_->[1];
		map {$_ => $n } @{$_->[0]}
	} 
	[[qw/300 301 302 303 305 306 308 309 310 311 325 327 370 371 372 373/] => 'Dunakeszi'],
	[[qw/700 701 710 711 712 713 713 715 720 722 723 731 732 734 734 735 736 737 741 742 744 745 746/] => 'Érd'],
	[[qw/3301 3302 3304 3324 3314 3305 3344 3306 3308 3309 3310 3311/] => 'Gödöllő'],
	[[qw/869 870 872 873 874 876 877 878 879 880 881 882 883 884 885 886 887 888 889 890 893 894 895 898/] => 'Szentendre'],
	[[qw/755/] => 'Törökbálint'],
	[[qw/360 361 362 363 364 365 366/] => 'Vác'],
};
#>>>
my @replace = (
		#<<<

		# Common
		[ qr/\butca\b/                          =>
			sub {$_[0] =~ m/^(.+)\butca(|(?:.+)?)$/; "$1u.$2"}],
		[ qr/\bsétány\b/                          =>
			sub {$_[0] =~ m/^(.+)\bsétány(|(?:.+)?)$/; "$1st.$2"}],


		[ qr/\bszövetkezeti vendéglő\b/                      =>
			sub {$_[0] =~ m/^(.+)\bszövetkezeti vendéglő(|(?:.+)?)$/; ("$1sz. vend.$2", "$1sz.vend.$2")}],
		[ qr/\bszövetkezeti italbolt\b/                      =>
			sub {$_[0] =~ m/^(.+)\bszövetkezeti italbolt(|(?:.+)?)$/; ("$1sz. ib.$2", "$1sz.ib.$2")}],
		[ qr/\bszövetkezeti bolt\b/                      =>
			sub {$_[0] =~ m/^(.+)\bszövetkezeti bolt(|(?:.+)?)$/; ("$1sz. bolt$2", "$1sz.bolt.$2")}],
		[ qr/\btakarékszövetkezet\b/                      =>
			sub {$_[0] =~ m/^(.+)\btakarékszövetkezet(|(?:.+)?)$/; ("$1tsz.$2")}],
		[ qr/\bországhatár\b/                      =>
			sub {$_[0] =~ m/^(.+)\bországhatár(|(?:.+)?)$/; "$1oh.$2"}],
		[ qr/\bhajóállomás\b/                      =>
			sub {$_[0] =~ m/^(.+)\bhajóállomás(|(?:.+)?)$/; "$1há.$2"}],
		[ qr/\bbejárati út\b/                      =>
			sub {$_[0] =~ m/^(.+)\bbejárati út(|(?:.+)?)$/; ("$1bej. út$2", "$1bej.út$2")}],
		[ qr/\belágazás\b/                      =>
			sub {$_[0] =~ m/^(.+)\belágazás(|(?:.+)?)$/; "$1elág.$2"}],
		[ qr/\bútelágazás\b/                      =>
			sub {$_[0] =~ m/^(.+)\bútelágazás(|(?:.+)?)$/; "$1útelág.$2"}],
		[ qr/\bvasúti átjáró\b/                  =>
			sub {$_[0] =~ m/^(.+)\bvasúti átjáró(|(?:.+)?)$/; ("$1v. átj.$2", "$1v.átj.$2")}],
		[ qr/\bvasúti megállóhely\b/                  =>
			sub {$_[0] =~ m/^(.+)\bvasúti megállóhely(|(?:.+)?)$/; ("$1v. mh.$2", "$1v.mh.$2")}],
		[ qr/\bvasútállomás\b/                  =>
			sub {$_[0] =~ m/^(.+)\bvasútállomás(|(?:.+)?)$/; "$1vá.$2"}],
		[ qr/\bpályaudvar\b/                  =>
			sub {$_[0] =~ m/^(.+)\bpályaudvar(|(?:.+)?)$/; "$1pu.$2"}],
		[ qr/\blakótelep\b/                     =>
			sub {$_[0] =~ m/^(.+)\blakótelep(|(?:.+)?)$/; "$1ltp.$2"}],
		[ qr/\bautóbusz[- ]?állomás\b/              =>
			sub {$_[0] =~ m/^(.+)\bautóbusz[- ]?állomás(|(?:.+)?)$/; ("$1aut. áll.$2", "$1aut.áll.$2" )}],
		[ qr/\bautóbusz[- ]?váróterem\b/              =>
			sub {$_[0] =~ m/^(.+)\bautóbusz[- ]?váróterem(|(?:.+)?)$/; ("$1aut. vt.$2", "$1aut.vt.$2")}],
		[ qr/\bautóbusz[- ]?forduló\b/              =>
			sub {$_[0] =~ m/^(.+)\bautóbusz[- ]?forduló(|(?:.+)?)$/; ("$1aut. ford.$2", "$1aut.ford.$2")}],
		[ qr/\bautóbusz[- ]?forduló\b/              =>
			sub {$_[0] =~ m/^(.+)\bautóbusz[- ]?forduló(|(?:.+)?)$/; ("$1aut. ford.$2", "$1aut.ford.$2")}],
		[ qr/\bvárosháza\b/                     =>
			sub {$_[0] =~ m/^(.+)\bvárosháza(|(?:.+)?)$/; "$1vh.$2"}],
		[ qr/\bközségháza\b/                    =>
			sub {$_[0] =~ m/^(.+)\bközségháza(|(?:.+)?)$/; "$1kh.$2"}],
		[ qr/\biskola\b/                      =>
			sub {$_[0] =~ m/^(.+)\biskola(|(?:.+)?)$/; "$1isk.$2"}],
		[ qr/\báltalános\b/                      =>
			sub {$_[0] =~ m/^(.+)\báltalános(|(?:.+)?)$/; "$1ált.$2"}],
		[ qr/\borvosi rendelő\b/                      =>
			sub {$_[0] =~ m/^(.+)\borvosi rendelő(|(?:.+)?)$/; "$1orvosi rend.$2"}],
		[ qr/\bÁllami Gazdaság\b/                      =>
			sub {$_[0] =~ m/^(.+)\bÁllami Gazdaság(|(?:.+)?)$/; "$1Ág.$2"}],

		# Városnevek
		[ qr/\bBudapest\b/                    =>
			sub {$_[0] =~ m/^(.*)\bBudapest(|(?:.+)?)$/; ("$1Bp.$2", "$1Bp$2")}],

		# Special
		[ qr/\bszigetmonostori rév\b/                    =>
			sub {$_[0] =~ m/^(.*)\bszigetmonostori rév(|(?:.+)?)$/; "$1sz.monostori rév$2", "$1sz.monostori r.$2"}],
		[ qr/\bPázmány Péter\b/                    =>
			sub {$_[0] =~ m/^(.*)\bPázmány Péter(|(?:.+)?)$/; "$1Pázmány P.$2"}],
		[ qr/\bebszőnybányai elágazás\b/                    =>
			sub {$_[0] =~ m/^(.*)\bebszőnybányai elágazás(|(?:.+)?)$/; "$1Ebszőnyb. elág$2"}],
		[ qr/\bVállalat\b/                    =>
			sub {$_[0] =~ m/^(.*)\bVállalat(|(?:.+)?)$/; "$1Váll.$2"}],
		[ qr/\bgyáregység\b/                    =>
			sub {$_[0] =~ m/^(.*)\bgyáregység(|(?:.+)?)$/; "$1gyáre.$2"}],

		# Rövidítések
		[ qr/.+\bkirály\b/ =>
			sub {$_[0] =~ m/^(.+)\bkirály(|(?:.+)?)$/; "$1kir.$2"}],
		[ qr/.+\bSzent\b/ =>
			sub {$_[0] =~ m/^(.+)\bSzent(|(?:.+)?)$/; "$1Szt.$2"}],
		[ qr/.+\b(?:Zs|Sz|Ny|Gy|Ly)[[:word:]]+/ =>
			sub {$_[0] =~ m/^(.+)\b(Zs|Sz|Ny|Gy|Ly)[[:word:]]+\b(|(?:.+)?)$/; ("$1$2.$3", "$1$2$3")}],
		[ qr/.+\b[[:upper:]][[:word:]]+/        =>
			sub {$_[0] =~ m/^(.+)\b([[:upper:]])[[:word:]]+\b(|(?:.+)?)$/; ("$1$2.$3", "$1$2$3")}],
		#>>>
);

sub rat_name
{
	local $ENV{LC_CTYPE} = 'hu_HU.UTF-8';
	use locale;

	my $name = shift;
	return "" unless $name;

	Encode::_utf8_on($name);

	my @pos = ($name);
	foreach my $r (@replace) {
		for (@pos) {
			push( @pos, $r->[1]($_) )
				if $_ =~ $r->[0];
		}
	}
	$name = join '|', ( map { quotemeta($_) } @pos );

	return $name;
}

sub stop_is_match
{
	my ( $stop_osm, $stop_gtfs, $trip, $route, $data ) = @_;
	my ( $name, $alt_name, $old_name, $alt_old_name ) = (
		rat_name( $stop_osm->{stop_name} ),
		rat_name( $stop_osm->{alt_name}     || 'NOBODY' ),
		rat_name( $stop_osm->{old_name}     || 'NOBODY' ),
		rat_name( $stop_osm->{alt_old_name} || 'NOBODY' )
	);

	return $stop_gtfs->{stop_name} =~ m/^(?:$name|$alt_name|$old_name|$alt_old_name)$/i;
}

sub create_stop
{
	my ( $stop_osm, $stop_gtfs, $trip, $route, $data ) = @_;
	my ($stop_id) = $stop_osm->{stop_id};

	my $zones = join ',', sort map { s/\s//g; $_ } split /,/,
		( $stop_gtfs->{zone_id} || '' );

	if ( !$data->{stops}->{$stop_id} ) {
		$data->{stops}->{$stop_id} = {
			%{ $data->{osm}->{stops}->{$stop_id} },
			stop_code     => undef,
			stop_id       => $stop_id,
			stop_name     => $stop_gtfs->{stop_name},
			stop_lat      => $stop_osm->{stop_lat},
			stop_lon      => $stop_osm->{stop_lon},
			stop_url      => undef,
			location_type => 0,
		};

		delete $data->{stops}->{$stop_id}->{name};
		delete $data->{stops}->{$stop_id}->{alt_name};
		delete $data->{stops}->{$stop_id}->{old_name};
		delete $data->{stops}->{$stop_id}->{alt_old_name};

		$data->{stops}->{$stop_id}->{zone_id} = join ',',
			sort map { s/\s//g; $_ } split /,/, $zones;
	}
	else {
		$data->{stops}->{$stop_id}->{zone_id} = join ',', sort keys %{
			{
				map { s/\s//g; $_ => 1 } split /,/,
				"$data->{stops}->{$stop_id}->{zone_id},$zones"
			}
			};
	}

	delete $stop_gtfs->{zone_id};
	delete $stop_gtfs->{stop_name};

	return $stop_id;
}

sub finalize_trip
{
	my ( $trip, $route, $data ) = @_;

	# Remove passed stops
	for ( my $i = $#{ $trip->{stop_times} }; $i >= 0; $i-- ) {
		if (   $trip->{stop_times}->[$i]->{drop_off_type} eq '1'
			&& $trip->{stop_times}->[$i]->{pickup_type} eq '1'
			&& !$trip->{stop_times}->[$i]->{arrival_time}
			&& !$trip->{stop_times}->[$i]->{departure_time} )
		{
			splice( @{ $trip->{stop_times} }, $i, 1 );
		}
	}

	delete $trip->{trip_signature};
	delete $trip->{trip_number};
	delete $trip->{volan_route};
	delete $trip->{suburban_route};
}

sub parse
{
	my $self   = shift;
	my %params = @_;
	my $glob   = $params{selective};

	create_calendar();

	$log->info("Parseing timetables...");
	my @files = sort glob( catfile( $self->data_directory, ( $glob || 'route_*_*_*.html' ) ) );
	foreach my $file (@files) {
		next if $file =~ /XX/;

		eval {
			my ($trips) = $self->parse_file($file);
			push @$TRIPS, @$trips if $trips;
		};
		if($@) {
			$log->warn("Failed to parse $file: $@");
		}
	}

	# Create routes...
	foreach my $trip (@$TRIPS) {
		unless ( $ROUTES->{ $trip->{route_id} } ) {

			$trip->{route_id} =~ m/(\d*)$/;
			my $short_name = $1;

			$ROUTES->{ $trip->{route_id} } = {
				route_id         => $trip->{route_id},
				agency_id        => 'VOLANBUSZ',
				route_short_name => ( $short_name || 'A Route' ),
				route_type       => 'bus',
				route_url        => $trip->{trip_url},
			};
		}

		my $r = $ROUTES->{ $trip->{route_id} };
		$r->{($trip->{direction_id} && $trip->{direction_id} eq 'outbound' ? 'common_from' : 'common_to')}->{ $trip->{stop_times}[-1]{stop_name} }++;
		$r->{($trip->{direction_id} && $trip->{direction_id} eq 'outbound' ? 'common_to' : 'common_from')}->{ $trip->{stop_times}[ 0]{stop_name} }++;
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

	my $osm_data = HuGTFS::OSMMerger->parse_osm( "Volánbusz", $self->osm_file );

	my $data = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
			stop_is_match       => \&stop_is_match,
			create_stop         => \&create_stop,
			finalize_trip       => \&finalize_trip,
		},
		$osm_data,
		$gtfs_data
	);

	$ROUTES = { map { $_->{route_id} => $_ } @{ $data->{routes} } };
	$TRIPS  = $data->{trips};
	$STOPS  = $data->{stops};
	delete $_->{trips} for values %$ROUTES;

=pod
for ( keys %$SVM ) {
	print "[\n\t[ '"
		. $SVM->{$_} . "', '"
		. $_
		. "', ],\n\t'VBS_"
		. $_
		. "',\n\t0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,\n],\n";
}
print "\n";
=cut

	$log->info("Purging unused data...");
	{

		for ( my $i = $#{$TRIPS}; $i >= 0; $i-- ) {
			splice( @$TRIPS, $i, 1 ) if $#{ $TRIPS->[$i]->{stop_times} } < 1;
		}

		my %visited_stops = ();
		my %used_routes   = ();
		foreach my $trip (@$TRIPS) {
			$used_routes{ $trip->{route_id} } = 1;
			foreach my $stop_time ( @{ $trip->{stop_times} } ) {
				$visited_stops{ $stop_time->{stop_id} } = 1;
			}
		}

		foreach my $stop ( keys %$STOPS ) {
			delete $STOPS->{$stop} unless $visited_stops{$stop};
		}
		foreach my $route ( keys %$ROUTES ) {
			delete $ROUTES->{$route} unless $used_routes{$route};
		}
	}

	for ( my $i = $#{ $AGENCY->{fares} }; $i >= 0; $i-- ) {
		if ( $AGENCY->{fares}[$i]{discount} < 0 ) {
			splice @{ $AGENCY->{fares} }, $i, 1;
		}
		else {
			delete $AGENCY->{fares}[$i]{discount};
		}
	}

	foreach my $route ( keys %$local_routes ) {
		my $zone = $local_zones->{ $local_routes->{$route} };
		foreach my $fare ( @{ $AGENCY->{fares} } ) {
			next unless $fare->{fare_id} =~ m/$zone/;
			next unless $ROUTES->{ $route };

			push @{ $fare->{rules} },
				{ route_id => $route, origin_id => $zone, destination_id => $zone, };
		}
	}

	HuGTFS::Cal->keep_only(qr/^VBS_/);

	# XXX: Expand fares to account for combined zones

	{
		$log->info("Dumping files...");

		my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
		$dumper->clean_dir;

		$dumper->dump_agency($AGENCY);
		$dumper->dump_route($_) for ( map { $ROUTES->{$_} } sort keys %$ROUTES );
		$dumper->dump_stop($_)  for ( map { $STOPS->{$_} } sort keys %$STOPS );
		$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump() );
		$dumper->dump_trip($_) for ( sort { $a->{trip_id} cmp $b->{trip_id} } @$TRIPS );

		$dumper->dump_statistics( $data->{statistics} );

		$dumper->deinit_dumper();
	}

	# Reset defaults
	$SERVICE_MAP = {};
	( $TRIPS, $STOPS, $ROUTES, $AGENCY ) = ( [], {}, {}, {}, );
	( %services, %restrictions, %valid ) = ( (), (), () );
}

sub parse_file
{
	my ( $self, $filename ) = @_;
	my ( $volan_route, $direction, $timetable_id )
		= ( $filename =~ m/(?:^|.+\/)route_(.*?)_(.*?)_(.*?)\.html$/o );
	$direction = ( $direction eq "to" ? 'inbound' : 'outbound' );

	{
		open( my $tfile, '<:utf8', $filename );
		$twig->parse_html($tfile);
	}

	my ( $descriptor, $service_valid )
		= map { $twig->get_xpath( $_, 0 )->text }
		( 'table[@id="menetrend_header"]//th[2]', 'table[@id="menetrend_header"]//td[2]' );
	$service_valid = ( split ':', $service_valid )[1];

	unless($service_valid) {
		$log->info("Skipped empty timetable: $filename");
		return ();
	}

	unless ( $service_valid
		=~ m/.*?(\d{4})-(\d{2})-(\d{2})(?:\s*( - )\s*(\d{4})-(\d{2})-(\d{2}))?.*/mso )
	{
		$log->warn("Timetable outdated: $filename");
		return [];
	}
	$service_valid = $1 . $2 . $3 . ( $4 ? '-' . $5 . $6 . $7 : '' );

	{
		my ($number) = ($descriptor =~ m/(\d+)/);
		unless(
		       ( 300 <= $number && $number <  900)
			|| (2100 <= $number && $number < 2500)) {
			$log->debug("Skipped: $filename ($number)");
			return;
		}

		$log->debug("Parsing: $filename ($number)");
	}


	my ( $index_stop, $index_trip, $max_index_trip );
	{
		my $z = 1;
		foreach ( $twig->get_xpath('table[@id="menetrend"]/tr[0]/td') ) {
			if ( $_->att('class') =~ m/jarat/o ) {
				$max_index_trip = $z;
				$index_trip = $z unless defined $index_trip;
			}
			if ( $_->text =~ m/Megállók/o ) {
				$index_stop = $z;
			}
			$z++;
		}
	}

	my $may_bksz = 0;
	my @stops;

	my $last_td;
	foreach my $td ( $twig->get_xpath("table[\@id=\"menetrend\"]/tr/td[$index_stop]") ) {
		my $stop;
		$last_td = $td;

		if ( $td->text =~ m/BB\s*szak/ ) {
			$may_bksz = 1;
			$stop     = 'BKSZ_HATAR';
			$td->parent->delete;
		}
		elsif ( $td->parent->att('class') && $td->parent->att('class') =~ m/kiemelRow/ ) {
			$td->parent->delete;
			next;
		}
		elsif ( !$td->text
			|| $td->text =~ m/^(?:\s+|Meg\x{c3}\x{a1}ll\x{c3}\x{b3}k.*|Megállók.*)$/i )
		{

			#$td->parent->delete;
			$stop = undef;
		}
		else {
			my $ntd = $td->copy;
			$ntd->cut_children('#ELT');

			$stop = {
				stop_name     => $ntd->trimmed_text,
				pickup_type   => 0,
				drop_off_type => 0,
				zone_id       => '',
			};

			if ( $td->get_xpath('strong') ) {
				$stop->{stop_name}
					= $td->get_xpath( 'strong', 0 )->text . ' ' . $stop->{stop_name};
			}
			if ( $td->get_xpath('span[@class =~ /jel_stop_L/]') ) {
				$stop->{pickup_type} = 1;
			}
			if ( $td->get_xpath('span[@class =~ /jel_stop_F/]') ) {
				$stop->{drop_off_type} = 1;
			}
		}
		push @stops, $stop;
	}
	$last_td->parent->delete;    # Empty row at the bottom of timetables
	pop @stops;                  # Remove undef because of empty last row

	my (@trips) = ();
	my (@paths) = ();

	{
		my @plugs;
		my %path_map;

		sub make_pm($)
		{
			my $path = shift;
			return join '-', map { defined $_ ? $_ : '*' } @$path;
		}

		foreach my $column_index ( 1 .. ( $index_stop - 1 ) ) {

			my $km = [
				map {
					$_ = $_->text;
					s/ //;
					s/\x{2e}\x{2e}/../;
					s/,/./;
					$_ =~ m/S/ ? undef : $_;
					} $twig->get_xpath("table[\@id=\"menetrend\"]/tr/td[$column_index]")
			];
			shift @$km if $km->[0] =~ m/km/i;

			my $first = 0;
			$first++ while($first < $#$km && !(defined $km->[$first] && $km->[$first] =~ m/^\d+\.\d+$/));

			next if $first >= $#$km;

			if (
				$column_index > 1
				&& ( ( $km->[0] && $km->[0] eq '..' )
					|| scalar( grep { defined $_ && $_ eq '0.0' } @{$km}[ 1 .. $#$km ] ) )
				&& (scalar( grep { defined $_->[$first] } @paths))
				)
			{

				# FOREACH path, which visits the first/last stop of the plug, but avoids the stops between,
				# create a duplicate which visits the stops, readjusting the km data
				# ALSO, take into account, that if the plug data decreases the difference needs to be used

				my $plug_start = undef;
				for ( my $i = 0; $i <= $#$km; $i++ ) {
					next if !defined $km->[$i] || $km->[$i] eq '..';

					if ( $km->[$i] eq '0.0'
						&& ( $i == 0 || ( $km->[ $i - 1 ] && $km->[ $i - 1 ] eq '..' ) ) )
					{
						$plug_start = $i;
					}
					elsif (defined $plug_start
						&& defined $km->[$i]
						&& $km->[$i] eq '0.0'
						&& ( !defined $km->[ $i + 1 ] || $km->[ $i + 1 ] ne '..' ) )
					{
						push @plugs, [ $plug_start, @{$km}[ $plug_start .. $i ] ];

						$plug_start = $i;
					}
					elsif (defined $plug_start
						&& defined $km->[$i]
						&& $km->[$i] ne '..'
						&& ( $i == $#$km || ( $km->[ $i + 1 ] && $km->[ $i + 1 ] eq '..' ) ) )
					{
						push @plugs, [ $plug_start, @{$km}[ $plug_start .. $i ] ];

						$plug_start = undef;
					}
				}
			}
			else {
				my $np = [ map { defined $_ && $_ eq '..' ? undef : $_ } @$km ];
				push @paths, $np;

				#push @plugs, [ 0, $np ];
				$path_map{ make_pm $np} = 1;
			}
		}

		foreach my $i (0 .. $#paths - 1) {
			foreach my $j ($i + 1 .. $#paths) {
				my ($path_a, $path_b) = @paths[$i, $j];
				my $start = undef;

				foreach my $k( 0 .. $#$path_a - 1) {
					if(defined $start && defined $path_a->[$k] && defined $path_b->[$k]) {
						push @plugs, [ $start, map { (defined  $_ && $_ =~ m/^\d+\.\d+$/ ? $_ - $path_a->[$start] : undef) } @{$path_a}[$start .. $k] ];
						push @plugs, [ $start, map { (defined  $_ && $_ =~ m/^\d+\.\d+$/ ? $_ - $path_b->[$start] : undef) } @{$path_b}[$start .. $k] ];

						$start = undef;
					}

					if(defined $path_a->[$k] && defined $path_b->[$k] && (!defined $path_a->[$k + 1] || !defined $path_b->[$k+1])) {
						$start = $k;
					}
				}
			}
		}

		@plugs = sort { $a->[0] <=> $b->[0] } values %{ { map  { join('-', map { $_ ? $_ : '' } @$_) =>  $_ } @plugs } };

		# XXX: Create list of distinct plugs...
		#die print Data::Dumper::Dumper(@plugs);

		foreach my $real_plug (@plugs) {

			my ( $real_start, $l, $i ) = ( shift @$real_plug );
			$real_plug = [ map { defined $_ && $_ eq '..' ? undef : $_ } @$real_plug ];

			$l = $#$real_plug;
			do {
				$l--;
			} until ( $l == 0 || defined $real_plug->[$l] );
			for ( $i = $#$real_plug; $i > 0; $i-- ) {
				last unless defined $real_plug->[$i] && defined $real_plug->[$l];
				last if $real_plug->[$i] > $real_plug->[$l];
				next unless defined $real_plug->[$i];

				$real_plug->[$i] = $real_plug->[$l] - $real_plug->[$i];

				do {
					$l--;
				} until ( $l == 0 || defined $real_plug->[$l] );
			}

			$l = $i;
			until ( $l == 0 || defined $real_plug->[$l] ) {
				$l--;
			}

			for ( $i++; $i <= $#$real_plug; $i++ ) {
				next unless defined $real_plug->[$i] && $real_plug->[$l];

				$real_plug->[$i] = $real_plug->[$l] + $real_plug->[$i];

				$l = $i;
			}

			my @np;
			foreach my $plug_from ( 0 .. $#$real_plug - 1 ) {
				foreach my $plug_to ( $plug_from + 1 .. $#$real_plug ) {
					my ( $start, $plug ) = (
						$real_start + $plug_from,
						[ @{$real_plug}[ $plug_from .. $plug_to ] ]
					);
					next unless defined $plug->[0] && defined $plug->[$#$plug];

					$plug = [ map { defined $_ ? $_ - $plug->[0] : $_ } @$plug ];

					for ( my $q = 0; $q <= $#paths; $q++ ) {
						my $p = $paths[$q];

						next
							unless ( defined $p->[$start]
							&& defined $p->[ $start + $#$plug ]
							&& $#$plug - $start > 1 )
							|| ( defined $p->[$start] && $plug_to == $#$real_plug )
							|| ( defined $p->[ $start + $#$plug ] && $plug_from == 0 );

						my $np = [@$p];

						# MERGE + FORK
						if ( defined $p->[$start] && defined $p->[ $start + $#$plug ] ) {

							# Difference in original path between forking stops
							my $diff = $p->[$start] - $p->[ $start + $#$plug ];

							for ( $i = $start + 1; $i <= $start + $#$plug; $i++ ) {
								$np->[$i]
									= defined $plug->[ $i - $start ]
									? ( $np->[$start] + $plug->[ $i - $start ] )
									: undef;
							}

							for ( ; $i <= $#$np; $i++ ) {
								$np->[$i] += $diff + $plug->[$#$plug]
									if defined $np->[$i];
							}
						}

						# MERGE
						elsif ( !defined $p->[$start] ) {

							# Difference in original path between forking stops
							my $diff = 0 - $p->[ $start + $#$plug ];

							for ( $i = 0; $i < $start; $i++ ) {
								$np->[$i] = undef;
							}

							$np->[$start] = '0.0';

							for ( $i = $start + 1; $i <= $start + $#$plug; $i++ ) {
								$np->[$i]
									= defined $plug->[ $i - $start ]
									? ( $np->[$start] + $plug->[ $i - $start ] )
									: undef;
							}

							for ( ; $i <= $#$np; $i++ ) {
								$np->[$i] += $diff + $plug->[$#$plug]
									if defined $np->[$i];
							}
						}

						# FORK
						else {
							for ( $i = $start + 1; $i <= $start + $#$plug; $i++ ) {
								$np->[$i]
									= defined $plug->[ $i - $start ]
									? ( $np->[$start] + $plug->[ $i - $start ] )
									: undef;
							}

							for ( ; $i <= $#$np; $i++ ) {
								$np->[$i] = undef;
							}
						}
						$np = [ map { defined $_ ? sprintf( "%.1f", $_ ) : $_ } @$np ];

						my $pm = make_pm $np;
						if ( !$path_map{$pm} ) {
							push @paths, $np;
							$path_map{ make_pm $np} = 1;
						}
					}
				}
			}
		}


		if (0) {
			my @g;
			my $cols = 30;
			my $fmt = '^###.#' x ( $cols - 1 );
			eval "format = \n$fmt\n\@g\n.";

			@paths = (sort { make_pm($a) cmp make_pm($b) } @paths );
			for my $row (1) {

				print "-" x ( 6 * ( $cols - 1 ) ) . "\n";
				print "    "
					. ( ( $row - 1 ) * $cols ) . " -> "
					. ( ( $row * $cols ) - 1 )
					. " of " . (1 + $#paths) . "\n";
				for my $i ( 0 .. $#{ $paths[0] } ) {
					@g = ( map { $_->[$i] }
							@paths[ ( $row - 1 ) * $cols .. $row * $cols - 1 ] );
					write;
				}
			}
			die;
		}
	}

	foreach my $trip_index ( $index_trip ... $max_index_trip ) {
		my $td = $twig->get_xpath( "table[\@id=\"menetrend\"]/tr[0]/td[$trip_index]", 0 );
		if ( $td->get_xpath( './/a', 0 ) ) {
			next;    # Subset of a trip from a differing route
		}

		my ( $suburban_route, $trip_number, $service, $restriction ) = ( 0, 0, 0, 0 );
		my $ntd = $td->copy;
		$ntd->cut_children('#ELT');

		my @children = $td->get_xpath('.//span[@class="jaratszam_top"]', 0)->children;

		if (   $#children >= 2
			&& $children[0]->tag eq '#PCDATA'
			&& $children[1]->tag eq 'br'
			&& $children[2]->tag eq '#PCDATA'
			&& $children[2]->trimmed_text )
		{
			$suburban_route = $children[0]->text;
			$trip_number    = $children[2]->text;
		}
		else {
			$trip_number = $children[0]->text;
			if ( $trip_number > 1000 ) {
				next;    # Presumably another route...
			}
		}

		if ( $td->get_xpath( './/span[@class =~ /jaratjel/]/span', 0 ) ) {
			my $img = $td->get_xpath( './/span[@class =~ /jaratjel/]/span[@class =~ /jel_alt/]/img', 0 );
			if( $img) {
				$service = $img->att('alt');
			} else {
				$service = $td->get_xpath( './/span[@class =~ /jaratjel/]/span[@class =~ /jel_/]', 0 )->trimmed_text;
			}
		} else {
			$service = '';
		}

		if ( $td->get_xpath( './/span[@class =~ /jaratinv/]/span[@class =~ /jel_inv/]', 0 ) ) {
			$restriction = $td->get_xpath( './/span[@class =~ /jaratinv/]/span[@class =~ /jel_inv/]', 0 )->trimmed_text;
		}

		my $trip = {
			trip_number    => $trip_number,
			volan_route    => $volan_route,
			suburban_route => $suburban_route,
			trip_signature => undef,

			route_id => ( $suburban_route || $volan_route ),
			trip_short_name => $trip_number,
			trip_id => "VBT_${volan_route}_${suburban_route}_${trip_number}_T$timetable_id",
			trip_headsign => $descriptor,
			stop_times    => [],
			direction_id  => $direction,
			service_id    => get_service_id( $volan_route, $service, $restriction, $service_valid ),
			shape_id      => undef,
			trip_url      => $self->reference_url ? ($self->reference_url . '/' . $filename) : undef,
		};

		if ($td->get_xpath('.//img[@class =~ /icon_disabled/]', 0))
		{
			$trip->{wheelchair_accessible} = 'yes';
		}

		# $dist = -1 'case there is a bogus undef stop at start
		my ( $crossed, $prev_time, $bksz, $switched, $i, $dist ) = ( 0, 0, 0, 0, 0, -1 );
		foreach my $stopy ( $twig->get_xpath("table[\@id=\"menetrend\"]/tr/td[$trip_index]") ) {
			my $text = $stopy->text;
			next unless $stops[$i];

			if ( $may_bksz && $stops[$i] eq 'BKSZ_HATAR' ) {
				$bksz     = !$bksz;
				$switched = 1;
				$i++
					; # The row containg BKSZ was removed, put an index was kept for it in $stops
			}

			if ( $text =~ m/^(?:o|\[)$/ ) {    # ???
				    # XXX: [ -> continues as another trip -> the one on the the right
				    # o -> presumably signifies end-of-life for trip
				last;
			}

			my %stop = (
				%{ $stops[$i] },
				shape_dist_traveled => $dist,
				arrival_time        => undef,
				departure_time      => undef,
			);

			if ( $may_bksz && !$switched && $stop{stop_name} =~ m/^(?:Bp\.|Budapest)/ ) {
				$bksz     = 1;
				$switched = 1;
			}

			next if $text =~ m/^\s*[sS][sS]?\s*$/ || $text =~ m/^\s+$/;

			if ( $text =~ m/[I|]/ ) {    # Stop passed
				@stop{ 'pickup_type', 'drop_off_type' } = ( 1, 1 );
			}
			elsif ( $text =~ m/^(\d?\d[.:]\d\d)$/ ) {
				my $time = _0D($text);    # Handle day boundary
				if ( $prev_time && !$crossed && _S($prev_time) - _S($time) > 6 * 60 * 60 ) {
					$crossed = 1;
				}
				else {
					$prev_time = $time;
				}

				if ($crossed) {
					$time = _T( _S($time) + 24 * 60 * 60 );
				}
				@stop{ 'arrival_time', 'departure_time' } = ( $time, $time );
			}
			else {
				warn $text;
			}

			if ( $stopy->get_xpath('span[@class =~ /jel_stop_F/]') ) {    # Felszálás csak
				@stop{ 'pickup_type', 'drop_off_type' } = ( 0, 1 );
			}
			elsif ( $stopy->get_xpath('span[@class =~ /jel_stop_L/]') ) {    # Leszálás csak
				@stop{ 'pickup_type', 'drop_off_type' } = ( 1, 0 );
			}

			if (   $local_routes->{$suburban_route}
				&& $stop{stop_name} =~ m/^$local_routes->{$suburban_route},/ )
			{
				$stop{zone_id} = $local_zones->{ $local_routes->{$suburban_route} };
			}

			if ($bksz) {
				$stop{zone_id} = 'BUDAPEST';
			}

			push @{ $trip->{stop_times} }, \%stop;
		}
		continue {
			$i++;
			$dist++;
		}

		if ( !scalar @{ $trip->{stop_times} } ) {
			$log->warn("Trip $trip->{trip_id} contains no stops....");
			next;
		}

	STPATH:
		foreach my $path (@paths) {
			my $start = $trip->{stop_times}->[0]->{shape_dist_traveled};
			$i = $start;

			foreach my $st ( @{ $trip->{stop_times} } ) {
				for ( $i .. $st->{shape_dist_traveled} ) {
					next STPATH
						if ( defined $path->[$_] && $st->{shape_dist_traveled} != $_ )
						|| ( !defined $path->[$_] && $st->{shape_dist_traveled} == $_ );
				}
				$i = $st->{shape_dist_traveled} + 1;
			}

			my $offset = $path->[$start];
			for ( 0 .. $#{ $trip->{stop_times} } ) {
				$trip->{stop_times}[$_]{shape_dist_traveled}
					= $path->[ $trip->{stop_times}[$_]{shape_dist_traveled} ] - $offset;
			}

			last;
		}
		if ( $trip->{stop_times}->[0]->{shape_dist_traveled} > 0 ) {
			$log->warn("No KM data: $trip->{trip_id}");
		}

		eval {
			$trip->{trip_headsign}
				= $trip->{stop_times}->[ $#{ $trip->{stop_times} } ]->{stop_name};
		};

		# If the same stop follows, merge the stop times
		for ( my $i = 0; $i < $#{ $trip->{stop_times} }; $i++ ) {

			if ( $trip->{stop_times}->[$i]->{stop_name} eq
				   $trip->{stop_times}->[ $i + 1 ]->{stop_name}
				&& $trip->{stop_times}->[$i]->{arrival_time}
				&& $trip->{stop_times}->[ $i + 1 ]->{departure_time} )
			{
				$trip->{stop_times}->[$i]->{departure_time}
					= $trip->{stop_times}->[ $i + 1 ]->{departure_time};
				splice @{ $trip->{stop_times} }, $i + 1, 1;
			}
		}

		push @trips, $trip;
	}

	$twig->purge;

	return \@trips;
}

# http://www.volanbusz.hu/hu/belfoldiutazas/menetrend/naptar
# http://www.volanbusz.hu/uploadfiles/57_jelmagyarazat.pdf
# http://www.volanbusz.hu/hu/belfoldiutazas/menetrend/jelmagyarazat
sub create_calendar
{
	my $data = [
#<<<
		[
			qw/service_id monday tuesday wednesday thursday friday saturday sunday start_date end_date service_desc/
		],

		[ [ "_", "naponta" ], 'VBS__', 1, 1, 1, 1, 1, 1, 1, CAL_START, CAL_END, ],

		[ ["M", "munkanapokon"], "VBS_M",
			1, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END, ],

		[ ["O", "szabadnapokon"], "VBS_O",
			0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END, ],

		[ ["V", "munkaszüneti napokon"], "VBS_V",
			0, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END, ],

		[ ["U", "nem közlekedik", "egyelőre nem közlekedik"], "VBS_U",
			0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END, ],

		[ [ "nemtudni", ], 'DUNNO', 0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END, ],
	];
#>>>

	HuGTFS::Cal->empty;

	foreach my $i ( 1 .. $#$data ) {
		$data->[$i]->[ $#{ $data->[0] } + 1 ] = $data->[$i]->[0]->[1];    # service_desc
		$SERVICE_MAP->{$_} = $data->[$i]->[1] for @{ $data->[$i]->[0] };
		shift @{ $data->[$i] };

		HuGTFS::Cal->new( map { $data->[0]->[$_] => $data->[$i]->[$_] } 0 .. $#{ $data->[0] } );
	}

	my $exceptions = [ [qw/service_id date exception_type/], ];

# DATEMOD
	push(
		@$exceptions,

		# M munkanapokon
		[qw/VBS_M 20121215 added  /],
		[qw/VBS_M 20121224 removed/],
		[qw/VBS_M 20121225 removed/],
		[qw/VBS_M 20121226 removed/],
		[qw/VBS_M 20121231 removed/],
		[qw/VBS_M 20130101 removed/],
		[qw/VBS_M 20130315 removed/],
		[qw/VBS_M 20130401 removed/],
		[qw/VBS_M 20130501 removed/],
		[qw/VBS_M 20130520 removed/],
		[qw/VBS_M 20130819 removed/],
		[qw/VBS_M 20130820 removed/],
		[qw/VBS_M 20130824 added  /],
		[qw/VBS_M 20131023 removed/],
		[qw/VBS_M 20131101 removed/],
		[qw/VBS_M 20131207 added  /],

		# O szabadnapokon
		[qw/VBS_O 20121215 removed/],
		[qw/VBS_O 20130316 removed/],
		[qw/VBS_O 20130824 removed/],
		[qw/VBS_O 20131102 removed/],
		[qw/VBS_O 20131207 removed/],

		# V munkaszüneti napokon
		[qw/VBS_V 20121224 added  /],
		[qw/VBS_V 20121225 added  /],
		[qw/VBS_V 20121226 added  /],
		[qw/VBS_V 20121231 added  /],
		[qw/VBS_V 20130101 added  /],
		[qw/VBS_V 20130315 added  /],
		[qw/VBS_V 20130316 added  /],
		[qw/VBS_V 20130401 added  /],
		[qw/VBS_V 20130501 added  /],
		[qw/VBS_V 20130520 added  /],
		[qw/VBS_V 20130819 added  /],
		[qw/VBS_V 20130820 added  /],
		[qw/VBS_V 20131023 added  /],
		[qw/VBS_V 20131101 added  /],
		[qw/VBS_V 20131102 added  /],
	);

	foreach my $i ( 1 .. $#$exceptions ) {
		HuGTFS::Cal->find( $exceptions->[$i]->[0] )
			->add_exception( @{ $exceptions->[$i] }[ 1, 2 ] );
	}

	HuGTFS::Cal->descriptor(['RENAME', ['OR'    , 'VBS_O', 'VBS_V'                     ], 'VBS_A', 'szabad- és munkaszüneti napokon'                   ]);
	HuGTFS::Cal->descriptor(['RENAME', ['INVERT', 'VBS_V'                              ], 'VBS_N', 'munkaszüneti napok kivételével naponta'            ]);
	HuGTFS::Cal->descriptor(['RENAME', ['INVERT', 'VBS_O'                              ], 'VBS_K', 'szabadnapok kivételével naponta'                   ]);
	HuGTFS::Cal->descriptor(['RENAME', ['LIMIT' , 'VBS_M', HuGTFS::Cal::CAL_A_TANSZUNET], 'VBS_I', 'iskolai előadási napokon'                          ]);
	HuGTFS::Cal->descriptor(['RENAME', ['LIMIT' , 'VBS_M', HuGTFS::Cal::CAL_TANSZUNET  ], 'VBS_T', 'tanszünetben munkanapokon'                         ]);

	HuGTFS::Cal->descriptor(['RENAME', ['FIRST-DAY' , 'VBS_M'                          ], 'VBS_H', 'a hetek első munkanapján'                          ]);
	HuGTFS::Cal->descriptor(['RENAME', [ 'LAST-DAY' , 'VBS_M'                          ], 'VBS_P', 'a hetek utolsó munkanapján'                        ]);
	HuGTFS::Cal->descriptor(['RENAME', [ 'PREV-DAY' , 'VBS_M'                          ], 'VBS_E', 'a hetek első munkanapját megelőző napokon'         ]);

	HuGTFS::Cal->descriptor(['RENAME', ['SUBTRACT', 'VBS_M', 'VBS_P'                   ], 'VBS_C', 'a hetek utolsó munkanapja kivételével munkanapokon']);

	#HuGTFS::Cal->find($_)->PRINT for( qw/VBS_O VBS_V VBS_A VBS_M VBS_N VBS_K VBS_I VBS_T VBS_H VBS_P VBS_E VBS_C/ ); die;

	my @descriptors = (
		[['1', 'hétfői munkanapokon'],
			['AND', ['SERVICE', monday => 1], 'VBS_M'],],
		[['5', 'pénteki munkanapokon'],
			['AND', ['SERVICE', friday => 1], 'VBS_M'],],
		[['8', 'külön rendeletre'],
			[qw/MAP VBS_U/],],
		[['11', 'iskolai előadási napokon valamint szabadnapokon'],
			[qw/OR VBS_I VBS_O/],],
		[['14', 'a hetek utolsó iskolai előadási napján'],
			['LAST-DAY', 'VBS_I'],],
		[['15', 'a hetek első iskolai előadási napját megelőző munkaszüneti napokon'],
			['PREV-DAY', 'VBS_I'],],
		[['16', 'tanév tartama alatt munkanapokon'],
			['LIMIT', 'VBS_M', HuGTFS::Cal::CAL_TANEV],],
		[['22', 'munkanapokon keddtől-péntekig'],
			['AND', 'VBS_M', ['SERVICE', map { $_ => 1 } qw/tuesday wednesday thursday friday/]],],
		[['23', 'nyári tanszünetben munkaszüneti napokon'],
			['LIMIT', 'VBS_V', CAL_SUMMER],],
		[['27', 'a hetek utolsó iskolai előadási napja kivételével iskolai előadási napokon'],
			[qw/SUBTRACT VBS_I VBS_14/],],
		[['28', 'munkaszüneti napok kivételével naponta, valamint 2013. III. 16-án, VIII. 19-én és XI. 2-án'],
			['ADD', 'VBS_N', '20130316,20130819,20131102'],],
		[['29', 'III. 1-től X. 31-ig szabadnapokon'],
			[qw/LIMIT VBS_O 20130301-20131031/],],
		[['31', 'VI. 1-től IX. 30-ig szabad- és munkaszüneti napokon közlekedik'],
			[qw/LIMIT VBS_A 20130601-20130930/],],
		[['32', 'IV.1-től. X.31.-ig  munkaszüneti napokon'],
			[qw/LIMIT VBS_V 20130401-20131031/],],
		[['34', 'V. 1-től IX. 30-ig szabad- és munkaszüneti napokon'],
			[qw/LIMIT VBS_A 20130501-20130930/],],
		[['37', 'szabad- és munkaszüneti napokon, valamint tanszünetben munkanapokon'],
			[qw/OR VBS_A VBS_T/],],
		[['41', 'IV. 1-től IX. 30-ig a hetek utolsó munkanapján'],
			['LIMIT', 'VBS_P', '20130401-20130930'],],
		[['42', 'III.31-ig és XI. 1-jétől munkaszüneti napokon'],
			['LIMIT', 'VBS_V', '-20130331,20131101-'],],
		[['44', 'IV. 30-ig és X. 1-től szabad- és munkaszüneti napokon'],
			['LIMIT', 'VBS_A', '-20130430,20131001-'],],
		[['49', 'III. 1-től X. 31-ig a hetek első munkanapját megelőző munkaszüneti napokon'],
			[qw/LIMIT VBS_E 20130301-20131031/],],
		[['54', 'VI. 1-től VIII. 31-ig a hetek utolsó munkanapján'],
			[qw/LIMIT VBS_P 20130601-20130831/],],
		[['66', 'a hetek első tanítási napját megelőző napon'],
			['PREV-DAY', 'VBS_I'],],
		[['70', 'a hetek utolsó tanszünetes munkanapja kivételével tanszünetben munkanapokon'],
			['SUBTRACT', 'VBS_T', ['LAST-DAY', 'VBS_T']],],
		[['71', 'őszi, téli és tavaszi tanszünetben munkanapokon közlekedik'],
			['LIMIT', 'VBS_M', HuGTFS::Cal::CAL_TANSZUNET_OSZ, HuGTFS::Cal::CAL_TANSZUNET_TEL, HuGTFS::Cal::CAL_TANSZUNET_TAVASZ],],
		[['74', 'szabadnapokon, valamint 2012. XII. 24-én, XII. 31-én, 2013. III. 16-án, VIII. 19-én és XI. 2-án'],
			[qw/ADD VBS_O 20121224 20121231 20130316 20130819 20131102/]],
		[['76', 'a hetek utolsó munkanapján és a hetek első munkanapját megelőző munkaszüneti napokon'],
			[qw/OR VBS_P VBS_E/],],
		[['77', 'munkanapokon, valamint szabad- és munkaszüneti napokon'],
			[qw/OR VBS_M VBS_A/],],
		[['78', 'nyári tanszünetben szabad és munkaszüneti napokon'],
			['LIMIT', 'VBS_A', CAL_SUMMER],],
		[['79', 'a hetek első munkanapját megelőző munkaszüneti nap kivételével munkaszüneti napokon'],
			[qw/SUBTRACT VBS_V VBS_E/],],
		[['82', 'nyári tanszünetben szabadnapokon'],
			['LIMIT', 'VBS_O', CAL_SUMMER],],
		[['84', 'munkanapot követő napokon'],
			['NEXT-DAY', 'VBS_M'],],
		[['87', 'nyári tanszünetben munkanapokon, valamint XII. 27-én és 28-án'],
			['ADD', ['LIMIT', 'VBS_M', CAL_SUMMER], 20121227, 20121228],],
		[['92', 'szabadnapokon, valamint tanszünetben munkanapokon'],
			[qw/OR VBS_O VBS_T/],],
		[['94', 'IV.1-től IX.30-ig szabadnapokon közlekedik'],
			[qw/LIMIT VBS_O 20130401-20130930/],],
		[['95', 'IV.1-től IX.30-ig munkaszüneti napokon közlekedik'],
			[qw/LIMIT VBS_V 20130401-20130930/],],
		[['98', 'munkaszüneti napok kivételével naponta, valamint 2012. XII. 24-én, XII. 31-én, 2013. III. 16-án, VIII. 19-én és XI. 2-án'],
			[qw/ADD VBS_N 20121224 20121231 20130303 20130316 20130819 20131102/],],
		[['99', 'pénteki tanítási napokon, valamint 2013. III. 14-én és III. 27-én'],
			['ADD', ['AND', 'VBS_I', ['SERVICE', friday => 1], '20130303,20130227'],],],
	);

	foreach (@descriptors) {
		HuGTFS::Cal->descriptor([ 'RENAME', $_->[1], 'VBS_' . $_->[0][0], $_->[0][1] ]);
	}
}

sub get_service_id
{
	my ( $route, $service, $restriction, $service_valid ) = @_;

	state $modifiers = {
		2 => ['REMOVE', '20121224'], # 2 XII. 24.
		3 => ['REMOVE', '20121224,20121231'], # 3 XII. 24. és 31.
		5 => ['REMOVE', '20121225,20121226'], # 5 XII. 25. és 26.
		6 => ['REMOVE', '20121225,20121226,20130101'], # 6 XII. 25., 26. és I. 1.
		9 => ['REMOVE', '20121227,20121228'], # 9 XII. 27-én és 28-án
		10 => ['REMOVE', '20121225,20130101'], # 10 XII. 25-én és I. 1-én
		12 => ['REMOVE', '20121224-20121226,20130101'], # 12 XII. 24., 25., 26. és I. 1.
		51 => ['REMOVE', '20121225'], # 51 XII. 25.
		61 => ['ADD', '20121225,20121226,20130101'], # 61 XII. 25-26. és I. 1-jén közlekedik
		#71 => ['REMOVE', '20121224,20121225'], # 71 XII. 24, 25.
		71 => ['REMOVE', '20121224-20121226,20121231'], # 71 XII. 24., 25., 26., és 31.
		72 => ['REMOVE', '20121224,20121225,20121231'], # 72 XII. 24-25-én és XII. 31-én
		82 => ['REMOVE', '20121226'], # 82 XII. 26.
		83 => ['REMOVE', '20121225,20121226,20121231'], # 83 XII. 25., 26. és 31.
		91 => ['REMOVE', '20121227,20121228'], # 91 XII. 27-28-án

		16 => ['SUBTRACT', ['REMOVE', ['LIMIT', 'VBS_M', HuGTFS::Cal::CAL_TANEV], '20121227,20120228']], # tanév tartama alatt munkanapokon, kivéve XII. 27-én és 28-án
		87 => ['SUBTRACT', ['LIMIT', 'VBS_M', CAL_SUMMER]], # nyári tanszünetben munakanapokon

		21 => ['REMOVE', '20121224'],
		22 => ['REMOVE', '20121224'],
		23 => ['REMOVE', '20121224'],
		24 => ['REMOVE', '20121224'],
		25 => ['REMOVE', '20121224'],
		26 => ['REMOVE', '20121224'],
		27 => ['REMOVE', '20121224'],
		31 => ['REMOVE', '20121224,20121231'],
		32 => ['REMOVE', '20121224,20121231'],
		61 => ['REMOVE', '20121225,20121226,20121231'],
		62 => ['REMOVE', '20121225,20121226,20121231'],
		81 => ['REMOVE', '20121228'],
	};

	state $overlapping = {
		5  => {(map { $_ => 'S'} qw/2493/),
		       (map { $_ => 'R'} qw/2115 2735 /),},
		22 => {(map { $_ => 'S'} qw/4451/),
		       (map { $_ => 'R'} qw/2010 2411 2810 2920/),},
		23 => {(map { $_ => 'S'} qw/2468/),
		       (map { $_ => 'R'} qw/2204 2441 2920/),},
		27 => {(map { $_ => 'S'} qw/2403 2505 2552/),
		       (map { $_ => 'R'} qw/2920/),},
		31 => {(map { $_ => 'S'} qw/2636/),
		       (map { $_ => 'R'} qw/2204 2221 2322 2326/),},
		32 => {(map { $_ => 'S'} qw/2080 2085/),
		       (map { $_ => 'R'} qw/2322 2326/),},
		71 => {(map { $_ => 'S'} qw/2683/),
		       (map { $_ => 'R'} qw/2105 2304/),},
		82 => {(map { $_ => 'S'} qw/2468/),
		       (map { $_ => 'R'} qw//),},
		87 => {(map { $_ => 'S'} qw/2018 2026 2040 2090 2160 2200 2923 4492/),
		       (map { $_ => 'R'} qw/2005 2010 2011/),},
	};

	if(!$service) {
		if($overlapping->{$restriction}) {
			unless($overlapping->{$restriction}->{$route}) {
				$log->warn("Missing data for overlapping service/restriction: (route: $_[0])  service: <$_[1]> restriction: <$_[2]>");
				return "VBS_U";
			}
			elsif($overlapping->{$restriction}->{$route} eq 'S') {
				$service = $restriction;
				$restriction = undef;
			}
		}
	   	elsif(!$modifiers->{$restriction}) {
			$service = $restriction;
			$restriction = undef;
		}
	}

	$service = '_' if !$service;

	my $fid = "VBS_$service" . ($restriction ? "-$restriction" : "") . "_$service_valid";
	return $fid if HuGTFS::Cal->find($fid);

	my $cal = HuGTFS::Cal->find("VBS_$service");
	if ( $cal ) {
		if ($restriction) {
			if($modifiers->{$restriction}) {
				$cal = $cal->descriptor($modifiers->{$restriction});
			} else {
				$log->warn("Unknown restriction: (route: $_[0])  service: <$_[1]> restriction: <$_[2]>");
			}
		}

		if ( $service_valid =~ /(.*)-(.*)/ ) {
			$cal = $cal->limit( $1, $2 );
		}
		else {
			$cal = $cal->limit( $service_valid, CAL_END );
		}
		return $cal->clone($fid)->service_id;
	}
	elsif ($service) {
		$log->warn("Unknown service: (route: $_[0])  service: <$_[1]> restriction: <$_[2]>");
	}
	else {
		return 'VBS__';
	}
}

=pod
21 XII. 24-én 120 perccel később közlekedik
21 XII. 24-én 20 perccel korábban és csak Nagytarcsa, kistemplomig közlekedik,
21 XII. 24-én 20 perccel korábban közlekedik
21 XII. 24-én 30 perccel később közlekedik
21 XII. 24-én 60 perccel korábban közlekedik
21 XII. 24-én Fót, aut. áll.-ig közlekedik
21 XII. 24-én Fót, aut. áll.-ig közlekedik,
21 XII. 24-én közlekedik
21 XII. 24-én Nézsa, gyógyszertárig közlekedik
21 XII. 24-én Nézsa, gyógyszertárig közlekedik,
21 XII. 24-én rövidített útvonalon, Bicske, vá. - Etyek, aut. ford. között közlekedik
21 XII. 24-én rövidített útvonalon, Zsámbék, Szent István térig közlekedik
21 XII. 24-én Szokolya, kh.-ig közlekedik
21 XII. 24-én 20 perccel korábban, Csobánka, Plandics tér érintésével és csak Pilisszentkereszt, autóbusz-fordulóig közlekedik
21 XII. 24-én 30 perccel később közlekedik
21 XII. 24-én 60 perccel korábban közlekedik
21 XII. 24-én csak Máriahalom, sz. boltig közlekedik
21 XII. 24-én csak Szentendre, aut. áll.-ig közlekedik
21 XII. 24-én csak Tahitótfalu, Hősök teréig közlekedik
21 XII. 24-én Szentendre, aut. áll.-ig közlekedik
21 XII. 24-én Tápiószőlős, aut. ford. megállóhelyig közlekedik
22 XII. 24-én 10 perccel később közlekedik
22 XII. 24-én csak Pilismarót, kh.-ig közlekedik
22 XII. 24-én Tápiószentmárton, Vízmű megállóhelyig közlekedik
22 XII. 24-én 120 perccel korábban közlekedik
22 XII. 24-én a járat Erdőkürt érintésével, Erdőtarcsáig közlekedik
22 XII. 24-én Dunakeszi, Okmányirodáig közlekedik
22 XII. 24-én rövidített útvonalon, Sóskút, iskola - Biatorbágy, aut. ford. között közlekedik
23 XII. 24-én 60 perccel korábban közlekedik
23 XII. 24-én 30 perccel korábban közlekedik
23 XII. 24-én Jászkarajenő, műv. ház megállóhelyig közlekedik
23 XII. 24-én Szenetendre, aut. áll.-ig közlekedik, ahol Budapest felé átszállást biztosítunk a 872/16 sz. járatra
24 XII. 24-én csak Kalocsa, aut. áll.-ig közlekedik
24 XII. 24-én 10 perccel korábban közlekedik
24 XII. 24-én 5 perccel később közlekedik
24 XII. 24-én Csemő, kh. megállóhelyig közlekedik
25 XII. 24-én 15 perccel később közlekedik
25 XII. 24-én Tahitótfalu, Hídfőig közlekedik
26 XII. 24-én Dunabogdány, kh.-ig közlekedik
26 XII. 24-én Gomba, aut. ford. megállóhely érintésével közlekedik
27 XII. 24-én Pilismarót, kh.-ig közlekedik
31 XII. 24-én nem közlekedik és XII. 31-én csak Nagytarcsa, kistemplomig közlekedik
31 nem közlekedik XII. 24-én, XII. 31-én 115 perccel korábban közlekedik
31 nem közlekedik XII. 24-én, XII. 31-én 60 perccel korábban közlekedik
31 nem közlekedik XII. 24-én, XII. 31-én 75 perccel korábban közlekedik
32 nem közlekedik XII. 24-én, XII. 31-én 70 perccel korábban közlekedik
61 XII. 25-26-án és I. 1-jén 130 perccel később közlekedik
61 XII. 25-26-án és I. 1-jén 60 perccel később közlekedik
61 XII. 25-26-án és I. 1-jén csak Pilismarót, kh. és Esztergom, aut. áll. között közlekedik
61 XII. 25-26-án és I. 1-jén csak Pilisszentkereszt, autóbusz-forduló és Pomáz, aut. áll. között közlekedik
62 XII. 25-26-án és I. 1-jén 60 perccel később közlekedik
62 XII. 25-26-án és I. 1-jén csak Tahitótfalu, Hídfő és Szentendre, aut. áll. között közlekedik
81 XII. 28-án csak Jászapáti, aut. áll.-ig közlekedik
=cut

sub fare_data
{
	$AGENCY->{fares} = [
		{
			'fare_id'        => 'E_DUNAKESZI',
			'price'          => '165',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_DUNAKESZI',
			'price'          => '165',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'E_ERD',
			'price'          => '175',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_ERD',
			'price'          => '210',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'E_GODOLLO',
			'price'          => '210',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_GODOLLO',
			'price'          => '250',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'E_SZENTENDRE',
			'price'          => '200',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_SZENTENDRE',
			'price'          => '265',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'E_TOROKBALINT',
			'price'          => '145',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_TOROKBALINT',
			'price'          => '165',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'E_VAC',
			'price'          => '210',
			'currency_type'  => 'HUF',
			'payment_method' => 'prepaid',
			'transfers'      => 0,
			'rules'          => [],
		},
		{
			'fare_id'        => 'G_VAC',
			'price'          => '300',
			'currency_type'  => 'HUF',
			'payment_method' => 'onboard',
			'transfers'      => 0,
			'rules'          => [],
		},
	];
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
