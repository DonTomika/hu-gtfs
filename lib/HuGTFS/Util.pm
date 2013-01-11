=head1 NAME

HuGTFS::Util - Helper functions used within HuGTFS

=head1 SYNOPSIS

	use HuGTFS::Util;

=head1 REQUIRES

perl 5.14.0, WWW::Mechanize, LWP::ConnCache, Log::Log4perl, Geo::OSM::OsmReaderV6

=head1 EXPORTS

Methods.

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::Util;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Unicode::Normalize qw/NFKD/;

use parent qw/ Exporter /;
our @EXPORT_OK = qw(slurp burp _0 _0X _0D _DH _S _T _TX _D hms seconds unaccent entity_id from_ymd remove_bom);
our %EXPORT_TAGS = (
	utils => [qw(slurp burp _0 _0X _0D _D _DH _S _T _TX hms seconds unaccent entity_id from_ymd remove_bom)] );
$EXPORT_TAGS{all} = ( [ @{ $EXPORT_TAGS{utils} } ] );

=head2 Utils

=head3 _0

Prefixes a 0, if less than 9.

=cut

sub _0($)
{
	defined $_[0]
		? ( int( $_[0] ) < 10 ? '0' . int( $_[0] ) : int( $_[0] ) )
		: $_[0];

}

=head3 _0X

Prefixes a 0, if less than 9. Keeps the fractional part.

=cut

sub _0X($)
{
	defined $_[0]
		? ( int( $_[0] ) < 10 ? '0' . $_[0] : $_[0] )
		: $_[0];
}

=head3 _0D

H:M to HH:MM

=cut

sub _0D($)
{
	my ( $h, $m ) = ( $_[0] =~ m/(\d+)[.:](\d+)/ );

	return _0($h) . ':' . _0($m);
}

=head3 slurp

Slurps a utf-8 file.

=cut

sub slurp($)
{
	open( my $file, '<:encoding(UTF-8)', $_[0] ) or die "Can't open file <$_[0]>: $!";
	local $/ = undef;
	my $data = <$file>;
	close $file;
	return $data;
}

=head3 burp

Writes a utf-8 file.

=cut

sub burp($;$)
{
	open( my $file, '>:encoding(UTF-8)', $_[0] );
	print $file $_[1];
	close $file;
}

=head3 _S

HH:MM:SS to seconds.

=cut

sub _S($)
{
	(shift) =~ m/^(\d\d?):(\d{2})(?::(\d{2}))?$/;
	return ( $1 ? $1 : 0 ) * 60 * 60 + ( $2 ? $2 : 0 ) * 60 + ( $3 ? $3 : 0 );
}

=head3 _T

Seconds to HH:MM:SS.

=cut

sub _T($)
{
	my $s = shift;
	return
		  _0( int( $s / ( 60 * 60 ) ) ) . ":"
		. _0( int( ( $s % ( 60 * 60 ) ) / 60 ) ) . ":"
		. _0( $s % 60 );
}

=head3 _TX

Fractional seconds to HH:MM:SS.SS.

=cut

sub _TX($)
{
	my $s = shift;
	return
		  _0( int( $s / ( 60 * 60 ) ) ) . ":"
		. _0( int( ( $s % ( 60 * 60 ) ) / 60 ) ) . ":"
		. _0X( $s - int( $s / ( 60 * 60 ) ) * 60 * 60 - int( ( $s % ( 60 * 60 ) ) / 60 ) * 60 );
}

=head3 _D

YYYYMMDD to (year => YYYY, month => MM, day => DD).

=cut

sub _D($)
{
	(shift) =~ m/^(\d{4})(\d{2})(\d{2})$/;
	return ( year => $1, month => $2, day => $3 );

}

=head3 _DH

YYYYMMDD to YYYY-MM-DD

=cut

sub _DH($)
{
	(shift) =~ m/^(\d{4})(\d{2})(\d{2})$/;
	return "$1-$2-$3";
}

=head3 seconds

HH:MM:SS to seconds.

=cut

sub seconds
{
	my ( @m, $ret ) = ( 60 * 60, 60, 1 );
	$ret += $_ * shift @m for ( split /:/, shift );
	return $ret;
}

=head3 hms

(int, int, int) to HH:MM:SS;

=cut

sub hms
{
	my ( $h, $m, $s ) = ( (shift) || 0, (shift) || 0, (shift) || 0 );
	$s += 60 * 60 * $h + 60 * $m;

	my $p = int( $s / ( 60 * 60 ) );
	$s -= $p * 60 * 60;

	my $q = int( $s / 60 );
	$s -= $q * 60;

	return _0($p) . ':' . _0($q) . ':' . _0($s);
}

=head2 from_ymd

YYYYMMDD to a DateTime.

=cut

sub from_ymd($)
{
	(shift) =~ m/^(\d{4})(\d{2})(\d{2})$/;
	return DateTime->new( year => $1, month => $2, day => $3 );
}

=head3 unaccent

Converts a utf-8 string to ascii.

=cut

sub unaccent($)
{
	my $s = shift;
	$s = NFKD($s);
	$s =~ s/\pM//og;
	return $s;
}

=head3 entity_id

Return an entity_id for an OSM::{Node,Way,Relation}.

=cut

sub entity_id($)
{
	my $e = shift;

	if ( $e->isa("Geo::OSM::Relation") ) {
		return 'relation_' . $e->id;
	}
	elsif ( $e->isa("Geo::OSM::Way") ) {
		return 'way_' . $e->id;
	}
	elsif ( $e->isa("Geo::OSM::Node") ) {
		return 'node_' . $e->id;
	}
	elsif ( $e->isa("Geo::OSM::Relation::Member") ) {
		return $e->member_type . '_' . $e->ref;
	}
}

=head2 remove_bom

Removes the UTF-8 Byte-Order-Mark (BOM) from a string.

=cut

sub remove_bom(@)
{
	return [ map { s/^\x{feff}//; $_ } @{ $_[0] } ];
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
