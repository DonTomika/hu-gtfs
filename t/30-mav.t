use utf8;
use strict;
use warnings;

use Test::More tests => 36;

BEGIN { use_ok( "HuGTFS::Test", 'is_active', 'is_inactive' ); }
BEGIN { use_ok("HuGTFS::FeedManager::MAV"); }

# XXX download

# XXX parse

# Calendar

HuGTFS::FeedManager::MAV::init_cal();

# Exceptions

is_active( "M_A", 20110111, 'munkanap - 1' );
is_inactive( "M_A", 20110315, 'munkanap - 2' );

is_active( "M_NOT_A", 20110101, '!munkanap - 1' );

is_active( 'M_5', 20110319, 'péntek közlekedési rend - 1' );
is_inactive( 'M_5', 20111028, 'péntek közlekedési rend - 2' );
is_inactive( 'M_7', 20111028, 'vasárnapi közlekedési rend - 1' );

# Combined

is_inactive( 'M_M5_M7', 20110312, 'péntek + vasárnap közlekedési rend - 1' );
is_active( 'M_M5_M7', 20110401, 'péntek + vasárnap közlekedési rend - 2' );
is_inactive( 'M_M5_M7', 20111028, 'péntek + vasárnap közlekedési rend - 3' );
is_inactive( 'M_M5_M7', 20111026, 'péntek + vasárnap közlekedési rend - 3' );

# Antied
is_active( 'M_25', 20111028, 'NEM pénteki közlkedési rend - 1' );
is_inactive( 'M_25', 20110211, 'NEM pénteki közlkedési rend - 2' );

# XXX: run_interval

# XXX: negate_dates

# XXX: parse_dates

# create_service_from_text

sub cr_active($$$)
{
	return is_active( HuGTFS::FeedManager::MAV::create_service_from_text( $_[0] ), $_[1],
		$_[2] );
}

sub cr_active_ex($$$$)
{
	return is_active( HuGTFS::FeedManager::MAV::create_service_from_text( $_[0], @{ $_[1] } ),
		$_[2], $_[3] );
}

sub cr_inactive($$$)
{
	return is_inactive( HuGTFS::FeedManager::MAV::create_service_from_text( $_[0] ), $_[1],
		$_[2] );
}

sub cr_inactive_ex($$$$)
{
	return is_inactive( HuGTFS::FeedManager::MAV::create_service_from_text( $_[0], @{ $_[1] } ),
		$_[2], $_[3] );
}

cr_active( "csütörtök", 20110210, 'cr: csütörtök' );
cr_inactive_ex( "csütörtök", [20110210], 20110210, 'cr: csütürtök - ex' );

cr_active( 'szombat, valamint 2010.XII.24, 31, 2011.IV.22',
	20110212, 'szombat, valamint 2010.XII.24, 31, 2011.IV.22 - 1' );
cr_active( 'szombat, valamint 2010.XII.24, 31, 2011.IV.22',
	20101231, 'szombat, valamint 2010.XII.24, 31, 2011.IV.22 - 2' );

cr_inactive( 'naponta, de nem közlekedik 2010.XII.27-től 31-ig',
	20100127, 'naponta, de nem közlekedik 2010.XII.27-től 31-ig - 1' );
cr_inactive( 'naponta, de nem közlekedik 2010.XII.27-től 31-ig',
	20100131, 'naponta, de nem közlekedik 2010.XII.27-től 31-ig - 2' );
cr_active( 'naponta, de nem közlekedik 2010.XII.27-től 31-ig',
	20101226, 'naponta, de nem közlekedik 2010.XII.27-től 31-ig - 3' );

cr_active( '2011.07.02', 20110702, '2011.07.02 - 1' );
cr_inactive( '2011.07.02', 20110703, '2011.07.02 - 2' );

cr_active( '2011.07.06, 2011.09.28, 2011.10.28',
	20110706, '2011.07.06, 2011.09.28, 2011.10.28 - 1' );
cr_inactive( '2011.07.06, 2011.09.28, 2011.10.28',
	20110707, '2011.07.06, 2011.09.28, 2011.10.28 - 2' );
cr_active( '2011.07.06, 2011.09.28, 2011.10.28',
	20111028, '2011.07.06, 2011.09.28, 2011.10.28 - 3' );

cr_active( '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat',
	20110625, '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat - 1' );
cr_inactive( '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat',
	20110624, '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat - 2' );
cr_active( '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat',
	20111029, '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat - 3' );
cr_inactive( '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat',
	20111030, '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat - 4' );
cr_inactive( '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat',
	20111031, '2011.06.25, 2011.06.27-től 10.30-ig péntek és szombat - 5' );

cr_active(
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta',
	20101212,
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta - 1'
);
cr_active(
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta',
	20101220,
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta - 1'
);
cr_inactive(
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta',
	20101225,
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta - 1'
);
cr_active(
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta',
	20110103,
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta - 1'
);
cr_inactive(
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta',
	20110612,
	'2010.12.12-től 19-ig naponta, 2010.12.20-tól 2011.01.02-ig szombat kivételével, 2011.01.03-tól 06.11-ig naponta - 1'
);

