
=head1 NAME

HuGTFS::FeedManager::Volan::Zala - HuGTFS feed manager for Zala Volán

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Zala;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Volan::Zala;

use 5.14.0;
use utf8;
use strict;
use warnings;

use YAML ();
use XML::Twig;
use File::Spec::Functions qw/catfile/;

use HuGTFS::Util qw/hms burp/;
use HuGTFS::Crawler;

use Mouse;

with 'HuGTFS::FeedManagerConvert';

extends 'HuGTFS::FeedManager::YaGTFS';
__PACKAGE__->meta->make_immutable;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

my %cities = (
	qw/9 zalaegerszeg/,
	qw/10 heviz/,
	qw/11 keszthely/,
	qw/12 lenti/,
	qw/13 letenye/,
	qw/14 nagykanizsa/,
	qw/15 zalakaros/,
	qw/16 zalalovo/,
	qw/17 zalaszentgrot/,
);

=head2 download

=cut

override 'download' => sub {
	my $self = shift;

	return HuGTFS::Crawler->crawl(
		['http://www.zalavolan.hu/zalavolan/menetrend'],
		$self->data_directory, \&crawl_city, \&cleanup,
		{ sleep => 0, name_file => \&name_files, proxy => 0, },
	);
};

=head3 crawl_city

=cut

sub crawl_city
{
	my ( $content, $mech, $url ) = @_;

	return ( [ $mech->find_all_links( url_abs_regex => qr{^$url/\d+$} ) ],
		undef, \&crawl_routes, \&cleanup, );
}

=head3 crawl_routes

=cut

sub crawl_routes
{
	my ( $content, $mech, $url ) = @_;

	return ( [ $mech->find_all_links( url_abs_regex => qr{^$url/\d+$} ) ],
		undef, undef, \&cleanup, );
}

=head3 cleanup

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;

	$content =~ s{<head>}{<head>\n<base href="http://www.zalavolan.hu/" />}go;
	$content =~ s{<div id="fejlec">.*?\n   </div>}{}gosm;
	$content =~ s{<ul class='tabs primary'>.*?</ul>}{}gosm;
	$content =~ s{<div id="jobbsav">.*?</div><!-- /sidebar-first -->}{}gosm;

	return $content;
}

=head3 name_files

=cut

sub name_files
{
	my ( $url, $file ) = shift;

	if ( $url =~ m{menetrend$} ) {
		return "index.html";
	}

	if ( $url =~ m{menetrend/(\d+)$} ) {
		return "city-$cities{$1}.html";
	}

	if ( $url =~ m{menetrend/(\d+)/(\d+)$} ) {
		return "city-$cities{$1}-$2.html";
	}

	return undef;
}

=head3

=cut

