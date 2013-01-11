#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  util/gtfs-yaml.pl
#
#        USAGE:  ./gtfs-yaml.pl
#
#  DESCRIPTION:  Converts gtfs CSV timetables to a look-alike YAML format
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  Szeged specific for now.
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  08/23/2011 08:49:35 AM
#     REVISION:  ---
#===============================================================================

use 5.10.0;
use utf8;
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use YAML qw//;
use Data::Dumper;
use Text::CSV::Encoded;
use HuGTFS::Util qw/burp remove_bom _S _T/;

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
	}
);

my $DIR    = './tmp';
my $RES_SZ = './szkt/timetables/';
my $RES_TV = './tisza_volan/timetables/';

my $file;

my $agencies;
open( $file, "$DIR/agency.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	given ( $cols->{agency_id} ) {
		when ("1") {
			$cols->{agency_id} = 'Tisza Volan';
		}
		when ("2") {
			$cols->{agency_id} = 'SZKT';
		}
	}

	$agencies->{ $cols->{agency_id} } = $cols;
}

burp( "$RES_SZ/agency.yml", <<EOF );
---
agency_id: SZKT
agency_name: SZKT
agency_phone: +36-80-820-500
agency_lang: hu
agency_timezone: Europe/Budapest
agency_url: http://www.szkt.hu
EOF

burp( "$RES_TV/agency.yml", <<EOF );
---
agency_id: Tisza Volan
agency_name: Tisza Volán Zrt.
agency_phone: +36-40-828-000
agency_lang: hu
agency_timezone: Europe/Budapest
agency_url: http://www.tiszavolan.hu
EOF

my ($services);

open( $file, "$DIR/calendar.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$services->{ $cols->{service_id} } = $cols;
}

open( $file, "$DIR/calendar_dates.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$cols->{exception_type} = $cols->{exception_type} eq '1' ? 'added' : 'removed';
	push @{ $services->{ $cols->{service_id} }->{exceptions} }, $cols;

	delete $cols->{service_id};
}

my $cal_text = '';
foreach my $s ( sort { $a->{service_id} cmp $b->{service_id} } values %$services ) {
	$cal_text .= <<EOF;
---
service_id: $s->{service_id}
start_date: $s->{start_date}
end_date:   $s->{end_date}
monday:     $s->{monday}
tuesday:    $s->{tuesday}
wednesday:  $s->{wednesday}
thursday:   $s->{thursday}
friday:     $s->{friday}
saturday:   $s->{saturday}
sunday:     $s->{sunday}
EOF

	if($s->{exceptions}) {

		$s->{exceptions} = [ sort { $a->{date} <=> $b->{date} } @{ $s->{exceptions} } ];

		$cal_text .= <<EOF;
exceptions:
EOF
		for (@{$s->{exceptions}}) {
			$cal_text .= <<EOF;
  - date:           $_->{date}
    exception_type: $_->{exception_type}
EOF
		}
	}
}

burp( "$RES_SZ/calendar.yml", $cal_text );
burp( "$RES_TV/calendar.yml", $cal_text );

my ( $routes, $trips, $stops, $patterns );

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$routes->{ $cols->{route_id} } = $cols;

	given ( $cols->{agency_id} ) {
		when ("1") {
			$cols->{agency_id} = 'Tisza Volan';
		}
		when ("2") {
			$cols->{agency_id} = 'SZKT';
		}
	}

	given ( $cols->{route_type} ) {
		when ("0") {
			$cols->{route_type} = 'tram';
		}
		when ("3") {
			if ( $cols->{agency_id} eq "SZKT" && $cols->{route_short_name} !~ m/V/ ) {
				$cols->{route_type} = 'trolleybus';
			}
			else {
				$cols->{route_type} = 'bus';
			}
		}
	}

	$cols->{trips} = [];

	delete $cols->{route_url}       unless $cols->{route_url};
	delete $cols->{route_long_name} unless $cols->{route_long_name};
}

