#!/usr/bin/env perl
#===============================================================================
#
#         FILE:  check_patterns.pl
#
#        USAGE:  ./check_patterns.pl
#
#  DESCRIPTION:
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (),
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  03/15/2013 06:46:07 PM
#     REVISION:  ---
#===============================================================================

use 5.10.0;
use utf8;
use strict;
use warnings;

use autodie;

my ($DIR) = (shift);

binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

use Data::Dumper;
use Text::CSV::Encoded;

use List::MoreUtils qw/none/;
use XML::Twig;
use Data::Dumper;

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
	}
);

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

my ( $file, $routes, $trips, $stops );

my $needed = { map { $_ => 1 } @ARGV };
my $skip = {};

say STDERR "Loading data...";

open( $file, "$DIR/routes.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$routes->{ $cols->{route_id} } = {%$cols};
}

open( $file, "$DIR/trips.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my ( $route, $id ) = ( $cols->{route_id}, $cols->{trip_id} );

	$trips->{$id} = {%$cols};
	push @{ $routes->{$route}->{trips} }, $trips->{$id};
}

open( $file, "$DIR/stop_times.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	my $trip = $trips->{ $cols->{trip_id} };

	push @{ $trip->{stop_times} }, {%$cols};
}

open( $file, "$DIR/stops.txt" );
$CSV->column_names( remove_bom $CSV->getline($file) );
while ( my $cols = $CSV->getline_hr($file) ) {
	$stops->{ $cols->{stop_id} } = {%$cols};
}

say STDERR "Creating patterns...";

foreach my $trip ( values %$trips ) {
	my $route = $routes->{ $trip->{route_id} };
	my $pattern = join '-', map { $_->{stop_id} } @{ $trip->{stop_times} };

	push @{ $route->{patterns}->{ $trip->{direction_id} }->{$pattern} }, $trip;
}

say STDERR "Comparing patterns...";

# returns the lowest weight match (weight = stops inbetween)
sub common_stop(\@$\@$)
{
	my @a = @{ (shift) };
	my $a = shift;
	my @b = @{ (shift) };
	my $b = shift;

	my ( %a, %b );
	for ( my $i = $a; $i <= $#a; ++$i ) {
		$a{ $a[$i] } = $i unless defined $a{ $a[$i] };
	}
	for ( my $j = $b; $j <= $#b; ++$j ) {
		$b{ $b[$j] } = $j unless defined $b{ $b[$j] };
	}

	my ( $min, $ma, $mb ) = ( 9999999999, undef, undef );
	foreach ( keys %a ) {
		next unless defined $b{$_};

		my $s = ( $a{$_} - $a ) + ( $b{$_} - $b );
		if ( $s < $min || ( $s == $min && $a{$_} < $ma ) ) {
			( $min, $ma, $mb ) = ( $s, $a{$_}, $b{$_} );
		}
	}

	return ( $ma, $mb );
}

foreach my $route ( sort { $a->{route_id} cmp $b->{route_id} } values %$routes ) {
	next if $route->{route_id} =~ m/^(?:0337|[569]...)$/;

	# split
=pod
	next
		if $route->{route_id}
		=~ m/^(?:0440|0540|0550|0665|0975|1041|1160|1310|1640|1660|1885|1961|2040|2300|2500|2620|2765|2810|2945)$/;
	next if $route->{route_id} =~ m/^(?:0405|0945|2015|2170|2335|2545)$/;
	next if $route->{route_id} =~ m/^(?:0895)$/;
=cut

	foreach my $dir ( sort keys %{ $route->{patterns} } ) {
		if ( scalar values %{ $route->{patterns}->{$dir} } > 1 ) {
			say "$route->{route_id}-$dir: " . scalar values %{ $route->{patterns}->{$dir} };

			my $patterns = {
				map { $_ => scalar( @{ $route->{patterns}->{$dir}->{$_} } ) }
					keys %{ $route->{patterns}->{$dir} }
			};

			my ( $master, $second )
				= ( sort { $patterns->{$b} <=> $patterns->{$a} } keys %$patterns )[ 0, 1 ];
			if ( $patterns->{$master} < 2 * $patterns->{$second} ) {
				say "\tSMALLDIFF ("
					. ( $patterns->{$master} - $patterns->{$second} ) . ", "
					. ( $patterns->{$second} / $patterns->{$master} ) . ")";
			}

			foreach my $p (sort { $patterns->{$b} <=> $patterns->{$a} } keys %$patterns ) {
				my @a = split /-/, $master;
				my @b = split /-/, $p;

=pod
				say "\t"
					. $stops->{ $b[0] }->{stop_name} . " -> "
					. $stops->{ $b[-1] }->{stop_name} . ", "
					. scalar @b
					. " megálló, "
					. $patterns->{$p}
					. " járat";
=cut

				if ( $p eq $master ) {
					say "\t- master: [" . ( join ", ", @b ) . "]";
					next;
				}
				next;

				my @modifiers = ();

				my ( $i, $j ) = ( 0, 0 );
				while ( $i <= $#a && $j <= $#b ) {
					if ( $a[$i] ne $b[$j] ) {
						my ( $na, $nb ) = common_stop( @a, $i, @b, $j );
						unless ( defined $na && defined $nb ) {
							if ( $i == 0 ) {
								push @modifiers,
									{
									from    => undef,
									to      => undef,
									skipped => [@a],
									visited => [@b]
									};
							}
							else {
								push @modifiers,
									{
									from    => $a[ $i - 1 ],
									to      => undef,
									skipped => [ @a[ $i .. $#a ] ],
									visited => [ @b[ $j .. $#b ] ]
									};
							}
							last;
						}
						elsif ( $i == 0 ) {
							push @modifiers,
								{
								from    => undef,
								to      => $a[$na],
								skipped => [ @a[ $i .. $na - 1 ] ],
								visited => [ @b[ $j .. $nb - 1 ] ]
								};
						}
						else {
							push @modifiers,
								{
								from    => $a[ $i - 1 ],
								to      => $a[$na],
								skipped => [ @a[ $i .. $na - 1 ] ],
								visited => [ @b[ $j .. $nb - 1 ] ]
								};
						}
						( $i, $j ) = ( $na, $nb );
					}
					else {
						( $i++, $j++ );
					}
				}

				if (   $#modifiers == 0
					&& !defined $modifiers[0]->{from}
					&& !defined $modifiers[0]->{to} )
				{
					say "\tNO OVERLAP! ($patterns->{$p})";
				}

=pod
				foreach (@modifiers) {
					say "\t- from:    " . ( defined $_->{from} ? $_->{from} : "~" );
					say "\t  to:      " . ( defined $_->{to}   ? $_->{to}   : "~" );
					say "\t  skipped: [" . ( join ", ", @{ $_->{skipped} } ) . "]";
					say "\t  visited: [" . ( join ", ", @{ $_->{visited} } ) . "]";
				}
=cut
			}
		}
	}
}