sub convert {
	my ( $self, %params ) = @_;

	my $glob   = $params{selective};

	my $twig = XML::Twig->new( discard_spaces => 1 );
	$twig->set_pretty_print('indented');

	my @files = sort glob( catfile( $self->data_directory, ( $glob || 'city-*-*.html' ) ) );
	foreach my $file (@files) {
		$log->info("Parsing file: $file");

		{
			open( my $tfile, '<:utf8', $file );
			$twig->parse_html($tfile);
		}

		my @data;
		my ($city, $route_num) = ($file =~ m/-(.*?)-(\d+)/);

		my $table = $twig->get_xpath("//table/tbody[0]", 0);
		my ( $route_colspan, $stop_col, $route_start, $broute_start, $has_routes )
			= ( $table->get_xpath( 'tr[1]/td[string()=~/Menetidő/]', 0 )->att('colspan') || 1,
			    get_colspanned_index($table->get_xpath( 'tr[1]/td[string()=~/Megállóhelyek/]', 0 ) ),
			    get_colspanned_index($table->get_xpath( 'tr[1]/td[string()=~/Menetidő/]', 0 ) ) - 1,
			    get_colspanned_index($table->get_xpath( 'tr[1]/td[string()=~/Menetidő/]', 1 ) ) - 1,
			);

		if($table->get_xpath( 'tr[1]/td[string()=~/Menetidő/]',  0 )->att('colspan')) {
			$has_routes = 1;
		} else {
			$has_routes = 0;
		}

		for my $index (1 .. $route_colspan) {
			my ($route, $forward_trip, $backward_trip);

			my $route_short_name;
			if($has_routes) {
				my $i = $route_start + $index;
				$i-- if $route_start >= $stop_col;
				$route_short_name = $table->get_xpath("tr[2]/td[$i]", 0)->trimmed_text;
			} elsif($twig->get_xpath('//h5[@style=~/center/i and string()=~/”/]', 0)) {
				$route_short_name = $twig->get_xpath('//h5[@style=~/center/i  and string()=~/”/]', 0)->trimmed_text;
				$route_short_name =~ s/^.*„(.*)”$/$1/;
			} elsif($twig->get_xpath('//h1[@style=~/center/i]//b[string()=~/”/]', 0)) {
				$route_short_name = $twig->get_xpath('//h1[@style=~/center/i]//b', 0)->parent('h1')->trimmed_text;
				$route_short_name =~ s/^.*„(.*)”$/$1/;
			} else {
				$route_short_name = $twig->get_xpath('//p[@align=~/center/i or @style=~/center/]//b', 0)->parent('p')->trimmed_text;
				$route_short_name =~ s/^.*„(.*)”$/$1/;
			}

			{
				$forward_trip = {
					trip_id => "ZALA-VOLAN-" . uc($city) . "-$route_short_name-outbound",
					service_id => 'NAPONTA',
					direction_id => 'outbound',
					stop_times => [],
					departures => [],
				};
				my @minutes = $twig->get_xpath("//table/tbody[2]/tr/td[" . ($route_start + $index ) ."]");
				for (@minutes) {
					my $m = $_->trimmed_text;
					next unless length $m && $m =~ /^\d+$/;

					my $name = $twig->get_xpath("//table/tbody[2]/tr[" . ($_->parent->pos) . "]/td[$stop_col]", 0)->trimmed_text;
					push $forward_trip->{stop_times}, [hms(0, $m, 0), get_name($name)];
				}
			}

			if($table->get_xpath("//table/tbody[2]/tr/td[" . ($broute_start + $index) . "]", 0)) {
				$backward_trip = {
					trip_id => "ZALA-VOLAN-" . uc($city) . "-$route_short_name-inbound",
					service_id => 'NAPONTA',
					direction_id => 'inbound',
					stop_times => [],
					departures => [],
				};
				my @minutes = $twig->get_xpath("//table/tbody[2]/tr/td[" . ($broute_start + $index) . "]");
				for (reverse @minutes) {
					my $m = $_->trimmed_text;
					next unless length $m && $m =~ /^\d+$/;

					my $name = $twig->get_xpath("//table/tbody[2]/tr[" . ($_->parent->pos) . "]/td[$stop_col]", 0)->trimmed_text;
					push $backward_trip->{stop_times}, [hms(0, $m, 0), get_name($name)];
				}
			}

			$route = {
				route_id => "ZALA-VOLAN-" . uc($city) . "-$route_short_name",
				agency_id => "ZALA-VOLAN-" . uc($city),
				route_short_name => $route_short_name,
				route_type => 'bus',
				route_url => 'http://zalavolan.hu/...',
				trips => [$forward_trip, $backward_trip ? ($backward_trip) : ()],
			};

			push @data, $route;
		}

		my $yaml_file = "route_$city";
		foreach (@data) {
			$yaml_file .= "-$_->{route_short_name}";
		}
		$yaml_file .= '.yml';

		burp( catfile( $self->timetable_directory, $yaml_file), YAML::Dump( @data ) );
		$log->info("Wrote YAML file: $yaml_file");
	}
}

sub get_colspanned_index {
	my $x = shift;
	return 0 unless $x;

	my $pos = $x->pos;

	$x = $x->prev_sibling;
	while($x) {
		$pos += -1 + $x->att('colspan') if $x->att('colspan');
		$x = $x->prev_sibling;
	}

	return $pos;
}

