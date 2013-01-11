#
#===============================================================================
#
#         FILE:  03-hugtfs-dumper.t
#
#  DESCRIPTION:
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (),
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  02/09/2011 09:55:45 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;

use Test::More qw/no_plan/;    # last test to print
use File::Spec::Functions qw/catfile catdir/;
use HuGTFS::Util qw/slurp burp/;

BEGIN { use_ok('HuGTFS::Dumper'); }

# read -> write same
{
	my $td = catdir( 't', 'gyermekvasut_data' );
	my $dumper = HuGTFS::Dumper->new;
	$dumper->load_data( $td, 1 );
	$dumper->deinit;

	for ( keys %$HuGTFS::Dumper::HEADERS ) {
		is(
			slurp( catfile( $dumper->{dir}, $_ . '.txt' ) ),
			slurp( catfile( $td, 'gtfs', $_ . '.txt' ) ),
			"simple load->dump test -- $_"
		) if -e catfile( $td, 'gtfs', $_ . '.txt' );
	}
}

# magic
# clean_dir
# mod: process_shapes, process_stops, readme, deinit, create_zip, load_data
