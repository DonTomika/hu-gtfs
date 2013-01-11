#
#===============================================================================
#
#         FILE:  01-cal.t
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

use Test::More tests => 50;    # last test to print

BEGIN { use_ok('Cal'); }
BEGIN { use_ok( 'HuGTFS::Test', qw/is_active is_inactive/ ); }

my $service = Cal->new(
	service_id => 'T1',
	start_date => '20100101',
	end_date   => '20100201',
	monday     => 1
);

my $service_b = Cal->new(
	service_id => 'T2',
	start_date => '20100101',
	end_date   => '20100201',
	tuesday    => 1,
);

ok( $service,   'service creation - main' );
ok( $service_b, 'service creation - b' );

is_inactive( $service, 20090101, 'bounds - 1' );
is_inactive( $service, 20110101, 'bounds - 2' );

$service->add_exception( '20100104', 'removed' );
$service->add_exception( '20100105', 'added' );
$service->add_exception( '20100115', 'added' );
$service->add_exception( '20100126', 'removed' );
$service->add_exception( '20100129', 'added' );
$service->add_exception( '20100130', 'removed' );
$service->add_exception( '20091201', 'added' );
$service->add_exception( '20091202', 'added' );

is_inactive( $service, 20100103, 'out of service' );
is_inactive( $service, 20100104, 'out of service - exception' );
is_active( $service, 20100105, 'service - exception' );
is_active( $service, 20100111, 'service' );
is_active( $service, 20091201, 'service - exception - bounds' );
is_active( $service, 20091202, 'service - exception - bounds' );

$service_b->add_exception( '20100114', 'added' );
$service_b->add_exception( '20100119', 'removed' );
$service_b->add_exception( '20100126', 'added' );
$service_b->add_exception( '20100129', 'added' );
$service_b->add_exception( '20100130', 'removed' );
$service_b->add_exception( '20091202', 'added' );

is_inactive( $service_b, 20100103, 'b - out of service' );
is_inactive( $service_b, 20100119, 'b - out of service - exception' );
is_active( $service_b, 20100114, 'b - service - exception' );
is_active( $service_b, 20100112, 'b - service' );
is_active( $service,   20091202, 'b- service - exception - bounds' );

# subtract_service
my $subtracted = $service->subtract_service($service_b);
is_inactive( $subtracted, 20091202, 'subtracted - exception - bounds - inactive' );
is_active( $subtracted, 20091201, 'subtracted - exception - bounds - active' );
is_inactive( $subtracted, 20100129, 'subtracted - inactive' );
is_active( $subtracted, 20100111, 'subtracted - active' );

# and_service
my $anded = $service->and_service($service_b);

is_inactive( $anded, 20100109, 'anded - inactive - 1' );
is_inactive( $anded, 20100201, 'anded - inactive - 2' );
is_inactive( $anded, 20100119, 'anded - inactive - 3' );
is_inactive( $anded, 20100115, 'anded - inactive - 4' );
is_active( $anded, 20100129, 'anded - active' );

is_active( $anded, 20091202, 'anded - exception - bounds' );

# or_service
my $ored = $service->or_service($service_b);
is_inactive( $ored, 20090101, 'ored - bounds - 1' );
is_inactive( $ored, 20110101, 'ored - bounds - 2' );

is_inactive( $ored, 20100103, 'ored - out of service' );
is_inactive( $ored, 20100104, 'ored - out of service - exception' );
is_active( $ored, 20100105, 'ored - service - exception' );
is_active( $ored, 20100111, 'ored - service' );

is_inactive( $ored, 20100103, 'ored - b - out of service' );
is_inactive( $ored, 20100119, 'ored - b - out of service - exception' );
is_active( $ored, 20100114, 'ored - b - service - exception' );
is_active( $ored, 20100112, 'ored - b - service' );

is_active( $ored, 20100126, 'ored - conflict' );
is_active( $ored, 20100129, 'ored - non-conflict' );
is_inactive( $ored, 20100130, 'ored - non-conflict' );

is_active( $ored, 20091201, 'ored - service - exception - bounds' );

# limit_service

my $limited = $service->limit( 20100110, 20100201 );
is_inactive( $limited, 20100104, 'limited - !enabled' );
is_inactive( $limited, 20100105, 'limited - !enabled - exception' );
is_active( $limited, 20100111, 'limited - enabled' );
is_active( $limited, 20100115, 'limited - enabled - exception' );

# parse_restrict
my $restricted = $service->restrict( '-20100106,20100110-20100114', 20100104, 20100201 );
is_inactive( $restricted, 20100104, 'restricted - !enabled - exception' );
is_active( $restricted, 20100105, 'restricted - enabled - exception' );
is_active( $restricted, 20100111, 'restricted - enabled' );
is_inactive( $restricted, 20100115, 'restricted - enabled - exception' );
is_inactive( $restricted, 20100118, 'restricted - enabled - exception' );

# XXX: clone

