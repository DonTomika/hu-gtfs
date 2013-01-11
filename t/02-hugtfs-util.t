#
#===============================================================================
#
#         FILE:  02-hugtfs-util.t
#
#  DESCRIPTION:
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (),
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  02/09/2011 09:57:59 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;

use Test::More tests => 18;    # last test to print

BEGIN { use_ok( "HuGTFS::Util", ':all' ); }

is( _0(1),  '01', '_0 - 1' );
is( _0(10), '10', '_0 - 2' );

is( _0X(1),  '01', '_0X - 1' );
is( _0X(10), '10', '_0X - 2' );
is( _0X(1.1),  '01.1', '_0X - 3' );
is( _0X(10.1), '10.1', '_0X - 4' );

is( _0D( '10:4' ), '10:04', '_0D' );

# XXX: slurp
# XXX: burp

is( _S('01:01:01'), 60 * 60 + 60 + 1, '_S' );

is( _T( 60 * 60 + 60 + 59 ), '01:01:59', '_T - 1' );
is( _T( 60 * 60 + 60 + 1 ), '01:01:01', '_T - 2' );
is( _TX( 60 * 60 + 60 + 0 ), '01:01:00', '_TX - 1' );
is( _TX( 60 * 60 + 60 + 1.5 ), '01:01:01.5', '_TX - 2' );

is_deeply( [ _D('19910224') ], [qw/year 1991 month 02 day 24/], '_D' );

is( seconds('01:01:01'), 60 * 60 + 60 + 1, '_S' );

is( hms( 1, 61, 61 ), '02:02:01', 'hms' );

is( unaccent('a'), 'a', 'unaccent - 1' );
is( unaccent('öüóőúéáűíÖÜÓŐÚÉÁŰÍ'), 'ouooueauiOUOOUEAUI', 'unaccent - 2' );

#is( entity_id( bless {}, 'Geo::OSM::Way' ), 'way_1', 'entity_id' );