sub get_name {
#<<<
	state $map = {
		"1.sz. posta"                        => "1.sz. posta",
		"1.sz. Posta"                        => "1.sz. posta",
		"7.sz. főközl. út – Petőfi út sarok" => "7.sz. fő út – Petőfi út sarok",
		"Ady Endre út 39-40."                => "Ady Endre út 39-40.",
		"Ady u. 39-40."                      => "Ady Endre út 39-40.",
		"Attila u. – Rózsa u."               => "Attila utca – Rózsa utca sarok",
		"Attila utca – Rózsa utca"           => "Attila utca – Rózsa utca sarok",
		"Bagolai elág."                      => "Bagolai elágazás",
		"Bagolasánc, Szeszf."                => "Bagolasánc, Szeszfőzde",
		"Bajcsai u. 31-46."                  => "Bajcsai utca 31-46.",
		"Bajcsa, sz.bolt"                    => "Bajcsa, szövetkezeti bolt",
		"Bajcsa, tsz. gépműhely"             => "Bajcsa, takarékszövetkezet gépműhely",
		"Bajcsa, Tsz-telep"                  => "Bajcsa, takarékszövetkezet-telep",
		"Bajcsay utca 31-46."                => "Bajcsay utca 31-46.",
		"Bajcsy-Zsilinszki út 13."           => "Bajcsy-Zsilinszky út 13.",
		"Bajcsy Zsilinszky út 13."           => "Bajcsy-Zsilinszky út 13.",
		"Bajcsy-Zsilinszky út 13."           => "Bajcsy-Zsilinszky út 13.",
		"Bajcsy-Zs. U. 13."                  => "Bajcsy-Zsilinszky út 13.",
		"Csengery – Kisfaludy u. s."         => "Csengery utca – Kisfaludy utca sarok",
		"Csengery u. 55-58."                 => "Csengery utca 55-58.",
		"Csengery út 55-58."                 => "Csengery utca 55-58.",
		"Csengery u. 86."                    => "Csengery utca 86.",
		"Csengery út – Kisfaludy u. sarok"   => "Csengery utca – Kisfaludy utca sarok",
		"Csónakázó-tó bej. út"               => "Csónakázó-tó bejárati út",
		"Deák tér"                           => "Deák tér",
		"DEÁK-tér"                           => "Deák tér",
		"DOMUS bej. út"                      => "DOMUS bejárati út",
		"Hevesi ABC"                         => "Hevesi Sándor utcai ABC",
		"Hevesi S. úti ABC"                  => "Hevesi Sándor utcai ABC",
		"Hevesi u. - Bartók Béla u. sarok"   => "Hevesi Sándor utca - Bartók Béla utca sarok",
		"Hevesi u. – Bartók u. sarok"        => "Hevesi Sándor utca – Bartók Béla utca sarok",
		"Homokkomáromi u., ford."            => "Homokkomáromi utca, forduló",
		"Kalmár u."                          => "Kalmár utca",
		"Király P. u. sarok"                 => "Király Pál utca sarok",
		"Kisfaludy – Batthyány sarok"        => "Kisfaludy utca – Batthyány utca sarok",
		"Kisfaludy – Batthyány u. sarok"     => "Kisfaludy utca – Batthyány utca sarok",
		"Kisfaludy – Csengery u. sarok"      => "Kisfaludy utca – Csengery utca sarok",
		"Kiskanizsa temető"                  => "Kiskanizsa, temető",
		"Kisrácz út"                         => "Kisrác út",
		"Kisrác Óvoda"                       => "Kisrác, óvoda",
		"Kisrácz óvoda"                      => "Kisrác, óvoda",
		"Kórház u."                          => "Kórház utca",
		"Magyar u. 60."                      => "Magyar utca 60.",
		"Magyar út 60."                      => "Magyar utca 60.",
		"Marek J. u."                        => "Marek József utca",
		"Miklósfa Óvoda"                     => "Miklósfa, óvoda",
		"Miklósfa ABC"                       => "Miklósfa, ABC",
		"Nagyrác forduló"                    => "Nagyrác, forduló",
		"Nagyrác Iskola"                     => "Nagyrác, iskola",
		"Nagyrácz forduló"                   => "Nagyrác, forduló",
		"Nagyrácz Iskola"                    => "Nagyrác, iskola",
		"PALIN, ÁG."                         => "Palin, államigazdaság",
		"Palin, Lakótelepi bej. út"          => "Palin, Lakótelepi bejárati út",
		"Palin, Magvető utca"                => "Palin, Magvető utca",
		"Palin, Új lakótelep"                => "Palin, Új lakótelep",
		"Petőfi – Honvéd u. sarok"           => "Petőfi utca – Honvéd utca sarok",
		"Petőfi u. – Honvéd u. sarok"        => "Petőfi utca – Honvéd utca sarok",
		"Petőfi u. Víztorony"                => "Petőfi utca – Víztorony",
		"Rozgonyi u. 1."                     => "Rozgonyi utca 1.",
		"Rozmaring utca"                     => "Rozmaring utca",
		"Rózsa u."                           => "Rózsa utca",
		"Rózsa u. 1-2."                      => "Rózsa utca 1-2.",
		"Sánc óvoda"                         => "Sánc, óvoda",
		"Sánc Temető"                        => "Sánc, temető",
		"STOP.SHOP"                          => "STOP.SHOP",
		"Szentendrey Edgár u."               => "Szentendrey Edgár utca",
		"Teleki u. Kórház bej.u."            => "Teleki utca – Kórház bejárati út",
		"Teleki u. kórház bej. út"           => "Teleki utca – Kórház bejárati út",
		"Teleki u. Kórház bej. út"           => "Teleki utca – Kórház bejárati út",
		"Teleki úti Víztorony"               => "Teleki utca – Víztorony",
		"Teleki út, Kórház bej. út"          => "Teleki utca – Kórház bejárati út",
		"Teleki u. Víztorony"                => "Teleki utca – Víztorony",
		"Templomtér"                         => "Templom tér",
		"Templom tér"                        => "Templom tér",
		"Vörösmarty u. sarok"                => "Vörösmarty utca sarok",
	};
#>>>

	my $name = shift;

	return $map->{$name} || $name;
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut


