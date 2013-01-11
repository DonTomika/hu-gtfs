#
#===============================================================================
#
#         FILE:  03-hugtfs-crawler.t
#
#  DESCRIPTION:  
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (), 
#      COMPANY:  
#      VERSION:  1.0
#      CREATED:  02/09/2011 09:54:21 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;

use Test::More tests => 2;                      # last test to print

BEGIN { use_ok('Test::WWW::Mechanize::Object'); }
BEGIN { use_ok('HuGTFS::Crawler'); }


