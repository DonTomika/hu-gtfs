#
#===============================================================================
#
#         FILE:  03-hugtfs-osmmerger.t
#
#  DESCRIPTION:  
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (), 
#      COMPANY:  
#      VERSION:  1.0
#      CREATED:  02/09/2011 09:54:50 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;

use Test::More tests => 23;                      # last test to print

BEGIN { use_ok('HuGTFS::OSMMerger'); }

is(HuGTFS::OSMMerger::node_sideof_way([5, 0], [[0, 0], [1, 0]]),  0, "(5,0) => [0,0 -> 1,0]");
is(HuGTFS::OSMMerger::node_sideof_way([0, 1], [[0, 0], [1, 0]]), -1, "(0,1) => [0,0 -> 1,0]");
is(HuGTFS::OSMMerger::node_sideof_way([0, 1], [[1, 0], [0, 0]]),  1, "");

is(HuGTFS::OSMMerger::node_sideof_way([ 0, 0], [[0, 0], [0, 1]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1, 0], [[0, 0], [0, 1]]),  1, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1, 0], [[0, 0], [0, 1]]), -1, "");

is(HuGTFS::OSMMerger::node_sideof_way([ 0, 0], [[0, 1], [0, 0]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1, 0], [[0, 1], [0, 0]]), -1, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1, 0], [[0, 1], [0, 0]]),  1, "");

is(HuGTFS::OSMMerger::node_sideof_way([ 0, 0], [[1, 1], [2, 2]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1, 2], [[1, 1], [2, 2]]), -1, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1, 0], [[1, 1], [2, 2]]),  1, "");

is(HuGTFS::OSMMerger::node_sideof_way([ 0,  0], [[-1, -1], [-2, -2]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1, -2], [[-1, -1], [-2, -2]]), -1, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1,  0], [[-1, -1], [-2, -2]]),  1, "");

is(HuGTFS::OSMMerger::node_sideof_way([-2,  2], [[-1, 1], [1, -1]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1, -1], [[-1, 1], [1, -1]]),  1, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1,  1], [[-1, 1], [1, -1]]), -1, "");

is(HuGTFS::OSMMerger::node_sideof_way([-2,  2], [[1, -1], [-1, 1]]),  0, "");
is(HuGTFS::OSMMerger::node_sideof_way([-1, -1], [[1, -1], [-1, 1]]), -1, "");
is(HuGTFS::OSMMerger::node_sideof_way([ 1,  1], [[1, -1], [-1, 1]]),  1, "(1,1) => [1,-1 -> -1,1]");

is(HuGTFS::OSMMerger::node_sideof_way([ 18.96955,  47.45644], [[18.96494, 47.45764], [18.97002, 47.45640]]),  1, "");

# parse_osm -> line/line_variant/line_segment stop/area/interchange