open( $file, "$DIR/stops.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$stops->{ $cols->{stop_id} } = $cols;
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$trips->{ $cols->{trip_id} } = $cols;
}

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	push @{ $trips->{ $cols->{trip_id} }->{stop_times} }, $cols;

	delete $cols->{trip_id};
	delete $cols->{shape_dist_traveled};

	delete $cols->{pickup_type}  unless $cols->{pickup_type};

	delete $cols->{drop_off_type} unless $cols->{stop_sequence};
	delete $cols->{drop_off_type} unless $cols->{drop_off_type};
}

foreach my $t ( values %$trips ) {
	$t->{stop_times}
		= [ sort { $a->{stop_sequence} <=> $b->{stop_sequence} } @{ $t->{stop_times} } ];

	my $p = "$t->{route_id}|$t->{service_id}|";
	my $prev;
	foreach my $st ( @{ $t->{stop_times} } ) {
		$prev ||= _S( $st->{arrival_time} );
		$p .= "$st->{stop_id},";
		$p .= ( _S( $st->{arrival_time} ) - $prev );
		$p .= ',';
		$p .= ( _S( $st->{departure_time} ) - _S( $st->{arrival_time} ) );
		$p .= '|';

		$st->{stop_name} = $stops->{ $st->{stop_id} }->{stop_name};
		$st->{stop_code} = $stops->{ $st->{stop_id} }->{stop_code} || $st->{stop_id};

		$prev = _S( $st->{departure_time} );

		if ( $st->{arrival_time} eq $st->{departure_time} ) {
			$st->{stop_time} = $st->{arrival_time};
			delete $st->{arrival_time};
			delete $st->{departure_time};
		}

		delete $st->{stop_id};
		delete $st->{stop_sequence};
	}

	push @{ $patterns->{$p} }, $t;
}

foreach my $p ( keys %$patterns ) {
	my $exemplar = $patterns->{$p}[0];

	$exemplar->{departures} = [];
	for ( @{ $patterns->{$p} } ) {
		push @{ $exemplar->{departures} }, ($_->{stop_times}[0]{arrival_time} || $_->{stop_times}[0]{stop_time});
		delete $trips->{ $_->{trip_id} };
	}

	$exemplar->{departures} = [ sort { _S($a) <=> _S($b) } @{ $exemplar->{departures} } ];
	$exemplar->{direction_id} = $exemplar->{direction_id} ? 'inbound' : 'outbound';

	push @{ $routes->{ $exemplar->{route_id} }->{trips} }, $exemplar;
	delete $exemplar->{route_id};
}

delete $_->{route_id} foreach ( values %$trips );

foreach my $r ( values %$routes ) {
	my $text = <<EOF;
---
route_id:         $r->{route_id}
agency_id:        $r->{agency_id}
route_type:       $r->{route_type}
route_short_name: $r->{route_short_name}
route_color:      $r->{route_color}
route_text_color: $r->{route_text_color}
trips:
EOF
	foreach my $t (sort {$a->{trip_id} cmp $b->{trip_id} } @{$r->{trips}}) {
		my $d = join ', ', @{$t->{departures}};

		$text .= <<EOF;
  - trip_id:       $t->{trip_id}
    service_id:    $t->{service_id}
    trip_headsign: $t->{trip_headsign}
    direction_id:  $t->{direction_id}
    departures: [$d]
    stop_times: 
EOF

		my $base = _S($t->{stop_times}[0]{stop_time} || $t->{stop_times}[0]{arrival_time});
		foreach (@{$t->{stop_times}}) {
			$text .= <<EOF;
      - stop_name: $_->{stop_name}
        stop_code: $_->{stop_code}
EOF

			if($_->{stop_time}) {
				$_->{stop_time} = _T(_S($_->{stop_time}) - $base);
				$text .= <<EOF;
        stop_time: $_->{stop_time}
EOF
			} else {
				$_->{arrival_time} = _T(_S($_->{arrival_time}) - $base);
				$_->{stop_time} = _T(_S($_->{stop_time}) - $base);
				$text .= <<EOF;
        arrival_time:   $_->{arrival_time}
        departure_time: $_->{departure_time}
EOF
			}
		}
	}

	if ( $r->{agency_id} eq 'SZKT' ) {
		burp( "$RES_SZ/route_$r->{route_type}_$r->{route_short_name}.yml", $text );
	}
	else {
		burp( "$RES_TV/route_$r->{route_type}_$r->{route_short_name}.yml", $text );
	}
}

