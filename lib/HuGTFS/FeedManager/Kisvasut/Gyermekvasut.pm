
=head1 NAME

HuGTFS::FeedManager::Kisvasut::Gyermekyvasut - HuGTFS feed manager for download + parsing Gyermekvasut data

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Kisvasut::Gyermekvasut;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Kisvasut::Gyermekvasut;

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
		['http://www.gyermekvasut.hu/timetable.php'],
		$self->data_directory, \&crawl_days, \&cleanup,
		{ sleep => 5, name_file => \&name_files, proxy => 1, },
	);
}

=head3 cleanup

=cut

sub cleanup
{
	my ( $content, $mech, $url ) = @_;

	$content =~ s/^\s*//;

	$content =~ s{charset=windows-1250}{charset=UTF-8};
	$content =~ s/\x{a0}/ /g;
	$content =~ s/&nbsp;/ /g;

	$content =~ s{(["'])/menetrend/(.*?)\1}{$1trip_$2$1}g;
	$content =~ s{(["'])/timetable\.php\?(\d{4}-\d{2}-\d{2})\1}{$1nap_$2.html$1}g;
	$content =~ s{SyncWithServerTime\('\d+'\);}{}g;

	return $content;
}

=head3 crawl_days

=cut

sub crawl_days
{
	my ( $content, $mech, $url ) = @_;

	return (
		[
			$mech->find_all_links(
				url_abs_regex => qr{^http://www\.gyermekvasut\.hu/timetable\.php\?}
			)
		],
		undef,
		\&crawl_trips,
		\&cleanup,
	);
}

=head3 crawl_trips

=cut

sub crawl_trips
{
	my ( $content, $mech, $url ) = @_;

	return (
		[
			map { $_->url_abs } $mech->find_all_images(
				url_abs_regex =>
					qr{^http://www\.gyermekvasut\.hu/menetrend/\d+-\d+(?:-\d)?\.(?:gif|png)$}
			)
		],
		undef, undef, undef,
	);
}

=head3 name_files

=cut

sub name_files
{
	my ( $url, $file ) = shift;

	if ( $url =~ m{\?(.+?)$} ) {
		return "nap_$1.html";
	}

	if ( $url =~ m{(\d+-\d+(?:-\d)?)\.(gif|png)$} ) {
		return "trip_$1.$2";
	}

	if ( $url =~ m{timetable\.php$} ) {
		return "timetable.html";
	}

	return undef;
}

=head2 parse

=cut

sub parse
{
	my $self = shift;

	my $AGENCY = {
		agency_id       => 'gyermekvasut',
		agency_phone    => '+36 (1) 397 5394',
		agency_lang     => 'hu',
		agency_name     => 'MÁV Zrt. Széchenyi-hegyi Gyermekvasút',
		agency_url      => 'http://www.gyermekvasut.hu',
		agency_timezone => 'Europe/Budapest',
		routes          => [
			{
				route_id         => 'SZ',
				route_short_name => '7',
				route_long_name  => 'Gyermekvasút (személyvonat)',
				route_desc       => 'Széchenyi-hegy / Hűvösvölgy',
				route_type       => 'narrow_gauge',
			},
			{
				route_id         => 'NSZG',
				route_short_name => '7',
				route_long_name  => 'Gyermekvasút (gőzvontatású nosztalgiavonat)',
				route_desc       => 'Széchenyi-hegy / Hűvösvölgy',
				route_type       => 'narrow_gauge',
			},
			{
				route_id         => 'NSZM',
				route_short_name => '7',
				route_long_name  => 'Gyermekvasút (nosztalgia motorvonat)',
				route_desc       => 'Széchenyi-hegy / Hűvösvölgy',
				route_type       => 'narrow_gauge',
			},
		],
		fares => [
			{
				fare_id        => 'FELNOTT_SZAKASZ',
				price          => 500,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'SZ',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'SZ',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'SZ',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'GYERMEK_SZAKASZ',
				price          => 300,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'SZ',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'SZ',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'SZ',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'FELNOTT_VONAL',
				price          => 700,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'SZ',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'GYERMEK_VONAL',
				price          => 350,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'SZ',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'NSZG_FELNOTT_SZAKASZ',
				price          => 700,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'NSZG',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZG',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZG',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'NSZG_GYERMEK_SZAKASZ',
				price          => 400,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'NSZG',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZG',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZG',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'VONAL',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'SZAKASZ',
						destination_id => 'SZAKASZ',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'NSZG_FELNOTT_VONAL',
				price          => 900,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'NSZG',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
			{
				fare_id        => 'NSZG_GYERMEK_VONAL',
				price          => 450,
				currency_type  => 'HUF',
				payment_method => 'onboard',
				transfers      => 0,
				rules          => [
					{
						route_id       => 'NSZG',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
					{
						route_id       => 'NSZM',
						origin_id      => 'VONAL',
						contains_id    => 'SZAKASZ',
						destination_id => 'VONAL',
					},
				],
			},
		],
	};

	my %TRIPS = ();
	my ( undef, $tmpfile )
		= tempfile( 'hugtfs-XXXXX', OPEN => 0, SUFFIX => '.png', DIR => tmpdir() );

	HuGTFS::Cal->empty();

	$log->info("Parsing trips...");
	foreach my $img ( glob( catfile( $self->data_directory, '*.png' ) ) ) {
		my ( $somenum, $trip_short_name, $route_id ) = $img =~ m/(\d+)-(\d+)(?:-(\d))?/;
		next if $somenum eq '035';    # Kisvasuti napi különvonat

		$route_id = 'SZ' unless $route_id;
		$route_id = 'NSZG' if $route_id eq 1;
		$route_id = 'NSZM' if $route_id eq 2;

		$log->debug("Parsing $img: $route_id $trip_short_name");

		my $trip = {
			route_id        => $route_id,
			service_id      => undef,
			trip_id         => "T_$route_id-$somenum-$trip_short_name",
			trip_headsign   => undef,
			trip_short_name => $trip_short_name,
			direction_id    => ( $trip_short_name % 2 == 1 ? 'outbound' : 'inbound' ),
		};
		$TRIPS{ $trip->{trip_id} } = $trip;

		my $service = HuGTFS::Cal->new(
			service_id => "S_$trip->{trip_id}",
			start_date => DateTime->now,
			end_date   => DateTime->now,
		);
		$trip->{service_id} = $service->service_id;

		$trip->{stop_times} = [];
		my @stops = (
#<<<
			[ 'Széchenyi-hegy', 0 ],
			[ 'Normafa',        1 ],
			[ 'Csillebérc',     2 ],
			[ 'Virágvölgy',     3 ],
			[ 'János-hegy',     5 ],
			[ 'Vadaspark',      6 ],
			[ 'Szépjuhászné',   7 ],
			[ 'Hárs-hegy',      9 ],
			[ 'Hűvösvölgy',    12 ],
#>>>
		);
		if ( $trip->{direction_id} eq 'outbound' ) {
			@stops = map { $_->[1] = 12 - $_->[1]; $_ } reverse @stops;
		}

		$trip->{trip_headsign} = $stops[-1]->[0];

		`convert '$img' -crop '40x256+0+70!' -crop '40x151+0+0!' '$tmpfile'`;
		my @data = split /\n/, `gocr -l 200 -s 9 -C '0123456789:I ' '$tmpfile'`;

		for (@stops) {
			my $time = shift @data;
			next if $time =~ m/I/;
			$time =~ s/ /:/g;
			$log->errordie("OCR failed: $trip->{trip_id}, $time") if $time =~ m/_/;

			push @{ $trip->{stop_times} },
				{
				stop_name           => $_->[0],
				shape_dist_traveled => $_->[1],
				stop_sequence       => $_->[1],
				departure_time      => $time,
				arrival_time        => $time,
				stop_zone => ( $_->[0] =~ m/Széchenyi|Hűvösvölgy/ ? 'VONAL' : 'SZAKASZ' ),
				};
		}
	}

	unlink($tmpfile);

	my $twig = XML::Twig->new(
		discard_spaces => 1,
		twig_roots     => { 'img[@src=~/trip_.*\\.png/]' => 1, }
	);

	$log->info("Parsing days...");
	foreach my $file ( glob( catfile( $self->data_directory, 'nap_*-*-*.html' ) ) ) {
		$file =~ m/_(\d+)-(\d+)-(\d+)\.html/;
		my $date = DateTime->new( year => $1, month => $2, day => $3 );

		$log->debug("Parsing $file");

		$twig->parse_html(slurp $file);

		foreach my $trip_img ( $twig->get_xpath('img') ) {
			my ( $somenum, $trip_short_name, $route_id )
				= $trip_img->att('src') =~ m/(\d+)-(\d+)(?:-(\d))?\.(?:png|gif)$/;
			next if $somenum eq '035';    # Kisvasuti napi különvonat

			$route_id = 'SZ' unless $route_id;
			$route_id = 'NSZG' if $route_id eq 1;
			$route_id = 'NSZM' if $route_id eq 2;

			my $trip = $TRIPS{"T_$route_id-$somenum-$trip_short_name"};
			HuGTFS::Cal->find( $trip->{service_id} )->add_exception( $date, 'added' );
		}
	}

	my $osm_data = HuGTFS::OSMMerger->parse_osm( "MÁV", $self->osm_file );
	my $data = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
			trip_line_variants  => sub {
				$osm_data->{shapes}->{train}->{7}
					? @{ $osm_data->{shapes}->{train}->{7} }
					: ();
			},
		},
		$osm_data,
		{ trips => [ values %TRIPS ], routes => $AGENCY->{routes}, },
	);

	my $dumper = HuGTFS::Dumper->new( dir => $self->gtfs_directory );
	$dumper->clean_dir;

	$dumper->dump_agency($AGENCY);

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
